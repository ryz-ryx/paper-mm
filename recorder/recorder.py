"""
High-Frequency Market Data Recorder for Mapped Binance Spot and Hyperliquid Perps.

Captures:
1. Normalized trades (ts_exchange, ts_local, venue, symbol, price, size, side)
2. 250ms periodic snapshots of mid + top-5 depth for both venues
3. Hyperliquid trade bursts (burst tracking: window_ms, burst_trades_count, burst_vol, etc.)

Writes compressed parquet hourly to recorder_data/
"""
import asyncio
import websockets
import json
import time
import os
import signal
import sys
import urllib.request
from typing import Dict, List, Any, Optional
from datetime import datetime, timezone
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq


def get_mapped_pairs(max_pairs: int = 40) -> Dict[str, Dict[str, str]]:
    """
    Find pairs that exist on both Binance Spot (<COIN>USDT) and Hyperliquid Perps (<COIN>).
    Ranked by min daily volume across both venues.
    Returns: {coin: {'binance_symbol': 'BTCUSDT', 'hl_coin': 'BTC'}}
    """
    try:
        # Binance 24hr ticker
        req_b = urllib.request.urlopen("https://data-api.binance.vision/api/v3/ticker/24hr", timeout=10)
        b_data = json.loads(req_b.read().decode('utf-8'))
        b_pairs = {}
        for item in b_data:
            sym = item.get('symbol', '')
            if sym.endswith('USDT'):
                base = sym[:-4]
                b_pairs[base] = (sym, float(item.get('quoteVolume', 0)))

        # Hyperliquid metaAndAssetCtxs
        req_hl = urllib.request.Request(
            "https://api.hyperliquid.xyz/info",
            data=json.dumps({"type": "metaAndAssetCtxs"}).encode('utf-8'),
            headers={"Content-Type": "application/json"}
        )
        hl_res = json.loads(urllib.request.urlopen(req_hl, timeout=10).read().decode('utf-8'))
        hl_coins = {}
        for u, c in zip(hl_res[0]['universe'], hl_res[1]):
            coin = u['name']
            vol = float(c.get('dayNtlVlm', 0))
            hl_coins[coin] = vol

        common = set(b_pairs.keys()).intersection(set(hl_coins.keys()))
        sorted_coins = sorted(list(common), key=lambda c: min(b_pairs[c][1], hl_coins[c]), reverse=True)
        selected = sorted_coins[:max_pairs]

        mapping = {}
        for c in selected:
            mapping[c] = {
                'binance_symbol': b_pairs[c][0],
                'hl_coin': c
            }
        print(f"[Recorder] Discovered {len(common)} common mapped pairs; tracking top {len(mapping)}:")
        print(f"[Recorder] Pairs: {', '.join(selected)}")
        return mapping
    except Exception as e:
        print(f"[Recorder] Error discovering mapped pairs: {e}. Falling back to default top pairs.")
        defaults = ['BTC', 'ETH', 'SOL', 'NEAR', 'ZEC', 'XRP', 'DOGE', 'AVAX', 'SUI', 'ADA', 'UNI', 'ENA', 'WLD', 'TAO', 'ONDO']
        return {c: {'binance_symbol': f'{c}USDT', 'hl_coin': c} for c in defaults}


