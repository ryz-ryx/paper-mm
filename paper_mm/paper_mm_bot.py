"""
Live Paper Market-Making Engine on Binance Public WebSocket Streams
Assets: BTCUSDT & ETHUSDT
Public Streams:
- btcusdt@bookTicker, ethusdt@bookTicker
- btcusdt@aggTrade, ethusdt@aggTrade
- btcusdt@depth20@100ms

Strategy:
- Quote both sides around mid at fixed half-spread: max(1 tick, 0.5 * trailing 60s median spread)
- Quote size: 0.001 BTC / 0.01 ETH per side.
- Inventory limit: +-0.01 BTC / +-0.1 ETH.
  - If exceeded, quote only the reducing side.
  - Flatten inventory at the touch every 10 min if non-zero (pay taker fee).
- Quote refresh: Cancel & requote when mid moves > 1 tick or every 1s.
- Volatility pause: Pause for 60s after 10-second move > 10 bps.

Conservative Fill Model:
- 150 ms simulated latency on quote placement and cancel.
- A resting bid fills ONLY when:
  1) An aggTrade prints at price strictly BELOW bid (trade-through), OR
  2) An aggTrade prints AT bid after the visible queue ahead of me (full displayed size at placement) has traded.
- Same symmetric logic for asks.
- No partial fill optimism (fills entire quote size once queue exhausted).

Persistent Trade & Quote Logging:
- Append-only trade log: paper_mm/trades/trades.csv, flush + os.fsync on each fill.
- Restore inventory & P&L state from trades.csv on startup.
- Asynchronous markouts log: paper_mm/trades/markouts.csv keyed by trade_id.
- Rotated quote log: paper_mm/quotes/quotes_<date>.csv.gz.
- Daily summary at 00:00 UTC: paper_mm/reports/daily_<date>.txt.
"""

import os
import sys
import time
import json
import gzip
import csv
import asyncio
import logging
from collections import deque
import numpy as np
import pandas as pd
import websockets

# Setup Directories
os.makedirs('paper_mm/raw_data', exist_ok=True)
os.makedirs('paper_mm/trades', exist_ok=True)
os.makedirs('paper_mm/quotes', exist_ok=True)
os.makedirs('paper_mm/fills', exist_ok=True)
os.makedirs('paper_mm/reports', exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.FileHandler('paper_mm/paper_mm.log', mode='a', encoding='utf-8'),
        logging.StreamHandler(sys.stdout)
    ]
)
logger = logging.getLogger('PaperMM')

ASSET_CONFIG = {
    'BTCUSDT': {
        'tick_size': 0.01,
        'quote_size': 0.001,
        'inv_limit': 0.01,
        'taker_flatten_fee': 0.0010, # 0.10%
    },
    'ETHUSDT': {
        'tick_size': 0.01,
        'quote_size': 0.01,
        'inv_limit': 0.10,
        'taker_flatten_fee': 0.0010,
    }
}

FEE_SCENARIOS = {
    'maker_10_taker_10': {'maker': 0.0010, 'taker': 0.0010},
    'maker_02_taker_10': {'maker': 0.0002, 'taker': 0.0010},
    'maker_00_taker_10': {'maker': 0.0000, 'taker': 0.0010},
    'rebate_005_taker_10': {'maker': -0.00005, 'taker': 0.0010},
}

TRADES_CSV_HEADER = [
    'trade_id', 'utc_time_ms', 'symbol', 'side', 'price', 'size',
    'trade_type', 'fill_reason', 'quote_price', 'quote_placed_ms',
    'latency_ms', 'queue_ahead_at_placement', 'mid_at_fill', 'spread_at_fill_bps',
    'inventory_after',
    'fee_usd_s1', 'cash_pnl_usd_s1',
    'fee_usd_s2', 'cash_pnl_usd_s2',
    'fee_usd_s3', 'cash_pnl_usd_s3',
    'fee_usd_s4', 'cash_pnl_usd_s4'
]

MARKOUTS_CSV_HEADER = [
    'trade_id', 'symbol', 'side', 'utc_time_ms', 'mid_at_fill',
    'markout_1s_bps', 'markout_10s_bps', 'markout_60s_bps'
]

QUOTES_CSV_HEADER = [
    'utc_time_ms', 'symbol', 'action', 'side', 'quote_price', 'quote_size',
    'mid_at_action', 'queue_ahead'
]

