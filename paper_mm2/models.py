"""
Shared models, OrderBook, and screeners for Phase 1 pre-registered paper trading.
"""
import time
import json
import math
import urllib.request
from typing import Dict, List, Tuple, Optional, Any
from collections import deque

class OrderBook:
    """
    Maintains a normalized L2 top book for an instrument.
    Tracks bids and asks as sorted lists of (price, size).
    bids: descending by price
    asks: ascending by price
    """
    def __init__(self, instrument: str, venue: str):
        self.instrument = instrument
        self.venue = venue
        self.bids: List[Tuple[float, float]] = []  # [(price, size), ...]
        self.asks: List[Tuple[float, float]] = []
        self.best_bid: float = 0.0
        self.best_ask: float = 0.0
        self.mid: float = 0.0
        self.spread_bps: float = 0.0
        self.last_update_ms: int = 0
        
        # Mid price history for 10s volatility and 10s move detection: deque of (timestamp_ms, mid)
        self.mid_history: deque = deque()
        
        # 1-second rolling taker sell/buy flow: deque of (timestamp_ms, taker_side, qty)
        self.trades_history: deque = deque()
        
        # Rolling 1-hour 1s-taker-sell/buy flow history for 80th percentile: deque of (timestamp_sec, buy_flow_1s, sell_flow_1s)
        self.flow_1h_history: deque = deque()
        self._last_flow_sample_sec: int = 0

    def update_bids_asks(self, bids: List[Tuple[float, float]], asks: List[Tuple[float, float]], timestamp_ms: int):
        self.bids = sorted(bids, key=lambda x: x[0], reverse=True)
        self.asks = sorted(asks, key=lambda x: x[0])
        self.last_update_ms = timestamp_ms
        if self.bids and self.asks:
            self.best_bid = self.bids[0][0]
            self.best_ask = self.asks[0][0]
            if self.best_bid > 0 and self.best_ask > 0:
                self.mid = (self.best_bid + self.best_ask) / 2.0
                self.spread_bps = (self.best_ask - self.best_bid) / self.mid * 10000.0
                self._record_mid(timestamp_ms)

    def _record_mid(self, timestamp_ms: int):
        self.mid_history.append((timestamp_ms, self.mid))
        # Keep 70 seconds of mid history (covers 10s move and 60s horizon)
        cutoff = timestamp_ms - 70000
        while self.mid_history and self.mid_history[0][0] < cutoff:
            self.mid_history.popleft()
        self.maybe_sample_flow(timestamp_ms)

    def maybe_sample_flow(self, timestamp_ms: int):
        # Sample flow once per second for rolling 1-hour percentiles
        sec = timestamp_ms // 1000
        if sec > self._last_flow_sample_sec:
            self._last_flow_sample_sec = sec
            buy_1s, sell_1s = self.get_1s_taker_flow(timestamp_ms)
            self.flow_1h_history.append((sec, buy_1s, sell_1s))
            cutoff_1h = sec - 3600
            while self.flow_1h_history and self.flow_1h_history[0][0] < cutoff_1h:
                self.flow_1h_history.popleft()

    def record_trade(self, timestamp_ms: int, taker_side: str, qty: float):
        """
        taker_side: 'BUY' (taker bought, aggressor buy) or 'SELL' (taker sold, aggressor sell)
        """
        self.trades_history.append((timestamp_ms, taker_side, qty))
        # Keep 65 seconds
        cutoff = timestamp_ms - 65000
        while self.trades_history and self.trades_history[0][0] < cutoff:
            self.trades_history.popleft()
        self.maybe_sample_flow(timestamp_ms)

    def get_top5_imbalance(self) -> float:
        """
        top-5 bid depth / (top-5 bid + ask depth)
        """
        top5_bids = self.bids[:5]
        top5_asks = self.asks[:5]
        bid_depth = sum(sz for px, sz in top5_bids)
        ask_depth = sum(sz for px, sz in top5_asks)
        total = bid_depth + ask_depth
        if total <= 0:
            return 0.5
        return bid_depth / total

    def get_1s_taker_flow(self, now_ms: int) -> Tuple[float, float]:
        """
        Returns (taker_buy_vol_1s, taker_sell_vol_1s) over the last 1000 ms.
        """
        cutoff = now_ms - 1000
        buy_vol = 0.0
        sell_vol = 0.0
        for ts, side, qty in reversed(self.trades_history):
            if ts < cutoff:
                break
            if side == 'BUY':
                buy_vol += qty
            elif side == 'SELL':
                sell_vol += qty
        return buy_vol, sell_vol

    def get_flow_80th_percentiles(self) -> Tuple[float, float]:
        """
        Returns (buy_80th_pct, sell_80th_pct) from rolling 1 hour flow history.
        If insufficient history, returns (0.0, 0.0).
        """
        if len(self.flow_1h_history) < 30:  # Need at least 30 samples (30 seconds)
            return 0.0, 0.0
        buys = [b for s, b, sl in self.flow_1h_history]
        sells = [sl for s, b, sl in self.flow_1h_history]
        buys.sort()
        sells.sort()
        idx = int(0.80 * (len(buys) - 1))
        return buys[idx], sells[idx]

    def get_10s_move_bps(self, now_ms: int) -> float:
        """
        Absolute price move over the last 10 seconds in bps: |mid - mid_10s_ago| / mid_10s_ago * 10000.
        """
        if not self.mid_history or self.mid <= 0:
            return 0.0
        cutoff = now_ms - 10000
        # Find closest mid around cutoff
        old_mid = None
        for ts, m in self.mid_history:
            if ts <= cutoff:
                old_mid = m
            else:
                if old_mid is None:
                    old_mid = m
                break
        if old_mid is None or old_mid <= 0:
            old_mid = self.mid_history[0][1]
        if old_mid <= 0:
            return 0.0
        return abs(self.mid - old_mid) / old_mid * 10000.0

    def get_10s_realised_vol(self, now_ms: int) -> float:
        """
        D2: 10-second realized volatility in bps from 1-second mid returns (stdev over last 10 samples).
        Samples mid price at t - 10s, t - 9s, ..., t (11 points -> 10 1-second returns).
        Returns sample standard deviation * 10000.0.
        """
        if not self.mid_history or self.mid <= 0:
            return 0.0

        hist = list(self.mid_history)
        if not hist:
            return 0.0

        # Sample 11 mid prices at 1-second boundaries: now_ms - 10s, -9s, ..., 0s
        sampled_mids = []
        idx = 0
        n = len(hist)
        current_m = hist[0][1]

        for s in range(10, -1, -1):
            target_ts = now_ms - s * 1000
            while idx < n and hist[idx][0] <= target_ts:
                current_m = hist[idx][1]
                idx += 1
            sampled_mids.append(current_m)

        if any(m <= 0 for m in sampled_mids):
            return 0.0

        rets = [(sampled_mids[i] - sampled_mids[i-1]) / sampled_mids[i-1] for i in range(1, len(sampled_mids))]
        if len(rets) < 2:
            return 0.0

        mean_r = sum(rets) / len(rets)
        var_r = sum((r - mean_r) ** 2 for r in rets) / (len(rets) - 1)
        return math.sqrt(var_r) * 10000.0

    def get_displayed_depth_at(self, side: str, price: float) -> float:
        """
        Returns displayed quantity strictly at or better than this price level.
        """
        total = 0.0
        if side == 'BUY':
            for px, sz in self.bids:
                if px >= price - 1e-9:
                    total += sz
                else:
                    break
        elif side == 'SELL':
            for px, sz in self.asks:
                if px <= price + 1e-9:
                    total += sz
                else:
                    break
        return total


