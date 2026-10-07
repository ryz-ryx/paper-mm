"""
Strategy and fill engine for Phase 1 pre-registered paper trading.
Implements:
- 450 ms latency on quote placement and cancel.
- Pessimistic fill model: resting bid fills ONLY when trade prints strictly BELOW bid price (trade_through).
  Queue-depletion fill logged as a secondary flag.
- Arms A, B, C executing on the same book feed.
- Inventory limits (+/- 3 quote sizes), pause on fast moves, 10s far-touch exit tracking.
"""
import time
import os
import csv
from typing import Dict, List, Optional, Tuple, Any

class ActiveQuote:
    def __init__(self, arm: str, venue: str, instrument: str, side: str, price: float, size: float,
                 placed_time_ms: int, queue_ahead: float, spread_bps: float,
                 top5_imbalance: float, flow_1s: float, realised_vol_10s: float):
        self.arm = arm
        self.venue = venue
        self.instrument = instrument
        self.side = side          # 'BUY' or 'SELL'
        self.price = price
        self.size = size
        self.placed_time_ms = placed_time_ms
        self.live_after_ms = placed_time_ms + 450  # 450 ms latency
        self.queue_ahead_initial = queue_ahead
        self.queue_ahead_remaining = queue_ahead
        self.spread_bps = spread_bps
        self.top5_imbalance = top5_imbalance
        self.flow_1s = flow_1s
        self.realised_vol_10s = realised_vol_10s
        self.is_active = True
        self.cancel_pending_after_ms: Optional[int] = None

class PendingExit:
    def __init__(self, fill_record: Dict[str, Any]):
        self.fill_record = fill_record
        self.fill_time_ms = fill_record['timestamp_ms']
        self.arm = fill_record['arm']
        self.venue = fill_record['venue']
        self.instrument = fill_record['instrument']
        self.side = fill_record['side']  # entry side: 'BUY' or 'SELL'
        self.fill_price = fill_record['fill_price']
        self.mid_1s: Optional[float] = None
        self.mid_10s: Optional[float] = None
        self.mid_60s: Optional[float] = None
        self.far_touch_exit_10s: Optional[float] = None
        self.exit_time_ms: Optional[int] = None
        self.is_complete = False