class AssetMarketState:
    def __init__(self, symbol):
        self.symbol = symbol
        self.config = ASSET_CONFIG[symbol]
        self.best_bid = 0.0
        self.best_ask = 0.0
        self.best_bid_qty = 0.0
        self.best_ask_qty = 0.0
        self.mid = 0.0
        
        # Trailing history
        self.spread_history = deque() # (timestamp, spread)
        self.mid_history = deque()    # (timestamp, mid)
        self.pause_until = 0.0
        
        # Current active quotes
        self.active_bid = None
        self.active_ask = None
        self.last_quote_time = 0.0
        self.last_quoted_mid = 0.0
        
        # Inventory & P&L tracking
        self.inventory = 0.0
        self.inv_min = 0.0
        self.inv_max = 0.0
        self.last_flatten_time = time.time()
        
        # Markout tracking
        self.pending_markouts = []

    def update_book(self, bid, ask, bid_qty, ask_qty, now):
        self.best_bid = bid
        self.best_ask = ask
        self.best_bid_qty = bid_qty
        self.best_ask_qty = ask_qty
        self.mid = (bid + ask) / 2.0
        spread = ask - bid
        
        # Trailing 60s spread
        self.spread_history.append((now, spread))
        while self.spread_history and self.spread_history[0][0] < now - 60.0:
            self.spread_history.popleft()
            
        # Trailing 10s mid for volatility pause check
        self.mid_history.append((now, self.mid))
        while self.mid_history and self.mid_history[0][0] < now - 10.0:
            self.mid_history.popleft()
            
        if len(self.mid_history) > 1:
            oldest_mid = self.mid_history[0][1]
            move_bps = abs(self.mid - oldest_mid) / oldest_mid * 10000.0
            if move_bps > 10.0 and now > self.pause_until:
                self.pause_until = now + 60.0
                logger.info(f"[{self.symbol}] 10s move of {move_bps:.1f} bps > 10 bps. Pausing quoting for 60s.")

    def median_spread(self):
        if not self.spread_history:
            return self.config['tick_size']
        sp_vals = [s[1] for s in self.spread_history]
        return float(np.median(sp_vals))

class QuoteRotator:
    def __init__(self):
        self.current_date = None
        self.gz_file = None
        self.writer = None

    def log_quote(self, row):
        # row: [utc_time_ms, symbol, action, side, quote_price, quote_size, mid_at_action, queue_ahead]
        t_ms = row[0]
        date_str = time.strftime('%Y-%m-%d', time.gmtime(t_ms / 1000.0))
        
        if date_str != self.current_date:
            if self.gz_file:
                try:
                    self.gz_file.close()
                except Exception:
                    pass
            self.current_date = date_str
            fn = f"paper_mm/quotes/quotes_{date_str}.csv.gz"
            file_exists = os.path.exists(fn)
            self.gz_file = gzip.open(fn, mode='at', newline='', encoding='utf-8')
            self.writer = csv.writer(self.gz_file)
            if not file_exists:
                self.writer.writerow(QUOTES_CSV_HEADER)
                self.gz_file.flush()
                
        self.writer.writerow(row)
        self.gz_file.flush()