class MarketRecorder:
    def __init__(self, data_dir: str = "recorder_data"):
        self.data_dir = data_dir
        os.makedirs(self.data_dir, exist_ok=True)
        self.running = True

        self.mapped_pairs = get_mapped_pairs(max_pairs=35)
        self.binance_symbols = {info['binance_symbol']: coin for coin, info in self.mapped_pairs.items()}
        self.hl_coins = {info['hl_coin']: coin for coin, info in self.mapped_pairs.items()}

        # Live book state: venue -> coin -> {'bids': [[px, sz]..5], 'asks': [[px, sz]..5], 'mid': float, 'ts': int}
        self.depth_state: Dict[str, Dict[str, Dict[str, Any]]] = {
            'binance': {},
            'hyperliquid': {}
        }
        for coin in self.mapped_pairs:
            self.depth_state['binance'][coin] = {'bids': [], 'asks': [], 'mid': 0.0, 'ts': 0}
            self.depth_state['hyperliquid'][coin] = {'bids': [], 'asks': [], 'mid': 0.0, 'ts': 0}

        # Buffers for hourly flush
        self.trades_buffer: List[Dict[str, Any]] = []
        self.depth_buffer: List[Dict[str, Any]] = []
        self.bursts_buffer: List[Dict[str, Any]] = []
        self.funding_buffer: List[Dict[str, Any]] = []

        # Trade burst detection state per coin on Hyperliquid
        # Window of trades in last 1000ms: deque of (ts_local, sz, side)
        self.hl_trade_history: Dict[str, List[Dict[str, Any]]] = {coin: [] for coin in self.mapped_pairs}
        self.last_burst_logged: Dict[str, int] = {coin: 0 for coin in self.mapped_pairs}

        self.current_hour_str = datetime.now(timezone.utc).strftime("%Y%m%d_%H")

    def record_trade(self, venue: str, coin: str, ts_exchange: int, ts_local: int, price: float, size: float, side: str):
        self.trades_buffer.append({
            'ts_exchange': ts_exchange,
            'ts_local': ts_local,
            'venue': venue,
            'coin': coin,
            'price': price,
            'size': size,
            'side': side
        })

        if venue == 'hyperliquid':
            self._check_hl_trade_burst(coin, ts_exchange, ts_local, price, size, side)

    def _check_hl_trade_burst(self, coin: str, ts_exchange: int, ts_local: int, price: float, size: float, side: str):
        hist = self.hl_trade_history[coin]
        hist.append({'ts': ts_local, 'sz': size, 'side': side, 'px': price})
        
        # Prune older than 1000ms
        cutoff = ts_local - 1000
        while hist and hist[0]['ts'] < cutoff:
            hist.pop(0)

        # Burst trigger: >= 5 trades in 1000ms or volume surge
        if len(hist) >= 5 and (ts_local - self.last_burst_logged[coin] >= 1000):
            buy_sz = sum(t['sz'] for t in hist if t['side'] == 'BUY')
            sell_sz = sum(t['sz'] for t in hist if t['side'] == 'SELL')
            start_px = hist[0]['px']
            end_px = hist[-1]['px']
            px_change_bps = ((end_px - start_px) / start_px * 10000.0) if start_px > 0 else 0.0

            self.bursts_buffer.append({
                'ts_exchange': ts_exchange,
                'ts_local': ts_local,
                'coin': coin,
                'trade_count_1s': len(hist),
                'buy_vol_1s': buy_sz,
                'sell_vol_1s': sell_sz,
                'price_start': start_px,
                'price_end': end_px,
                'price_change_bps': px_change_bps
            })
            self.last_burst_logged[coin] = ts_local

    def record_depth_snapshot(self, now_ms: int):
        for coin in self.mapped_pairs:
            b_state = self.depth_state['binance'].get(coin, {})
            hl_state = self.depth_state['hyperliquid'].get(coin, {})

            b_bids = b_state.get('bids', [])
            b_asks = b_state.get('asks', [])
            b_mid = b_state.get('mid', 0.0)

            hl_bids = hl_state.get('bids', [])
            hl_asks = hl_state.get('asks', [])
            hl_mid = hl_state.get('mid', 0.0)

            # Record if at least one venue has valid quote
            if b_mid > 0 or hl_mid > 0:
                row = {
                    'ts_local': now_ms,
                    'coin': coin,
                    'binance_mid': b_mid,
                    'binance_bid_0_px': b_bids[0][0] if len(b_bids) > 0 else 0.0,
                    'binance_bid_0_sz': b_bids[0][1] if len(b_bids) > 0 else 0.0,
                    'binance_ask_0_px': b_asks[0][0] if len(b_asks) > 0 else 0.0,
                    'binance_ask_0_sz': b_asks[0][1] if len(b_asks) > 0 else 0.0,
                    'binance_bid_top5_sz': sum(x[1] for x in b_bids[:5]),
                    'binance_ask_top5_sz': sum(x[1] for x in b_asks[:5]),
                    'hl_mid': hl_mid,
                    'hl_bid_0_px': hl_bids[0][0] if len(hl_bids) > 0 else 0.0,
                    'hl_bid_0_sz': hl_bids[0][1] if len(hl_bids) > 0 else 0.0,
                    'hl_ask_0_px': hl_asks[0][0] if len(hl_asks) > 0 else 0.0,
                    'hl_ask_0_sz': hl_asks[0][1] if len(hl_asks) > 0 else 0.0,
                    'hl_bid_top5_sz': sum(x[1] for x in hl_bids[:5]),
                    'hl_ask_top5_sz': sum(x[1] for x in hl_asks[:5]),
                }
                self.depth_buffer.append(row)

    def flush_to_parquet(self, hour_str: Optional[str] = None):
        """
        Flushes in-memory buffers into compressed parquet files.
        """
        target_hour = hour_str or self.current_hour_str
        print(f"[Recorder] Flushing data for hour {target_hour} (trades={len(self.trades_buffer)}, depth={len(self.depth_buffer)}, bursts={len(self.bursts_buffer)})...")

        if self.trades_buffer:
            df_t = pd.DataFrame(self.trades_buffer)
            table_t = pa.Table.from_pandas(df_t)
            t_path = os.path.join(self.data_dir, f"trades_{target_hour}.parquet")
            if os.path.exists(t_path):
                # Append by reading existing or write partitioned
                existing_t = pq.read_table(t_path)
                combined = pa.concat_tables([existing_t, table_t])
                pq.write_table(combined, t_path, compression='snappy')
            else:
                pq.write_table(table_t, t_path, compression='snappy')
            self.trades_buffer.clear()

        if self.depth_buffer:
            df_d = pd.DataFrame(self.depth_buffer)
            table_d = pa.Table.from_pandas(df_d)
            d_path = os.path.join(self.data_dir, f"depth_{target_hour}.parquet")
            if os.path.exists(d_path):
                existing_d = pq.read_table(d_path)
                combined = pa.concat_tables([existing_d, table_d])
                pq.write_table(combined, d_path, compression='snappy')
            else:
                pq.write_table(table_d, d_path, compression='snappy')
            self.depth_buffer.clear()

        if self.bursts_buffer:
            df_b = pd.DataFrame(self.bursts_buffer)
            table_b = pa.Table.from_pandas(df_b)
            b_path = os.path.join(self.data_dir, f"bursts_{target_hour}.parquet")
            if os.path.exists(b_path):
                existing_b = pq.read_table(b_path)
                combined = pa.concat_tables([existing_b, table_b])
                pq.write_table(combined, b_path, compression='snappy')
            else:
                pq.write_table(table_b, b_path, compression='snappy')
            self.bursts_buffer.clear()

        if self.funding_buffer:
            df_f = pd.DataFrame(self.funding_buffer)
            table_f = pa.Table.from_pandas(df_f)
            f_path = os.path.join(self.data_dir, f"funding_{target_hour}.parquet")
            if os.path.exists(f_path):
                existing_f = pq.read_table(f_path)
                combined = pa.concat_tables([existing_f, table_f])
                pq.write_table(combined, f_path, compression='snappy')
            else:
                pq.write_table(table_f, f_path, compression='snappy')
            self.funding_buffer.clear()

        print(f"[Recorder] Flush complete.")

    async def run_depth_sampler_loop(self):
        """
        Polls and records mid + top-5 depth snapshot every 250 ms.
        """
        print("[Recorder] Depth sampler loop started (250ms interval).")
        while self.running:
            start_t = time.perf_counter()
            now_ms = int(time.time() * 1000)
            self.record_depth_snapshot(now_ms)
            elapsed = time.perf_counter() - start_t
            sleep_time = max(0.25 - elapsed, 0.05)
            await asyncio.sleep(sleep_time)

    async def run_hourly_flush_loop(self):
        """
        Periodically flushes data to parquet every 10 minutes or upon hour rollover.
        """
        while self.running:
            await asyncio.sleep(600)  # Flush every 10 min
            now_hour = datetime.now(timezone.utc).strftime("%Y%m%d_%H")
            prev_hour = self.current_hour_str
            self.flush_to_parquet(prev_hour)
            self.current_hour_str = now_hour

    async def run_binance_ws(self):
        symbols = [info['binance_symbol'].lower() for info in self.mapped_pairs.values()]
        streams = []
        for s in symbols:
            streams.append(f"{s}@aggTrade")
            streams.append(f"{s}@depth20@100ms")

        # Binance combined stream
        url = f"wss://data-stream.binance.vision/stream?streams={'/'.join(streams)}"
        print(f"[Recorder] Connecting to Binance WS for {len(symbols)} pairs ({len(streams)} streams)...")

        while self.running:
            try:
                async with websockets.connect(url, ping_interval=20, max_size=10**7) as ws:
                    print("[Recorder] Binance WS connected.")
                    while self.running:
                        msg = await ws.recv()
                        now_ms = int(time.time() * 1000)
                        data = json.loads(msg)
                        stream = data.get('stream', '')
                        payload = data.get('data', {})
                        s = payload.get('s') or (stream.split('@')[0].upper() if '@' in stream else '')
                        coin = self.binance_symbols.get(s)
                        if not coin:
                            continue

                        if '@aggTrade' in stream:
                            px = float(payload.get('p', 0.0))
                            sz = float(payload.get('q', 0.0))
                            is_buyer_maker = payload.get('m', False)
                            side = 'SELL' if is_buyer_maker else 'BUY'
                            ts_ex = payload.get('T', now_ms)
                            self.record_trade('binance', coin, ts_ex, now_ms, px, sz, side)

                        elif '@depth20' in stream:
                            bids = [(float(px), float(sz)) for px, sz in payload.get('bids', [])[:5]]
                            asks = [(float(px), float(sz)) for px, sz in payload.get('asks', [])[:5]]
                            best_b = bids[0][0] if bids else 0.0
                            best_a = asks[0][0] if asks else 0.0
                            mid = (best_b + best_a) / 2.0 if best_b > 0 and best_a > 0 else 0.0
                            self.depth_state['binance'][coin] = {
                                'bids': bids,
                                'asks': asks,
                                'mid': mid,
                                'ts': now_ms
                            }

            except Exception as e:
                print(f"[Recorder] Binance WS error: {e}. Reconnecting in 3s...")
                await asyncio.sleep(3)

    async def run_hyperliquid_ws(self):
        coins = list(self.hl_coins.keys())
        url = "wss://api.hyperliquid.xyz/ws"
        print(f"[Recorder] Connecting to Hyperliquid WS for {len(coins)} coins...")

        while self.running:
            try:
                async with websockets.connect(url, ping_interval=20, max_size=10**7) as ws:
                    print("[Recorder] Hyperliquid WS connected.")
                    for c in coins:
                        await ws.send(json.dumps({'method': 'subscribe', 'subscription': {'type': 'l2Book', 'coin': c}}))
                        await ws.send(json.dumps({'method': 'subscribe', 'subscription': {'type': 'trades', 'coin': c}}))

                    while self.running:
                        msg = await ws.recv()
                        now_ms = int(time.time() * 1000)
                        data = json.loads(msg)
                        channel = data.get('channel')

                        if channel == 'l2Book':
                            book_data = data.get('data', {})
                            coin = book_data.get('coin')
                            if coin in self.hl_coins:
                                levels = book_data.get('levels', [[], []])
                                bids = [(float(x['px']), float(x['sz'])) for x in levels[0][:5]]
                                asks = [(float(x['px']), float(x['sz'])) for x in levels[1][:5]]
                                best_b = bids[0][0] if bids else 0.0
                                best_a = asks[0][0] if asks else 0.0
                                mid = (best_b + best_a) / 2.0 if best_b > 0 and best_a > 0 else 0.0
                                self.depth_state['hyperliquid'][coin] = {
                                    'bids': bids,
                                    'asks': asks,
                                    'mid': mid,
                                    'ts': now_ms
                                }

                        elif channel == 'trades':
                            trades_list = data.get('data', [])
                            for tr in trades_list:
                                coin = tr.get('coin')
                                if coin in self.hl_coins:
                                    px = float(tr.get('px', 0.0))
                                    sz = float(tr.get('sz', 0.0))
                                    side = 'BUY' if tr.get('side') == 'B' else 'SELL'
                                    ts_ex = tr.get('time', now_ms)
                                    self.record_trade('hyperliquid', coin, ts_ex, now_ms, px, sz, side)

            except Exception as e:
                print(f"[Recorder] Hyperliquid WS error: {e}. Reconnecting in 3s...")
                await asyncio.sleep(3)

    async def run_funding_tracker_loop(self):
        """
        Polls Hyperliquid metaAndAssetCtxs every 5 minutes (300s) for funding rates, mark, and oracle prices.
        """
        print("[Recorder] Funding tracker loop started (300s interval).")
        while self.running:
            try:
                now_ms = int(time.time() * 1000)
                req_hl = urllib.request.Request(
                    "https://api.hyperliquid.xyz/info",
                    data=json.dumps({"type": "metaAndAssetCtxs"}).encode('utf-8'),
                    headers={"Content-Type": "application/json"}
                )
                loop = asyncio.get_running_loop()
                res = await loop.run_in_executor(
                    None,
                    lambda: json.loads(urllib.request.urlopen(req_hl, timeout=10).read().decode('utf-8'))
                )
                if isinstance(res, list) and len(res) >= 2:
                    universe = res[0].get('universe', [])
                    asset_ctxs = res[1]
                    for u, c in zip(universe, asset_ctxs):
                        coin = u.get('name')
                        if coin in self.mapped_pairs:
                            self.funding_buffer.append({
                                'ts_local': now_ms,
                                'coin': coin,
                                'funding': float(c.get('funding', 0.0)),
                                'oracle_px': float(c.get('oraclePx', 0.0)),
                                'mark_px': float(c.get('markPx', 0.0)),
                                'open_interest': float(c.get('openInterest', 0.0)),
                                'day_ntl_vlm': float(c.get('dayNtlVlm', 0.0))
                            })
            except Exception as e:
                print(f"[Recorder] Error polling funding info: {e}")

            await asyncio.sleep(300)

    async def start(self):
        tasks = [
            asyncio.create_task(self.run_depth_sampler_loop()),
            asyncio.create_task(self.run_hourly_flush_loop()),
            asyncio.create_task(self.run_binance_ws()),
            asyncio.create_task(self.run_hyperliquid_ws()),
            asyncio.create_task(self.run_funding_tracker_loop()),
        ]
        try:
            await asyncio.gather(*tasks)
        except asyncio.CancelledError:
            print("[Recorder] Main loop cancelled.")
        finally:
            print("[Recorder] Performing final flush to parquet...")
            self.flush_to_parquet()


def main():
    recorder = MarketRecorder()

    def handle_signal(sig, frame):
        print(f"[Recorder] Signal {sig} received, exiting...")
        recorder.running = False
        recorder.flush_to_parquet()
        sys.exit(0)

    try:
        signal.signal(signal.SIGINT, handle_signal)
        signal.signal(signal.SIGTERM, handle_signal)
    except Exception:
        pass

    try:
        asyncio.run(recorder.start())
    except KeyboardInterrupt:
        recorder.flush_to_parquet()

if __name__ == "__main__":
    main()
