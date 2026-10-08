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
import subprocess
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
        
        # Determine CODE VERSION from git
        try:
            self.code_version = subprocess.check_output(
                ['git', 'rev-parse', 'HEAD'], cwd=self.base_dir, stderr=subprocess.DEVNULL
            ).decode('utf-8').strip()
        except Exception:
            self.code_version = "UNKNOWN"

        self.heartbeat_json_path = os.path.join(self.data_dir, "heartbeat.json")
        self.last_ws_msg_ms: Dict[str, int] = {'binance': 0, 'hyperliquid': 0}

        self.downtime_log_path = os.path.join(self.data_dir, "downtime.csv")
        self._init_downtime_log()

        self.control_json_path = os.path.join(self.base_dir, "control.json")
        self._init_control_json()

        self.engine = StrategyEngine(self.data_dir)
        self.books: Dict[str, OrderBook] = {}
        self.running = True
        self.is_paused = False
        
        # Universe tracking: instrument -> info
        self.binance_universe: Dict[str, Dict[str, Any]] = {}
        self.hyperliquid_universe: Dict[str, Dict[str, Any]] = {}
        self.last_screen_day: str = ""

    def _init_control_json(self):
        if not os.path.exists(self.control_json_path):
            init_ctl = {
                "paused": False,
                "kill": False,
                "flatten_now": False,
                "params": {
                    "quote_size_usd": 10.0,
                    "min_spread_bps": None,
                    "inventory_limit_mult": 3.0
                },
                "updated_ms": int(time.time() * 1000)
            }
            tmp = self.control_json_path + ".tmp"
            with open(tmp, 'w', encoding='utf-8') as f:
                json.dump(init_ctl, f, indent=2)
            os.replace(tmp, self.control_json_path)

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
                        self.last_ws_msg_ms['binance'] = now_ms
                        data = json.loads(msg)
                        stream = data.get('stream', '')
                        payload = data.get('data', {})
                        s = payload.get('s') or (stream.split('@')[0].upper() if '@' in stream else '')

                        if '@depth20' in stream:
                            if s in self.books:
                                bids = [(float(px), float(sz)) for px, sz in payload.get('bids', [])]
                                asks = [(float(px), float(sz)) for px, sz in payload.get('asks', [])]
                                self.books[s].update_bids_asks(bids, asks, now_ms)
                                if not self.is_paused:
                                    # Evaluate quotes: quote_size_usd notional
                                    mid = self.books[s].mid
                                    q_usd = float(self.engine.params.get('quote_size_usd', 10.0))
                                    sz = q_usd / mid if mid > 0 else 1.0
                                    self.engine.update_quote_logic(self.books[s], now_ms, sz, min_spread_bps=3.0)

                        elif '@bookTicker' in stream:
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
                        self.last_ws_msg_ms['hyperliquid'] = now_ms
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
                                if not self.is_paused:
                                    mid = self.books[coin].mid
                                    q_usd = float(self.engine.params.get('quote_size_usd', 10.0))
                                    sz = max(q_usd / mid if mid > 0 else 1.0, 0.01)
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

    async def run_control_poll_loop(self):
        """
        Polls paper_mm2/control.json every 1 s.
        Keys supported:
        - paused: cancel quotes, stop quoting.
        - flatten_now: flatten once, then reset the flag in the file.
        - kill: cancel everything, flatten, exit.
        - params: apply only whitelisted keys (quote_size_usd, min_spread_bps, inventory_limit_mult), log every change.
        """
        whitelisted_param_keys = {'quote_size_usd', 'min_spread_bps', 'inventory_limit_mult', 'inventory_limit', 'inventory_limits'}
        while self.running:
            try:
                if os.path.exists(self.control_json_path):
                    with open(self.control_json_path, 'r', encoding='utf-8') as f:
                        ctl = json.load(f)
                    
                    now_ms = int(time.time() * 1000)
                    needs_rewrite = False

                    # 1. kill switch: cancel everything, flatten, exit
                    if ctl.get('kill'):
                        print(f"[{now_ms}] CONTROL KILL SWITCH ACTIVATED. Cancelling all quotes, flattening, and shutting down.")
                        self.engine.cancel_all_global(now_ms, reason="CONTROL_KILL")
                        self.engine.flatten_all_inventory(self.books, now_ms)
                        self.running = False
                        break

                    # 2. paused: cancel quotes, stop quoting
                    new_paused = bool(ctl.get('paused', False))
                    if new_paused != self.is_paused:
                        self.is_paused = new_paused
                        if self.is_paused:
                            print(f"[{now_ms}] CONTROL: Bot PAUSED. Cancelling all quotes.")
                            self.engine.cancel_all_global(now_ms, reason="CONTROL_PAUSED")
                        else:
                            print(f"[{now_ms}] CONTROL: Bot RESUMED.")

                    # 3. flatten_now: flatten once, then reset flag in file
                    if ctl.get('flatten_now'):
                        print(f"[{now_ms}] CONTROL: FLATTEN_NOW triggered.")
                        self.engine.flatten_all_inventory(self.books, now_ms)
                        ctl['flatten_now'] = False
                        needs_rewrite = True

                    # 4. params: apply whitelisted keys only, log every change
                    incoming_params = ctl.get('params', {})
                    if isinstance(incoming_params, dict):
                        for k, v in incoming_params.items():
                            if k in whitelisted_param_keys:
                                # Normalize inventory limits key to inventory_limit_mult
                                target_k = 'inventory_limit_mult' if 'inventory_limit' in k else k
                                old_val = self.engine.params.get(target_k)
                                if old_val != v:
                                    self.engine.params[target_k] = v
                                    print(f"[{now_ms}] CONTROL PARAM CHANGE: {target_k} = {v} (was {old_val})")

                    if needs_rewrite:
                        tmp = self.control_json_path + ".tmp"
                        with open(tmp, 'w', encoding='utf-8') as f:
                            json.dump(ctl, f, indent=2)
                        os.replace(tmp, self.control_json_path)

            except Exception as e:
                print(f"Control polling error: {e}")

            await asyncio.sleep(1.0)

    async def run_pending_exits_loop(self):
        """
        Periodically checks and records +1s/+10s/+60s mid and +10s far-touch exit.
        """
        while self.running:
            now_ms = int(time.time() * 1000)
            self.engine.check_pending_exits(self.books, now_ms)
            await asyncio.sleep(0.5)

    async def run_heartbeat_loop(self):
        """
        Writes paper_mm2/data/heartbeat.json every 60 s.
        Includes: utc time, git commit SHA of running code, fills so far, last WebSocket message time per venue.
        """
        while self.running:
            try:
                now_utc = datetime.now(timezone.utc).isoformat()
                primary_finalized = 0
                if os.path.exists(self.engine.trades_csv_path):
                    try:
                        with open(self.engine.trades_csv_path, 'r', encoding='utf-8') as f:
                            primary_finalized = max(0, sum(1 for _ in f) - 1)
                    except Exception:
                        pass
                
                pending_count = len(self.engine.pending_exits)
                
                qd_count = 0
                if os.path.exists(self.engine.queue_depleted_csv_path):
                    try:
                        with open(self.engine.queue_depleted_csv_path, 'r', encoding='utf-8') as f:
                            qd_count = max(0, sum(1 for _ in f) - 1)
                    except Exception:
                        pass

                active_q_counts = self.engine.get_active_quotes_count()
                hb_data = {
                    "utc_time": now_utc,
                    "commit_sha": self.code_version,
                    "fills_so_far": {
                        "primary_trade_through_finalized": primary_finalized,
                        "pending_exits": pending_count,
                        "total_primary": primary_finalized + pending_count,
                        "queue_depleted": qd_count,
                        "next_fill_id": self.engine.next_fill_id
                    },
                    "active_quotes": active_q_counts,
                    "telemetry": self.engine.telemetry,
                    "last_ws_msg_time": {
                        "binance": datetime.fromtimestamp(self.last_ws_msg_ms['binance'] / 1000.0, timezone.utc).isoformat() if self.last_ws_msg_ms['binance'] > 0 else None,
                        "hyperliquid": datetime.fromtimestamp(self.last_ws_msg_ms['hyperliquid'] / 1000.0, timezone.utc).isoformat() if self.last_ws_msg_ms['hyperliquid'] > 0 else None
                    }
                }
                tmp_path = self.heartbeat_json_path + ".tmp"
                with open(tmp_path, 'w', encoding='utf-8') as f:
                    json.dump(hb_data, f, indent=2)
                os.replace(tmp_path, self.heartbeat_json_path)
                print(f"[HEARTBEAT {now_utc}] Active quotes: {active_q_counts} | Telemetry: {self.engine.telemetry} | Fills finalized: {primary_finalized}")
            except Exception as e:
                print(f"Error updating heartbeat.json: {e}")
            await asyncio.sleep(60.0)

    async def run_main(self):
        print(f"CODE VERSION: {self.code_version}")
        self.record_start()
        self.engine.restore_state()
        self.screen_universe_if_needed()

        tasks = [
            asyncio.create_task(self.run_binance_ws()),
            asyncio.create_task(self.run_hyperliquid_ws()),
            asyncio.create_task(self.run_pending_exits_loop()),
            asyncio.create_task(self.run_control_poll_loop()),
            asyncio.create_task(self.run_heartbeat_loop())
        ]
        await asyncio.gather(*tasks)

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.abspath(__file__))
    bot = PaperMM2Bot(base_dir)
    try:
        asyncio.run(bot.run_main())
    except KeyboardInterrupt:
        print("Bot stopped by user.")