class PaperMarketMaker:
    def __init__(self):
        self.states = {
            'BTCUSDT': AssetMarketState('BTCUSDT'),
            'ETHUSDT': AssetMarketState('ETHUSDT'),
        }
        self.depth_book = {'BTCUSDT': {'bids': {}, 'asks': {}}}
        
        # P&L tracking per fee scenario
        self.pnl_data = {
            s: {
                'spread_captured': 0.0,
                'fee_drag': 0.0,
                'flatten_cost': 0.0,
                'fills_count': 0,
                'total_volume_usd': 0.0,
                'daily_pnl': {}, # day_str -> pnl
            } for s in FEE_SCENARIOS
        }
        
        self.quote_rotator = QuoteRotator()
        self.trades_file_path = 'paper_mm/trades/trades.csv'
        self.markouts_file_path = 'paper_mm/trades/markouts.csv'
        self.trades_file = None
        self.trades_writer = None
        
        self.next_trade_id = 0
        self.init_persistent_trade_files()
        self.restore_state_from_trades()
        
        # Raw event buffer for parquet dumps
        self.raw_event_buffer = []
        self.fill_records = []
        self.completed_markouts = []
        self.last_buffer_dump = time.time()
        self.last_report_time = time.time()
        self.start_time = time.time()
        self.total_dropped_buffers = 0
        self.last_daily_report_day = None
        self.running = True

    def init_persistent_trade_files(self):
        # 1. trades.csv
        file_exists = os.path.exists(self.trades_file_path)
        self.trades_file = open(self.trades_file_path, mode='a', newline='', encoding='utf-8')
        self.trades_writer = csv.writer(self.trades_file)
        if not file_exists or os.path.getsize(self.trades_file_path) == 0:
            self.trades_writer.writerow(TRADES_CSV_HEADER)
            self.trades_file.flush()
            os.fsync(self.trades_file.fileno())

        # 2. markouts.csv
        if not os.path.exists(self.markouts_file_path) or os.path.getsize(self.markouts_file_path) == 0:
            with open(self.markouts_file_path, mode='a', newline='', encoding='utf-8') as f:
                w = csv.writer(f)
                w.writerow(MARKOUTS_CSV_HEADER)
                f.flush()
                os.fsync(f.fileno())

    def restore_state_from_trades(self):
        if not os.path.exists(self.trades_file_path) or os.path.getsize(self.trades_file_path) == 0:
            logger.info("No existing trades.csv found. Initializing fresh state.")
            return

        try:
            df = pd.read_csv(self.trades_file_path)
            if df.empty:
                logger.info("trades.csv is empty. Fresh state initialized.")
                return

            self.next_trade_id = int(df['trade_id'].max()) + 1
            
            # Reconstruct inventory per symbol
            for sym in ['BTCUSDT', 'ETHUSDT']:
                df_sym = df[df['symbol'] == sym]
                if not df_sym.empty:
                    last_inv = float(df_sym.iloc[-1]['inventory_after'])
                    self.states[sym].inventory = last_inv
                    self.states[sym].inv_min = float(df_sym['inventory_after'].min())
                    self.states[sym].inv_max = float(df_sym['inventory_after'].max())
                    logger.info(f"RESTORE [{sym}]: inventory={last_inv:.4f} (min={self.states[sym].inv_min:.4f}, max={self.states[sym].inv_max:.4f})")

            # Reconstruct cumulative P&L and volume across scenarios
            s_map = {
                'maker_10_taker_10': ('fee_usd_s1', 'cash_pnl_usd_s1'),
                'maker_02_taker_10': ('fee_usd_s2', 'cash_pnl_usd_s2'),
                'maker_00_taker_10': ('fee_usd_s3', 'cash_pnl_usd_s3'),
                'rebate_005_taker_10': ('fee_usd_s4', 'cash_pnl_usd_s4'),
            }
            
            # Group by date for daily P&L
            df['day_str'] = pd.to_datetime(df['utc_time_ms'], unit='ms', utc=True).dt.strftime('%Y-%m-%d')
            
            for s_name, (fee_col, pnl_col) in s_map.items():
                if fee_col in df.columns and pnl_col in df.columns:
                    tot_fee = float(df[fee_col].sum())
                    tot_pnl = float(df[pnl_col].sum())
                    tot_vol = float((df['price'] * df['size']).sum())
                    self.pnl_data[s_name]['fee_drag'] = tot_fee
                    self.pnl_data[s_name]['total_volume_usd'] = tot_vol
                    self.pnl_data[s_name]['fills_count'] = len(df)
                    
                    # daily pnl
                    day_pnl_series = df.groupby('day_str')[pnl_col].sum()
                    for d, val in day_pnl_series.items():
                        self.pnl_data[s_name]['daily_pnl'][d] = float(val)
                        
            logger.info(f"RESTORE SUCCESS: Restored {len(df)} trades from trades.csv. Next trade_id: {self.next_trade_id}")
        except Exception as e:
            logger.error(f"Error restoring state from trades.csv: {e}")

    def log_trade_persistent(self, row):
        # row matches TRADES_CSV_HEADER
        self.trades_writer.writerow(row)
        self.trades_file.flush()
        os.fsync(self.trades_file.fileno())

    def log_markout_persistent(self, trade_id, symbol, side, utc_time_ms, mid_at_fill, m1, m10, m60):
        with open(self.markouts_file_path, mode='a', newline='', encoding='utf-8') as f:
            w = csv.writer(f)
            w.writerow([
                trade_id, symbol, side, utc_time_ms, mid_at_fill,
                f"{m1:.4f}" if m1 is not None else "",
                f"{m10:.4f}" if m10 is not None else "",
                f"{m60:.4f}" if m60 is not None else ""
            ])
            f.flush()
            os.fsync(f.fileno())

    def update_depth(self, symbol, bids, asks):
        b_dict = self.depth_book[symbol]['bids']
        for p, q in bids:
            price = float(p)
            qty = float(q)
            if qty == 0.0:
                b_dict.pop(price, None)
            else:
                b_dict[price] = qty
        a_dict = self.depth_book[symbol]['asks']
        for p, q in asks:
            price = float(p)
            qty = float(q)
            if qty == 0.0:
                a_dict.pop(price, None)
            else:
                a_dict[price] = qty

    def get_displayed_size(self, symbol, side, price):
        if symbol == 'BTCUSDT' and price in self.depth_book['BTCUSDT']['bids' if side == 'BUY' else 'asks']:
            return self.depth_book['BTCUSDT']['bids' if side == 'BUY' else 'asks'][price]
        state = self.states[symbol]
        if side == 'BUY' and abs(price - state.best_bid) < 1e-4:
            return state.best_bid_qty
        if side == 'SELL' and abs(price - state.best_ask) < 1e-4:
            return state.best_ask_qty
        return state.config['quote_size'] * 5.0 # fallback

    def quote_cycle(self, symbol, now):
        st = self.states[symbol]
        if st.mid == 0.0 or now < st.pause_until:
            return
            
        tick = st.config['tick_size']
        half_spread = max(tick, 0.5 * st.median_spread())
        
        # Check requote trigger: mid moved > 1 tick or 1s elapsed
        mid_moved = abs(st.mid - st.last_quoted_mid) > tick
        time_elapsed = (now - st.last_quote_time) >= 1.0
        
        if not (mid_moved or time_elapsed):
            return
            
        st.last_quote_time = now
        st.last_quoted_mid = st.mid
        
        target_bid = np.floor((st.mid - half_spread) / tick) * tick
        target_ask = np.ceil((st.mid + half_spread) / tick) * tick
        
        # Inventory limit check
        inv = st.inventory
        limit = st.config['inv_limit']
        
        allow_bid = (inv < limit)
        allow_ask = (inv > -limit)
        
        # Conservative latency: live after now + 0.150s (150ms)
        live_after = now + 0.150
        utc_now_ms = int(now * 1000)
        
        # Log cancels if previous active quotes existed
        if st.active_bid and st.active_bid['active']:
            self.quote_rotator.log_quote([
                utc_now_ms, symbol, 'CANCEL', 'BUY', st.active_bid['price'],
                st.active_bid['size'], st.mid, 0.0
            ])
        if st.active_ask and st.active_ask['active']:
            self.quote_rotator.log_quote([
                utc_now_ms, symbol, 'CANCEL', 'SELL', st.active_ask['price'],
                st.active_ask['size'], st.mid, 0.0
            ])
            
        if allow_bid:
            queue_bid = self.get_displayed_size(symbol, 'BUY', target_bid)
            st.active_bid = {
                'side': 'BUY',
                'price': target_bid,
                'size': st.config['quote_size'],
                'placed_time': now,
                'placed_ms': utc_now_ms,
                'live_after': live_after,
                'queue_ahead': queue_bid,
                'queue_ahead_initial': queue_bid,
                'active': True
            }
            self.quote_rotator.log_quote([
                utc_now_ms, symbol, 'PLACE', 'BUY', target_bid,
                st.config['quote_size'], st.mid, queue_bid
            ])
        else:
            st.active_bid = None
            
        if allow_ask:
            queue_ask = self.get_displayed_size(symbol, 'SELL', target_ask)
            st.active_ask = {
                'side': 'SELL',
                'price': target_ask,
                'size': st.config['quote_size'],
                'placed_time': now,
                'placed_ms': utc_now_ms,
                'live_after': live_after,
                'queue_ahead': queue_ask,
                'queue_ahead_initial': queue_ask,
                'active': True
            }
            self.quote_rotator.log_quote([
                utc_now_ms, symbol, 'PLACE', 'SELL', target_ask,
                st.config['quote_size'], st.mid, queue_ask
            ])
        else:
            st.active_ask = None

    def process_trade(self, symbol, trade_price, trade_qty, is_buyer_maker, now):
        st = self.states[symbol]
        
        # Check Resting Bid Fill
        if st.active_bid and st.active_bid['active'] and now >= st.active_bid['live_after']:
            b_price = st.active_bid['price']
            if is_buyer_maker: # Taker sell hitting bids
                if trade_price < b_price:
                    # Trade-through strictly below my bid!
                    self.execute_fill(symbol, st.active_bid, trade_price, now, reason='trade_through')
                elif abs(trade_price - b_price) < 1e-4:
                    # Trade at my bid price: deplete queue ahead
                    st.active_bid['queue_ahead'] -= trade_qty
                    if st.active_bid['queue_ahead'] <= 0.0:
                        self.execute_fill(symbol, st.active_bid, b_price, now, reason='queue_depleted')
                        
        # Check Resting Ask Fill
        if st.active_ask and st.active_ask['active'] and now >= st.active_ask['live_after']:
            a_price = st.active_ask['price']
            if not is_buyer_maker: # Taker buy hitting asks
                if trade_price > a_price:
                    # Trade-through strictly above my ask!
                    self.execute_fill(symbol, st.active_ask, trade_price, now, reason='trade_through')
                elif abs(trade_price - a_price) < 1e-4:
                    # Trade at my ask price: deplete queue ahead
                    st.active_ask['queue_ahead'] -= trade_qty
                    if st.active_ask['queue_ahead'] <= 0.0:
                        self.execute_fill(symbol, st.active_ask, a_price, now, reason='queue_depleted')

    def execute_fill(self, symbol, quote, fill_price, now, reason):
        quote['active'] = False
        side = quote['side']
        qty = quote['size']
        st = self.states[symbol]
        
        # Update inventory
        if side == 'BUY':
            st.inventory += qty
        else:
            st.inventory -= qty
            
        st.inv_min = min(st.inv_min, st.inventory)
        st.inv_max = max(st.inv_max, st.inventory)
        
        vol_usd = fill_price * qty
        mid_at_fill = st.mid
        spread_captured = (mid_at_fill - fill_price) if side == 'BUY' else (fill_price - mid_at_fill)
        spread_captured_usd = spread_captured * qty
        spread_at_fill_bps = (abs(st.best_ask - st.best_bid) / mid_at_fill * 10000.0) if mid_at_fill > 0 else 0.0
        
        # Calculate fees and cash pnl across scenarios
        today_str = time.strftime('%Y-%m-%d', time.gmtime(now))
        fee_pnl_cols = []
        for s_idx, (s_name, fees) in enumerate(FEE_SCENARIOS.items(), start=1):
            maker_fee_rate = fees['maker']
            fee_usd = vol_usd * maker_fee_rate
            cash_pnl = spread_captured_usd - fee_usd
            
            self.pnl_data[s_name]['spread_captured'] += spread_captured_usd
            self.pnl_data[s_name]['fee_drag'] += fee_usd
            self.pnl_data[s_name]['fills_count'] += 1
            self.pnl_data[s_name]['total_volume_usd'] += vol_usd
            
            day_dict = self.pnl_data[s_name]['daily_pnl']
            day_dict[today_str] = day_dict.get(today_str, 0.0) + cash_pnl
            
            fee_pnl_cols.extend([f"{fee_usd:.6f}", f"{cash_pnl:.6f}"])

        trade_id = self.next_trade_id
        self.next_trade_id += 1
        utc_ms = int(now * 1000)
        placed_ms = quote.get('placed_ms', utc_ms - 150)
        lat_ms = utc_ms - placed_ms
        q_ahead = quote.get('queue_ahead_initial', quote.get('queue_ahead', 0.0))
        
        # Write to trades.csv immediately (flush + fsync)
        trade_row = [
            trade_id, utc_ms, symbol, side, f"{fill_price:.4f}", f"{qty:.4f}",
            'maker_fill', reason, f"{quote['price']:.4f}", placed_ms,
            lat_ms, f"{q_ahead:.4f}", f"{mid_at_fill:.4f}", f"{spread_at_fill_bps:.2f}",
            f"{st.inventory:.4f}"
        ] + fee_pnl_cols
        
        self.log_trade_persistent(trade_row)

        fill_rec = {
            'trade_id': trade_id,
            'fill_id': trade_id,
            'time': now,
            'symbol': symbol,
            'side': side,
            'price': fill_price,
            'qty': qty,
            'mid_at_fill': mid_at_fill,
            'reason': reason,
            'inventory_after': st.inventory,
            'vol_usd': vol_usd,
        }
        self.fill_records.append(fill_rec)
        
        # Add to pending markouts
        st.pending_markouts.append({
            'trade_id': trade_id,
            'symbol': symbol,
            'side': side,
            'fill_time': now,
            'utc_time_ms': utc_ms,
            'mid_at_fill': mid_at_fill,
            'm1': None,
            'm10': None,
            'm60': None,
        })
        logger.info(f"FILL [{symbol}] {side} {qty} @ {fill_price:.2f} (mid: {mid_at_fill:.2f}, reason: {reason}) | Inv: {st.inventory:.4f}")

    def check_markouts(self, now):
        for sym, st in self.states.items():
            remaining = []
            for m in st.pending_markouts:
                elapsed = now - m['fill_time']
                if m['m1'] is None and elapsed >= 1.0:
                    sign = 1 if m['side'] == 'BUY' else -1
                    m['m1'] = sign * (st.mid - m['mid_at_fill']) / m['mid_at_fill'] * 10000.0
                if m['m10'] is None and elapsed >= 10.0:
                    sign = 1 if m['side'] == 'BUY' else -1
                    m['m10'] = sign * (st.mid - m['mid_at_fill']) / m['mid_at_fill'] * 10000.0
                if m['m60'] is None and elapsed >= 60.0:
                    sign = 1 if m['side'] == 'BUY' else -1
                    m['m60'] = sign * (st.mid - m['mid_at_fill']) / m['mid_at_fill'] * 10000.0
                    self.completed_markouts.append(m)
                    # Asynchronously write completed markout to markouts.csv
                    self.log_markout_persistent(
                        m['trade_id'], m['symbol'], m['side'], m['utc_time_ms'],
                        m['mid_at_fill'], m['m1'], m['m10'], m['m60']
                    )
                else:
                    remaining.append(m)
            st.pending_markouts = remaining

    def check_flatten(self, now):
        today_str = time.strftime('%Y-%m-%d', time.gmtime(now))
        for sym, st in self.states.items():
            if (now - st.last_flatten_time) >= 600.0: # 10 minutes
                st.last_flatten_time = now
                if abs(st.inventory) > 1e-6:
                    inv = st.inventory
                    side = 'SELL' if inv > 0 else 'BUY'
                    touch_price = st.best_bid if inv > 0 else st.best_ask
                    qty = abs(inv)
                    vol_usd = touch_price * qty
                    
                    slip_cost = qty * abs(touch_price - st.mid)
                    taker_fee_rate = st.config['taker_flatten_fee'] # 0.10%
                    taker_fee = vol_usd * taker_fee_rate
                    total_flatten_drag = slip_cost + taker_fee
                    
                    logger.info(f"FLATTEN [{sym}] Flattening inventory {inv:.4f} at touch {touch_price:.2f} | Drag: ${total_flatten_drag:.4f}")
                    
                    # Update inventory to 0.0
                    st.inventory = 0.0
                    st.inv_min = min(st.inv_min, 0.0)
                    st.inv_max = max(st.inv_max, 0.0)
                    
                    fee_pnl_cols = []
                    for s_name in FEE_SCENARIOS:
                        self.pnl_data[s_name]['flatten_cost'] += total_flatten_drag
                        self.pnl_data[s_name]['fills_count'] += 1
                        self.pnl_data[s_name]['total_volume_usd'] += vol_usd
                        day_dict = self.pnl_data[s_name]['daily_pnl']
                        day_dict[today_str] = day_dict.get(today_str, 0.0) - total_flatten_drag
                        fee_pnl_cols.extend([f"{taker_fee:.6f}", f"{-total_flatten_drag:.6f}"])
                        
                    # Write flatten trade as normal row in trades.csv
                    trade_id = self.next_trade_id
                    self.next_trade_id += 1
                    utc_ms = int(now * 1000)
                    spread_at_fill_bps = (abs(st.best_ask - st.best_bid) / st.mid * 10000.0) if st.mid > 0 else 0.0
                    
                    flatten_row = [
                        trade_id, utc_ms, sym, side, f"{touch_price:.4f}", f"{qty:.4f}",
                        'flatten_taker', 'flatten', f"{touch_price:.4f}", utc_ms,
                        0, "0.0000", f"{st.mid:.4f}", f"{spread_at_fill_bps:.2f}",
                        "0.0000"
                    ] + fee_pnl_cols
                    
                    self.log_trade_persistent(flatten_row)

    def check_daily_summary(self, now):
        gm = time.gmtime(now)
        # Check if we crossed 00:00 UTC and haven't written the daily summary for yesterday
        day_str = time.strftime('%Y-%m-%d', gm)
        if self.last_daily_report_day is None:
            self.last_daily_report_day = day_str
            return
            
        if day_str != self.last_daily_report_day and gm.tm_hour == 0:
            yesterday_str = self.last_daily_report_day
            self.last_daily_report_day = day_str
            self.write_daily_summary(yesterday_str, now)

    def write_daily_summary(self, target_date_str, now):
        fn = f"paper_mm/reports/daily_{target_date_str}.txt"
        
        m1_vals = [m['m1'] for m in self.completed_markouts if m['m1'] is not None]
        m10_vals = [m['m10'] for m in self.completed_markouts if m['m10'] is not None]
        m60_vals = [m['m60'] for m in self.completed_markouts if m['m60'] is not None]
        
        avg_m1 = np.mean(m1_vals) if m1_vals else 0.0
        avg_m10 = np.mean(m10_vals) if m10_vals else 0.0
        avg_m60 = np.mean(m60_vals) if m60_vals else 0.0
        
        lines = [
            f"=== DAILY PAPER MM REPORT FOR {target_date_str} (Generated at {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC) ===",
            f"Completed Trades: {len(self.fill_records)}",
            f"Inventory BTC: min={self.states['BTCUSDT'].inv_min:.4f}, max={self.states['BTCUSDT'].inv_max:.4f}, current={self.states['BTCUSDT'].inventory:.4f}",
            f"Inventory ETH: min={self.states['ETHUSDT'].inv_min:.4f}, max={self.states['ETHUSDT'].inv_max:.4f}, current={self.states['ETHUSDT'].inventory:.4f}",
            "",
            "--- MEAN MARKOUTS (Adverse Selection, bps signed in favor) ---",
            f"  1s:  {avg_m1:+.2f} bps",
            f"  10s: {avg_m10:+.2f} bps",
            f"  60s: {avg_m60:+.2f} bps",
            "",
            "--- NET P&L & VOLUME PER FEE SCENARIO ---",
        ]
        
        for s_name, data in self.pnl_data.items():
            day_pnl = data['daily_pnl'].get(target_date_str, 0.0)
            tot_net = data['spread_captured'] - data['fee_drag'] - data['flatten_cost']
            lines.append(
                f"[{s_name}] Day Net P&L: ${day_pnl:+.2f} | Cum Net P&L: ${tot_net:+.2f} | "
                f"Spread: ${data['spread_captured']:.2f} | Fees: ${data['fee_drag']:.2f} | "
                f"Flatten Drag: ${data['flatten_cost']:.2f} | Vol: ${data['total_volume_usd']:,.0f}"
            )
        lines.append("========================================================================\n")
        
        report_txt = "\n".join(lines)
        with open(fn, 'w', encoding='utf-8') as f:
            f.write(report_txt)
        logger.info(f"Wrote daily summary report for {target_date_str} -> {fn}")

    def dump_data_to_parquet(self):
        try:
            if self.raw_event_buffer:
                buffer_len = len(self.raw_event_buffer)
                try:
                    df_raw = pd.DataFrame(self.raw_event_buffer)
                    df_raw['time'] = df_raw['time'].astype(np.float64)
                    df_raw['stream'] = df_raw['stream'].astype(str)
                    df_raw['event_type'] = df_raw['event_type'].astype(str)
                    df_raw['symbol'] = df_raw['symbol'].astype(str)
                    for col in ['price', 'size', 'bid', 'ask', 'bid_size', 'ask_size']:
                        df_raw[col] = pd.to_numeric(df_raw[col], errors='coerce').astype(np.float64)
                    df_raw['payload_json'] = df_raw['payload_json'].astype(str)
                    
                    fn = f"paper_mm/raw_data/events_{int(time.time())}.parquet"
                    df_raw.to_parquet(fn, index=False)
                    self.raw_event_buffer.clear()
                except Exception as write_err:
                    self.total_dropped_buffers += 1
                    logger.error(
                        f"Failed to write raw data parquet ({buffer_len} records). "
                        f"Buffer dropped. Total dropped buffers: {self.total_dropped_buffers}. Error: {write_err}"
                    )
                    self.raw_event_buffer.clear()
                
            if self.fill_records:
                try:
                    df_fills = pd.DataFrame(self.fill_records)
                    df_fills.to_parquet('paper_mm/fills/fills_latest.parquet', index=False)
                except Exception as f_err:
                    logger.error(f"Failed to write fills parquet: {f_err}")
                
            if self.completed_markouts:
                try:
                    df_marks = pd.DataFrame(self.completed_markouts)
                    df_marks.to_parquet('paper_mm/reports/markouts_latest.parquet', index=False)
                except Exception as m_err:
                    logger.error(f"Failed to write markouts parquet: {m_err}")
        except Exception as e:
            logger.error(f"Unexpected error in dump_data_to_parquet: {e}")
            
        self.last_buffer_dump = time.time()

    def generate_report(self, now):
        self.last_report_time = now
        elapsed_hours = (now - self.start_time) / 3600.0
        
        m1_vals = [m['m1'] for m in self.completed_markouts if m['m1'] is not None]
        m10_vals = [m['m10'] for m in self.completed_markouts if m['m10'] is not None]
        m60_vals = [m['m60'] for m in self.completed_markouts if m['m60'] is not None]
        
        avg_m1 = np.mean(m1_vals) if m1_vals else 0.0
        avg_m10 = np.mean(m10_vals) if m10_vals else 0.0
        avg_m60 = np.mean(m60_vals) if m60_vals else 0.0
        
        mtm_unrealized = sum(st.inventory * (st.mid - st.last_quoted_mid) for st in self.states.values())
        
        report_lines = [
            f"=== PAPER MM 24H PERFORMANCE REPORT ===",
            f"Timestamp: {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(now))} UTC",
            f"Running Time: {elapsed_hours:.2f} hours ({(elapsed_hours/24):.2f} days)",
            f"Completed Fills: {len(self.fill_records)}",
            f"Current Inventory: BTC={self.states['BTCUSDT'].inventory:.4f}, ETH={self.states['ETHUSDT'].inventory:.4f}",
            "",
            f"--- MARKOUT (Adverse Selection in bps, signed in my favor) ---",
            f"  1s Markout:  {avg_m1:+.2f} bps",
            f"  10s Markout: {avg_m10:+.2f} bps",
            f"  60s Markout: {avg_m60:+.2f} bps",
            "",
            f"--- P&L DECOMPOSITION PER FEE SCENARIO ---",
        ]
        
        for s_name, data in self.pnl_data.items():
            net_pnl = data['spread_captured'] - data['fee_drag'] - data['flatten_cost'] + mtm_unrealized
            report_lines.append(
                f"[{s_name}] Net P&L: ${net_pnl:+.2f} | Spread: ${data['spread_captured']:.2f} | "
                f"Fees: ${data['fee_drag']:.2f} | Flatten Costs: ${data['flatten_cost']:.2f} | "
                f"Vol: ${data['total_volume_usd']:,.0f} | Daily: {data['daily_pnl']}"
            )
            
        report_lines.append("=========================================\n")
        report_txt = "\n".join(report_lines)
        print(report_txt)
        
        with open('paper_mm/reports/latest_report.txt', 'w', encoding='utf-8') as f:
            f.write(report_txt)
            
        with open('paper_mm/reports/report_history.txt', 'a', encoding='utf-8') as f:
            f.write(report_txt + "\n")
            
        # Check Stop Rules
        if elapsed_hours >= 72.0: # After 3 days
            all_fills = self.fill_records
            if all_fills:
                avg_half_spread_bps = np.mean([abs(f['price'] - f['mid_at_fill']) / f['mid_at_fill'] * 10000.0 for f in all_fills])
                if avg_m10 < -avg_half_spread_bps:
                    logger.warning(f"STOP RULE 1 TRIGGERED: 10s markout ({avg_m10:.2f} bps) < -half-spread ({avg_half_spread_bps:.2f} bps). Stopping bot.")
                    self.running = False
                    
        if elapsed_hours >= 168.0: # After 7 days
            best_pos_days = 0
            for s_name in ['maker_02_taker_10', 'maker_00_taker_10', 'rebate_005_taker_10']:
                d_pnl = self.pnl_data[s_name]['daily_pnl']
                pos_days = sum(1 for v in d_pnl.values() if v > 0)
                best_pos_days = max(best_pos_days, pos_days)
            if best_pos_days < 5:
                logger.warning(f"STOP RULE 2 TRIGGERED: Only {best_pos_days} positive days out of 7. Stopping bot.")
                self.running = False
            else:
                logger.info(f"DAY 7 CHECK PASSED: {best_pos_days} positive days. Continuing to Day 14.")

    async def run(self):
        url = 'wss://data-stream.binance.vision/stream?streams=btcusdt@bookTicker/ethusdt@bookTicker/btcusdt@aggTrade/ethusdt@aggTrade/btcusdt@depth20@100ms'
        
        logger.info(f"Connecting to Binance streams: {url}")
        
        while self.running:
            try:
                async with websockets.connect(url, ping_interval=20, ping_timeout=20, max_size=10**7) as ws:
                    logger.info("Connected to Binance WebSocket stream successfully.")
                    
                    while self.running:
                        msg = await ws.recv()
                        now = time.time()
                        data = json.loads(msg)
                        stream = data.get('stream', '')
                        payload = data.get('data', {})
                        
                        # Parse stream type and extract structured fields
                        ev_type = 'unknown'
                        sym = ''
                        p_val, q_val, b_val, a_val, bq_val, aq_val = np.nan, np.nan, np.nan, np.nan, np.nan, np.nan
                        
                        if stream.endswith('@bookTicker'):
                            ev_type = 'bookTicker'
                            sym = str(payload.get('s', ''))
                            b_val = float(payload.get('b', 0.0))
                            a_val = float(payload.get('a', 0.0))
                            bq_val = float(payload.get('B', 0.0))
                            aq_val = float(payload.get('A', 0.0))
                            if sym in self.states:
                                self.states[sym].update_book(b_val, a_val, bq_val, aq_val, now)
                                self.quote_cycle(sym, now)
                                
                        elif stream.endswith('@aggTrade'):
                            ev_type = 'aggTrade'
                            sym = str(payload.get('s', ''))
                            p_val = float(payload.get('p', 0.0))
                            q_val = float(payload.get('q', 0.0))
                            m_val = payload.get('m') # True = buyer maker (sell hits bid)
                            if sym in self.states:
                                self.process_trade(sym, p_val, q_val, m_val, now)
                                
                        elif stream.endswith('@depth20@100ms'):
                            ev_type = 'depth20'
                            sym = 'BTCUSDT'
                            bids = payload.get('bids', [])
                            asks = payload.get('asks', [])
                            self.update_depth('BTCUSDT', bids, asks)
                            
                        # Buffer raw events with explicit typed fields
                        self.raw_event_buffer.append({
                            'time': float(now),
                            'stream': str(stream),
                            'event_type': str(ev_type),
                            'symbol': str(sym),
                            'price': float(p_val) if not np.isnan(p_val) else np.nan,
                            'size': float(q_val) if not np.isnan(q_val) else np.nan,
                            'bid': float(b_val) if not np.isnan(b_val) else np.nan,
                            'ask': float(a_val) if not np.isnan(a_val) else np.nan,
                            'bid_size': float(bq_val) if not np.isnan(bq_val) else np.nan,
                            'ask_size': float(aq_val) if not np.isnan(aq_val) else np.nan,
                            'payload_json': json.dumps(payload)
                        })
                            
                        # Markout & Flatten checks
                        self.check_markouts(now)
                        self.check_flatten(now)
                        self.check_daily_summary(now)
                        
                        # Periodic parquet dump every 60s
                        if now - self.last_buffer_dump >= 60.0:
                            self.dump_data_to_parquet()
                            
                        # 24h reporting check
                        if now - self.last_report_time >= 86400.0:
                            self.generate_report(now)
                            
            except Exception as e:
                logger.error(f"WebSocket connection error: {e}. Reconnecting in 5 seconds...")
                await asyncio.sleep(5.0)

if __name__ == '__main__':
    bot = PaperMarketMaker()
    asyncio.run(bot.run())
