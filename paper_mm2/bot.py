"""
Main bot runtime for Phase 1 pre-registered market making.
Orchestrates:
- Binance spot WebSocket (wss://data-stream.binance.vision)
- Hyperliquid perps WebSocket (wss://api.hyperliquid.xyz/ws)
- Daily universe screening
- Parallel Arms A, B, C execution
- State saving and downtime tracking
"""
import asyncio
import websockets
import json
import time
import os
import signal
import sys
from typing import Dict, List, Any
from datetime import datetime, timezone

from models import OrderBook, screen_binance_universe, screen_hyperliquid_universe
from engine import StrategyEngine

class PaperMM2Bot:
    def __init__(self, base_dir: str):
        self.base_dir = base_dir
        self.data_dir = os.path.join(base_dir, "data")
        self.reports_dir = os.path.join(base_dir, "reports")
        os.makedirs(self.data_dir, exist_ok=True)
        os.makedirs(self.reports_dir, exist_ok=True)
        
        self.downtime_log_path = os.path.join(self.data_dir, "downtime.csv")
        self._init_downtime_log()

        self.engine = StrategyEngine(self.data_dir)
        self.books: Dict[str, OrderBook] = {}
        self.running = True
        
        # Universe tracking: instrument -> info
        self.binance_universe: Dict[str, Dict[str, Any]] = {}
        self.hyperliquid_universe: Dict[str, Dict[str, Any]] = {}
        self.last_screen_day: str = ""

    def _init_downtime_log(self):
        if not os.path.exists(self.downtime_log_path):
            with open(self.downtime_log_path, 'w', encoding='utf-8') as f:
                f.write("event,start_utc,end_utc,duration_sec,reason\n")

    def record_start(self):
        utc_now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
        print(f"BOT STARTED: {utc_now}")

    def screen_universe_if_needed(self):
        today_utc = datetime.now(timezone.utc).strftime("%Y-%m-%d")
        if today_utc != self.last_screen_day:
            print(f"[{today_utc}] Running daily universe screen...")
            b_list = screen_binance_universe(max_pairs=12, min_vol_usd=5_000_000.0, min_spread_bps=3.0)
            hl_list = screen_hyperliquid_universe(min_vol_usd=5_000_000.0, min_spread_bps=2.0)
            
            self.binance_universe = {x['instrument']: x for x in b_list}
            self.hyperliquid_universe = {x['instrument']: x for x in hl_list}
            self.last_screen_day = today_utc

            print(f"Screened {len(self.binance_universe)} Binance pairs: {list(self.binance_universe.keys())}")
            print(f"Screened {len(self.hyperliquid_universe)} Hyperliquid coins: {list(self.hyperliquid_universe.keys())}")

            # Register books
            for s in self.binance_universe:
                if s not in self.books:
                    self.books[s] = OrderBook(s, 'binance')
            for s in self.hyperliquid_universe:
                if s not in self.books:
                    self.books[s] = OrderBook(s, 'hyperliquid')

    async def run_binance_ws(self):
        while self.running:
            if not self.binance_universe:
                await asyncio.sleep(5)
                continue

            symbols = list(self.binance_universe.keys())
            # Streams: <symbol>@bookTicker / <symbol>@aggTrade / <symbol>@depth20@100ms
            streams = []
            for s in symbols:
                sl = s.lower()
                streams.append(f"{sl}@bookTicker")
                streams.append(f"{sl}@aggTrade")
                streams.append(f"{sl}@depth20@100ms")

            stream_str = "/".join(streams)
            url = f"wss://data-stream.binance.vision/stream?streams={stream_str}"
            print(f"Connecting to Binance streams for {len(symbols)} pairs...")
            
            try:
                async with websockets.connect(url, ping_interval=20, max_size=10**7) as ws:
                    print("Connected to Binance WebSocket stream successfully.")
                    while self.running:
                        msg = await ws.recv()
                        now_ms = int(time.time() * 1000)
                        data = json.loads(msg)
                        stream = data.get('stream', '')
                        payload = data.get('data', {})

                        if '@depth20' in stream:
                            s = payload.get('s')
                            if s in self.books:
                                bids = [(float(px), float(sz)) for px, sz in payload.get('bids', [])]
                                asks = [(float(px), float(sz)) for px, sz in payload.get('asks', [])]
                                self.books[s].update_bids_asks(bids, asks, now_ms)
                                # Evaluate quotes: min $10 notional, exchange minimum
                                mid = self.books[s].mid
                                sz = max(10.0 / mid if mid > 0 else 1.0, 0.1)
                                self.engine.update_quote_logic(self.books[s], now_ms, sz, min_spread_bps=3.0)

                        elif '@bookTicker' in stream:
                            s = payload.get('s')
                            if s in self.books:
                                b_px = float(payload.get('b', 0.0))
                                b_sz = float(payload.get('B', 0.0))
                                a_px = float(payload.get('a', 0.0))
                                a_sz = float(payload.get('A', 0.0))
                                if b_px > 0 and a_px > 0:
                                    # If book was empty, update
                                    if not self.books[s].bids or not self.books[s].asks:
                                        self.books[s].update_bids_asks([(b_px, b_sz)], [(a_px, a_sz)], now_ms)

                        elif '@aggTrade' in stream:
                            s = payload.get('s')
                            if s in self.books:
                                px = float(payload.get('p', 0.0))
                                sz = float(payload.get('q', 0.0))
                                is_buyer_maker = payload.get('m', False)
                                taker_side = 'SELL' if is_buyer_maker else 'BUY'
                                trade_time = payload.get('T', now_ms)
                                self.books[s].record_trade(trade_time, taker_side, sz)
                                self.engine.process_trade(self.books[s], trade_time, px, sz, taker_side)

            except Exception as e:
                print(f"Binance WS error: {e}. Reconnecting in 3s...")
                await asyncio.sleep(3)

    async def run_hyperliquid_ws(self):
        while self.running:
            if not self.hyperliquid_universe:
                await asyncio.sleep(5)
                continue

            coins = list(self.hyperliquid_universe.keys())
            url = "wss://api.hyperliquid.xyz/ws"
            print(f"Connecting to Hyperliquid streams for {len(coins)} coins...")
            
            try:
                async with websockets.connect(url, ping_interval=20, max_size=10**7) as ws:
                    print("Connected to Hyperliquid WebSocket stream successfully.")
                    # Subscribe to l2Book and trades for each coin
                    for coin in coins:
                        await ws.send(json.dumps({'method': 'subscribe', 'subscription': {'type': 'l2Book', 'coin': coin}}))
                        await ws.send(json.dumps({'method': 'subscribe', 'subscription': {'type': 'trades', 'coin': coin}}))

                    while self.running:
                        msg = await ws.recv()
                        now_ms = int(time.time() * 1000)
                        data = json.loads(msg)
                        channel = data.get('channel')

                        if channel == 'l2Book':
                            book_data = data.get('data', {})
                            coin = book_data.get('coin')
                            if coin in self.books:
                                levels = book_data.get('levels', [[], []])
                                bids = [(float(x['px']), float(x['sz'])) for x in levels[0]]
                                asks = [(float(x['px']), float(x['sz'])) for x in levels[1]]
                                self.books[coin].update_bids_asks(bids, asks, now_ms)
                                mid = self.books[coin].mid
                                sz = max(10.0 / mid if mid > 0 else 1.0, 0.01)
                                self.engine.update_quote_logic(self.books[coin], now_ms, sz, min_spread_bps=2.0)

                        elif channel == 'trades':
                            trades_list = data.get('data', [])
                            for tr in trades_list:
                                coin = tr.get('coin')
                                if coin in self.books:
                                    px = float(tr.get('px', 0.0))
                                    sz = float(tr.get('sz', 0.0))
                                    # In Hyperliquid trades: side is 'B' (buy) or 'A' (sell/ask)
                                    side_str = tr.get('side', '')
                                    taker_side = 'BUY' if side_str == 'B' else 'SELL'
                                    trade_time = tr.get('time', now_ms)
                                    self.books[coin].record_trade(trade_time, taker_side, sz)
                                    self.engine.process_trade(self.books[coin], trade_time, px, sz, taker_side)

            except Exception as e:
                print(f"Hyperliquid WS error: {e}. Reconnecting in 3s...")
                await asyncio.sleep(3)

    async def run_pending_exits_loop(self):
        """
        Periodically checks and records +1s/+10s/+60s mid and +10s far-touch exit.
        """
        while self.running:
            now_ms = int(time.time() * 1000)
            self.engine.check_pending_exits(self.books, now_ms)
            await asyncio.sleep(0.5)

    async def run_main(self):
        self.record_start()
        self.engine.restore_state()
        self.screen_universe_if_needed()

        tasks = [
            asyncio.create_task(self.run_binance_ws()),
            asyncio.create_task(self.run_hyperliquid_ws()),
            asyncio.create_task(self.run_pending_exits_loop())
        ]
        await asyncio.gather(*tasks)

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.abspath(__file__))
    bot = PaperMM2Bot(base_dir)
    try:
        asyncio.run(bot.run_main())
    except KeyboardInterrupt:
        print("Bot stopped by user.")