def screen_binance_universe(max_pairs: int = 12, min_vol_usd: float = 5_000_000.0, min_spread_bps: float = 3.0) -> List[Dict[str, Any]]:
    """
    Screen Binance spot pairs:
    >= $5M 24h vol, median spread >= 3 bps, max 12 pairs, excludes stablecoin and leveraged tokens.
    """
    try:
        req24 = urllib.request.urlopen('https://data-api.binance.vision/api/v3/ticker/24hr', timeout=10)
        t24 = json.loads(req24.read().decode())
        vol_map = {}
        for item in t24:
            s = item['symbol']
            if s.endswith('USDT'):
                vol_map[s] = float(item['quoteVolume'])

        req_bt = urllib.request.urlopen('https://data-api.binance.vision/api/v3/ticker/bookTicker', timeout=10)
        bt = json.loads(req_bt.read().decode())

        stable_bases = {'USDC', 'FDUSD', 'TUSD', 'BUSD', 'DAI', 'USDP', 'EUR', 'AEUR', 'USTC', 'WBTC', 'EURI'}
        leveraged_tags = {'UP', 'DOWN', 'BULL', 'BEAR'}

        candidates = []
        for item in bt:
            s = item['symbol']
            if s not in vol_map or vol_map[s] < min_vol_usd:
                continue
            base = s[:-4]
            if base in stable_bases or any(base.endswith(t) for t in leveraged_tags):
                continue
            bid = float(item['bidPrice'])
            ask = float(item['askPrice'])
            if bid <= 0 or ask <= 0:
                continue
            mid = (bid + ask) / 2.0
            spread_bps = (ask - bid) / mid * 10000.0
            if spread_bps >= min_spread_bps:
                candidates.append({
                    'instrument': s,
                    'venue': 'binance',
                    'volume_usd': vol_map[s],
                    'spread_bps': spread_bps,
                    'bid': bid,
                    'ask': ask
                })

        # Rank by volume descending, take top max_pairs
        candidates.sort(key=lambda x: x['volume_usd'], reverse=True)
        return candidates[:max_pairs]
    except Exception as e:
        print(f"Error screening Binance universe: {e}")
        return []