class StrategyEngine:
    def __init__(self, data_dir: str):
        self.data_dir = data_dir
        os.makedirs(data_dir, exist_ok=True)
        self.trades_csv_path = os.path.join(data_dir, "trades.csv")
        self.quotes_csv_path = os.path.join(data_dir, "quotes.csv")
        
        # State tracking: {arm: {instrument: {'inventory': float, 'last_requote_ms': int, 'pause_until_ms': int}}}
        self.arms = ['A', 'B', 'C']
        self.state: Dict[str, Dict[str, Dict[str, Any]]] = {
            arm: {} for arm in self.arms
        }
        
        # Active quotes: {arm: {instrument: {'BUY': Optional[ActiveQuote], 'SELL': Optional[ActiveQuote]}}}
        self.active_quotes: Dict[str, Dict[str, Dict[str, Optional[ActiveQuote]]]] = {
            arm: {} for arm in self.arms
        }
        
        # Pending exits for mid +1/+10/+60s and far-touch +10s
        self.pending_exits: List[PendingExit] = []
        
        self.next_fill_id = 0
        self.next_quote_id = 0
        
        # Ensure CSV headers
        self._init_csvs()

    def _init_csvs(self):
        if not os.path.exists(self.quotes_csv_path):
            with open(self.quotes_csv_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerow([
                    'quote_id', 'timestamp_ms', 'arm', 'venue', 'instrument',
                    'action', 'side', 'price', 'size', 'spread_bps',
                    'top5_imbalance', 'flow_1s', 'realised_vol_10s', 'queue_ahead'
                ])
                f.flush()
                os.fsync(f.fileno())

        if not os.path.exists(self.trades_csv_path):
            with open(self.trades_csv_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.writer(f)
                writer.writerow([
                    'fill_id', 'timestamp_ms', 'arm', 'venue', 'instrument',
                    'side', 'fill_price', 'fill_size', 'quote_price',
                    'spread_bps_at_placement', 'top5_imbalance', 'flow_1s',
                    'realised_vol_10s', 'queue_ahead', 'fill_reason',
                    'is_primary_pessimistic_fill', 'is_queue_depleted_fill',
                    'mid_1s', 'mid_10s', 'mid_60s', 'far_touch_exit_10s',
                    'exit_time_ms', 'round_trip_edge_bps',
                    'rt_net_hl', 'rt_net_binance_vip0', 'rt_net_binance_bnb', 'rt_net_zero_fee'
                ])
                f.flush()
                os.fsync(f.fileno())

    def restore_state(self) -> int:
        """
        Restore state from trades.csv.
        Recalculates net paper inventory per arm and instrument.
        """
        if not os.path.exists(self.trades_csv_path):
            return 0
        restored_count = 0
        try:
            with open(self.trades_csv_path, 'r', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    restored_count += 1
                    fid = int(row['fill_id'])
                    self.next_fill_id = max(self.next_fill_id, fid + 1)
                    
                    arm = row['arm']
                    inst = row['instrument']
                    side = row['side']
                    sz = float(row['fill_size'])
                    
                    if arm not in self.state:
                        self.state[arm] = {}
                    if inst not in self.state[arm]:
                        self.state[arm][inst] = {'inventory': 0.0, 'last_requote_ms': 0, 'pause_until_ms': 0}
                    
                    # Note: pre-registration specifies "paper inventory is reset to flat after each 10 s exit".
                    # If exit has not completed yet, inventory would be non-zero. Since exits happen at +10s,
                    # after restart all past trades are already past +10s, so inventory is flat (0.0).
                    self.state[arm][inst]['inventory'] = 0.0
            print(f"RESTORE SUCCESS: Restored {restored_count} trades from {self.trades_csv_path}. Next fill_id: {self.next_fill_id}")
        except Exception as e:
            print(f"Error restoring state: {e}")
        return restored_count

    def get_instrument_state(self, arm: str, instrument: str) -> Dict[str, Any]:
        if instrument not in self.state[arm]:
            self.state[arm][instrument] = {
                'inventory': 0.0,
                'last_requote_ms': 0,
                'pause_until_ms': 0
            }
        return self.state[arm][instrument]

    def log_quote(self, quote_id: int, now_ms: int, arm: str, venue: str, instrument: str,
                  action: str, side: str, price: float, size: float, spread_bps: float,
                  top5_imb: float, flow_1s: float, rvol_10s: float, q_ahead: float):
        row = [
            quote_id, now_ms, arm, venue, instrument,
            action, side, f"{price:.8f}", f"{size:.8f}", f"{spread_bps:.2f}",
            f"{top5_imb:.4f}", f"{flow_1s:.4f}", f"{rvol_10s:.2f}", f"{q_ahead:.4f}"
        ]
        with open(self.quotes_csv_path, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(row)
            f.flush()
            os.fsync(f.fileno())

    def log_fill(self, fill_rec: Dict[str, Any]):
        row = [
            fill_rec['fill_id'], fill_rec['timestamp_ms'], fill_rec['arm'], fill_rec['venue'],
            fill_rec['instrument'], fill_rec['side'], f"{fill_rec['fill_price']:.8f}",
            f"{fill_rec['fill_size']:.8f}", f"{fill_rec['quote_price']:.8f}",
            f"{fill_rec['spread_bps_at_placement']:.2f}", f"{fill_rec['top5_imbalance']:.4f}",
            f"{fill_rec['flow_1s']:.4f}", f"{fill_rec['realised_vol_10s']:.2f}",
            f"{fill_rec['queue_ahead']:.4f}", fill_rec['fill_reason'],
            fill_rec['is_primary_pessimistic_fill'], fill_rec['is_queue_depleted_fill'],
            f"{fill_rec.get('mid_1s', 0.0):.8f}" if fill_rec.get('mid_1s') is not None else "",
            f"{fill_rec.get('mid_10s', 0.0):.8f}" if fill_rec.get('mid_10s') is not None else "",
            f"{fill_rec.get('mid_60s', 0.0):.8f}" if fill_rec.get('mid_60s') is not None else "",
            f"{fill_rec.get('far_touch_exit_10s', 0.0):.8f}" if fill_rec.get('far_touch_exit_10s') is not None else "",
            fill_rec.get('exit_time_ms', "") if fill_rec.get('exit_time_ms') is not None else "",
            f"{fill_rec.get('round_trip_edge_bps', 0.0):.4f}" if fill_rec.get('round_trip_edge_bps') is not None else "",
            f"{fill_rec.get('rt_net_hl', 0.0):.4f}" if fill_rec.get('rt_net_hl') is not None else "",
            f"{fill_rec.get('rt_net_binance_vip0', 0.0):.4f}" if fill_rec.get('rt_net_binance_vip0') is not None else "",
            f"{fill_rec.get('rt_net_binance_bnb', 0.0):.4f}" if fill_rec.get('rt_net_binance_bnb') is not None else "",
            f"{fill_rec.get('rt_net_zero_fee', 0.0):.4f}" if fill_rec.get('rt_net_zero_fee') is not None else ""
        ]
        with open(self.trades_csv_path, 'a', newline='', encoding='utf-8') as f:
            writer = csv.writer(f)
            writer.writerow(row)
            f.flush()
            os.fsync(f.fileno())

    def update_quote_logic(self, book: Any, now_ms: int, quote_size: float, min_spread_bps: float):
        """
        Evaluates and updates quotes for Arms A, B, C for an instrument.
        """
        instrument = book.instrument
        venue = book.venue
        
        # Check fast move: 60 s pause after > 10 bps / 10 s move
        move_10s_bps = book.get_10s_move_bps(now_ms)
        for arm in self.arms:
            st = self.get_instrument_state(arm, instrument)
            if move_10s_bps > 10.0:
                st['pause_until_ms'] = now_ms + 60000
                self._cancel_all_quotes(arm, instrument, now_ms, "PAUSE_FAST_MOVE")

        if book.best_bid <= 0 or book.best_ask <= 0 or book.spread_bps < min_spread_bps:
            for arm in self.arms:
                self._cancel_all_quotes(arm, instrument, now_ms, "SPREAD_TOO_NARROW")
            return

        top5_imb = book.get_top5_imbalance()
        buy_flow_1s, sell_flow_1s = book.get_1s_taker_flow(now_ms)
        buy_80th, sell_80th = book.get_flow_80th_percentiles()
        rvol_10s = book.get_10s_realised_vol(now_ms)

        for arm in self.arms:
            st = self.get_instrument_state(arm, instrument)
            if now_ms < st['pause_until_ms']:
                continue  # In pause window

            # Check inventory limits: +/- 3 quote sizes
            allow_bid = (st['inventory'] + quote_size <= 3.0 * quote_size + 1e-9)
            allow_ask = (st['inventory'] - quote_size >= -3.0 * quote_size - 1e-9)

            # Arm-specific filters:
            if arm == 'A':
                # No other filter
                pass
            elif arm == 'B':
                # quote bid only if top-5 bid depth / (top-5 bid + ask depth) >= 0.60; mirror for ask (ask depth ratio >= 0.60 => top5_imb <= 0.40)
                if top5_imb < 0.60:
                    allow_bid = False
                if (1.0 - top5_imb) < 0.60:  # top5_imb > 0.40
                    allow_ask = False
            elif arm == 'C':
                # B plus cancel-on-flow: pull bid if taker-sell volume over last 1s exceeds rolling 80th percentile; mirror for ask
                if top5_imb < 0.60:
                    allow_bid = False
                if (1.0 - top5_imb) < 0.60:
                    allow_ask = False
                    
                # Flow check
                if sell_80th > 0 and sell_flow_1s > sell_80th:
                    allow_bid = False
                if buy_80th > 0 and buy_flow_1s > buy_80th:
                    allow_ask = False

            # Update Quotes for this arm:
            # Requote conditions: requote on >= 1 tick mid move or every 1 s
            self._manage_side_quote(arm, venue, instrument, 'BUY', book.best_bid, quote_size,
                                    allow_bid, now_ms, book, top5_imb, sell_flow_1s, rvol_10s)
            self._manage_side_quote(arm, venue, instrument, 'SELL', book.best_ask, quote_size,
                                    allow_ask, now_ms, book, top5_imb, buy_flow_1s, rvol_10s)

    def _manage_side_quote(self, arm: str, venue: str, instrument: str, side: str,
                           touch_price: float, size: float, allowed: bool, now_ms: int,
                           book: Any, top5_imb: float, flow_1s: float, rvol_10s: float):
        if instrument not in self.active_quotes[arm]:
            self.active_quotes[arm][instrument] = {'BUY': None, 'SELL': None}
        current_q = self.active_quotes[arm][instrument][side]

        if not allowed:
            if current_q and current_q.is_active and current_q.cancel_pending_after_ms is None:
                # Initiate cancel with 450 ms latency
                current_q.cancel_pending_after_ms = now_ms + 450
            return

        # Check if current quote needs requote
        needs_requote = False
        if current_q is None or not current_q.is_active:
            needs_requote = True
        else:
            # If price changed from touch price
            if abs(current_q.price - touch_price) > 1e-9:
                needs_requote = True
            # Or if more than 1 second elapsed since placement
            elif now_ms - current_q.placed_time_ms >= 1000:
                needs_requote = True

        if needs_requote:
            # If there was an existing active quote, schedule cancel
            if current_q and current_q.is_active and current_q.cancel_pending_after_ms is None:
                current_q.cancel_pending_after_ms = now_ms + 450
                self.log_quote(self.next_quote_id, now_ms, arm, venue, instrument, 'CANCEL',
                               side, current_q.price, current_q.size, current_q.spread_bps,
                               top5_imb, flow_1s, rvol_10s, current_q.queue_ahead_remaining)
                self.next_quote_id += 1

            # Place new quote
            q_ahead = book.get_displayed_depth_at(side, touch_price)
            new_q = ActiveQuote(
                arm=arm, venue=venue, instrument=instrument, side=side, price=touch_price,
                size=size, placed_time_ms=now_ms, queue_ahead=q_ahead,
                spread_bps=book.spread_bps, top5_imbalance=top5_imb,
                flow_1s=flow_1s, realised_vol_10s=rvol_10s
            )
            self.active_quotes[arm][instrument][side] = new_q
            self.log_quote(self.next_quote_id, now_ms, arm, venue, instrument, 'PLACE',
                           side, touch_price, size, book.spread_bps,
                           top5_imb, flow_1s, rvol_10s, q_ahead)
            self.next_quote_id += 1

    def _cancel_all_quotes(self, arm: str, instrument: str, now_ms: int, reason: str):
        if instrument not in self.active_quotes[arm]:
            return
        for side in ['BUY', 'SELL']:
            q = self.active_quotes[arm][instrument][side]
            if q and q.is_active and q.cancel_pending_after_ms is None:
                q.cancel_pending_after_ms = now_ms + 450

    def process_trade(self, book: Any, trade_time_ms: int, trade_price: float, trade_qty: float, taker_side: str):
        """
        Evaluate fills against active quotes for all arms.
        Primary fill rule (pessimistic):
        - Resting bid fills only when trade prints strictly BELOW bid price AFTER the 450 ms latency.
        - Resting ask fills only when trade prints strictly ABOVE ask price AFTER the 450 ms latency.
        Secondary: queue-depletion fills are logged as a secondary flag.
        """
        instrument = book.instrument
        for arm in self.arms:
            quotes_dict = self.active_quotes[arm].get(instrument, {})
            for side in ['BUY', 'SELL']:
                q = quotes_dict.get(side)
                if not q or not q.is_active:
                    continue

                # Has 450 ms latency elapsed?
                if trade_time_ms < q.live_after_ms:
                    continue

                # Check if cancel has completed
                if q.cancel_pending_after_ms is not None and trade_time_ms >= q.cancel_pending_after_ms:
                    q.is_active = False
                    continue

                fill_occurred = False
                fill_reason = ""
                is_trade_through = False
                is_queue_depleted = False

                if side == 'BUY':
                    # Trade-through: trade prints strictly below bid price
                    if trade_price < q.price - 1e-9:
                        is_trade_through = True
                        fill_reason = "trade_through"
                        fill_occurred = True
                    # Queue depletion: trade prints at bid price
                    elif abs(trade_price - q.price) <= 1e-9 and taker_side == 'SELL':
                        q.queue_ahead_remaining -= trade_qty
                        if q.queue_ahead_remaining <= 0:
                            is_queue_depleted = True
                            fill_reason = "queue_depleted"
                            # If only queue depleted, primary pessimistic fill is False, but secondary is True
                            fill_occurred = True

                elif side == 'SELL':
                    # Trade-through: trade prints strictly above ask price
                    if trade_price > q.price + 1e-9:
                        is_trade_through = True
                        fill_reason = "trade_through"
                        fill_occurred = True
                    # Queue depletion: trade prints at ask price
                    elif abs(trade_price - q.price) <= 1e-9 and taker_side == 'BUY':
                        q.queue_ahead_remaining -= trade_qty
                        if q.queue_ahead_remaining <= 0:
                            is_queue_depleted = True
                            fill_reason = "queue_depleted"
                            fill_occurred = True

                if fill_occurred:
                    q.is_active = False  # Full-size fill: quote consumed
                    fill_id = self.next_fill_id
                    self.next_fill_id += 1

                    # Update paper inventory
                    st = self.get_instrument_state(arm, instrument)
                    if side == 'BUY':
                        st['inventory'] += q.size
                    else:
                        st['inventory'] -= q.size

                    fill_rec = {
                        'fill_id': fill_id,
                        'timestamp_ms': trade_time_ms,
                        'arm': arm,
                        'venue': q.venue,
                        'instrument': instrument,
                        'side': side,
                        'fill_price': q.price,
                        'fill_size': q.size,
                        'quote_price': q.price,
                        'spread_bps_at_placement': q.spread_bps,
                        'top5_imbalance': q.top5_imbalance,
                        'flow_1s': q.flow_1s,
                        'realised_vol_10s': q.realised_vol_10s,
                        'queue_ahead': q.queue_ahead_initial,
                        'fill_reason': fill_reason,
                        'is_primary_pessimistic_fill': is_trade_through,
                        'is_queue_depleted_fill': is_queue_depleted
                    }
                    
                    # Register pending exit for +1s, +10s, +60s mid and +10s far-touch exit
                    self.pending_exits.append(PendingExit(fill_rec))
                    print(f"[{trade_time_ms}] FILL Arm-{arm} {instrument} {side} {q.size} @ {q.price} ({fill_reason})")

    def check_pending_exits(self, book_map: Dict[str, Any], now_ms: int):
        """
        Check and record mid at +1/+10/+60s and far-touch exit at +10s.
        Reset paper inventory to flat after each 10s exit.
        """
        completed = []
        for p in self.pending_exits:
            if p.is_complete:
                continue
            book = book_map.get(p.instrument)
            if not book or book.mid <= 0:
                continue

            elapsed_ms = now_ms - p.fill_time_ms
            
            # Mid at +1 s (>= 1000 ms)
            if elapsed_ms >= 1000 and p.mid_1s is None:
                p.mid_1s = book.mid
                
            # Mid and far touch at +10 s (>= 10000 ms)
            if elapsed_ms >= 10000 and p.mid_10s is None:
                p.mid_10s = book.mid
                p.exit_time_ms = now_ms
                # Far-touch exit price: sell at bid for longs, buy at ask for shorts
                if p.side == 'BUY':
                    p.far_touch_exit_10s = book.best_bid
                else:
                    p.far_touch_exit_10s = book.best_ask
                    
                # Reset paper inventory to flat after each 10 s exit
                st = self.get_instrument_state(p.arm, p.instrument)
                if p.side == 'BUY':
                    st['inventory'] = max(0.0, st['inventory'] - p.fill_record['fill_size'])
                else:
                    st['inventory'] = min(0.0, st['inventory'] + p.fill_record['fill_size'])

            # Mid at +60 s (>= 60000 ms)
            if elapsed_ms >= 60000 and p.mid_60s is None:
                p.mid_60s = book.mid
                p.is_complete = True
                completed.append(p)

        # Log finalized fills that completed the 60s horizon
        for p in completed:
            self.pending_exits.remove(p)
            self._finalize_and_log_fill(p)

    def _finalize_and_log_fill(self, p: PendingExit):
        rec = dict(p.fill_record)
        rec['mid_1s'] = p.mid_1s
        rec['mid_10s'] = p.mid_10s
        rec['mid_60s'] = p.mid_60s
        rec['far_touch_exit_10s'] = p.far_touch_exit_10s
        rec['exit_time_ms'] = p.exit_time_ms

        exit_px = p.far_touch_exit_10s if p.far_touch_exit_10s else p.fill_price
        fill_px = p.fill_price
        side_sign = 1.0 if p.side == 'BUY' else -1.0
        
        # Edge per fill (bps) = side-signed (exit_price - fill_price) / fill_price * 1e4
        edge_bps = side_sign * (exit_px - fill_px) / fill_px * 10000.0
        rec['round_trip_edge_bps'] = edge_bps

        # Fee sets:
        # Hyperliquid perps (maker 1.5, taker 4.5): total fee = 6.0 bps
        rec['rt_net_hl'] = edge_bps - 1.5 - 4.5
        # Binance spot VIP0 (10 / 10): total fee = 20.0 bps
        rec['rt_net_binance_vip0'] = edge_bps - 10.0 - 10.0
        # Binance spot with BNB (7.5 / 7.5): total fee = 15.0 bps
        rec['rt_net_binance_bnb'] = edge_bps - 7.5 - 7.5
        # Zero-fee reference (0 / 0): total fee = 0.0 bps
        rec['rt_net_zero_fee'] = edge_bps - 0.0 - 0.0

        self.log_fill(rec)