def screen_hyperliquid_universe(min_vol_usd: float = 5_000_000.0, min_spread_bps: float = 2.0) -> List[Dict[str, Any]]:
    """
    Screen Hyperliquid perps:
    >= $5M 24h vol, spread >= 2 bps.
    """
    try:
        req = urllib.request.Request('https://api.hyperliquid.xyz/info',
                                     data=json.dumps({'type': 'metaAndAssetCtxs'}).encode(),
                                     headers={'Content-Type': 'application/json'})
        res = urllib.request.urlopen(req, timeout=10)
        hl_data = json.loads(res.read().decode())
        universe = hl_data[0]['universe']
        ctxs = hl_data[1]

        candidates = []
        for i, meta in enumerate(universe):
            name = meta['name']
            ctx = ctxs[i]
            day_vol = float(ctx.get('dayNtlVlm', 0.0))
            if day_vol >= min_vol_usd:
                # Query l2Book for spread check
                try:
                    req_b = urllib.request.Request('https://api.hyperliquid.xyz/info',
                                                   data=json.dumps({'type': 'l2Book', 'coin': name}).encode(),
                                                   headers={'Content-Type': 'application/json'})
                    res_b = urllib.request.urlopen(req_b, timeout=5)
                    book = json.loads(res_b.read().decode())
                    bids = book['levels'][0]
                    asks = book['levels'][1]
                    if bids and asks:
                        b_px = float(bids[0]['px'])
                        a_px = float(asks[0]['px'])
                        if b_px > 0 and a_px > 0:
                            m = (b_px + a_px) / 2.0
                            sp_bps = (a_px - b_px) / m * 10000.0
                            if sp_bps >= min_spread_bps:
                                candidates.append({
                                    'instrument': name,
                                    'venue': 'hyperliquid',
                                    'volume_usd': day_vol,
                                    'spread_bps': sp_bps,
                                    'bid': b_px,
                                    'ask': a_px,
                                    'sz_decimals': meta.get('szDecimals', 0)
                                })
                except Exception:
                    pass

        candidates.sort(key=lambda x: x['volume_usd'], reverse=True)
        return candidates
    except Exception as e:
        print(f"Error screening Hyperliquid universe: {e}")
        return []
