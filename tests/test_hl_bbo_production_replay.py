import unittest
import os
import shutil
import tempfile
import json
from datetime import datetime, timezone

from paper_mm2.bot import PaperMM2Bot
from paper_mm2.models import OrderBook

class FakeClock:
    def __init__(self, start_ms: int = 1_000_000_000):
        self._current_ms = start_ms

    def now_ms(self) -> int:
        return self._current_ms

    def advance_ms(self, delta_ms: int):
        self._current_ms += delta_ms

class TestHLEngineProductionReplay(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.bot = PaperMM2Bot(self.test_dir)
        self.clock = FakeClock()
        # Mock universe with PURR
        self.bot.hyperliquid_universe = {'PURR': {'instrument': 'PURR', 'venue': 'hyperliquid'}}
        self.bot.books['PURR'] = OrderBook('PURR', 'hyperliquid')

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def _read_downtime_rows(self):
        if not os.path.exists(self.bot.downtime_log_path):
            return []
        with open(self.bot.downtime_log_path, 'r', encoding='utf-8') as f:
            lines = [line.strip() for line in f if line.strip()]
        return lines[1:]  # skip header

    def test_case_a_messages_every_500ms_zero_cancels_zero_downtime(self):
        """Case A: messages every 500 ms for 10 s => 0 cancels, 0 downtime rows"""
        cancel_calls = 0
        original_cancel = self.bot.engine.cancel_all_venue
        def mock_cancel(venue, now_ms, reason=""):
            nonlocal cancel_calls
            if venue == 'hyperliquid':
                cancel_calls += 1
            original_cancel(venue, now_ms, reason=reason)
        self.bot.engine.cancel_all_venue = mock_cancel

        for _ in range(20):  # 20 * 500ms = 10s
            self.clock.advance_ms(500)
            now_ms = self.clock.now_ms()
            msg = json.dumps({
                "channel": "bbo",
                "data": {
                    "coin": "PURR",
                    "time": now_ms,
                    "bbo": [{"px": "0.50", "sz": "100.0"}, {"px": "0.51", "sz": "100.0"}]
                }
            })
            self.bot.handle_hl_ws_message(msg, now_ms)
            self.bot._hl_check_stale(now_ms)

        self.assertFalse(self.bot.venue_stale['hyperliquid'])
        self.assertEqual(cancel_calls, 0)
        self.assertEqual(len(self._read_downtime_rows()), 0)

    def test_case_b_3s_gap_one_cancel_one_downtime_row_and_recovery(self):
        """Case B: 3.0 s gap => exactly 1 cancel_all_venue('hyperliquid'), exactly 1 row in downtime.csv,
        quotes cancelled, venue_stale True; next bbo message recovers with correct duration"""
        cancel_calls = 0
        original_cancel = self.bot.engine.cancel_all_venue
        def mock_cancel(venue, now_ms, reason=""):
            nonlocal cancel_calls
            if venue == 'hyperliquid':
                cancel_calls += 1
            original_cancel(venue, now_ms, reason=reason)
        self.bot.engine.cancel_all_venue = mock_cancel

        now_ms = self.clock.now_ms()
        # Seed initial quote
        init_msg = json.dumps({
            "channel": "bbo",
            "data": {
                "coin": "PURR",
                "time": now_ms,
                "bbo": [{"px": "0.50", "sz": "100.0"}, {"px": "0.51", "sz": "100.0"}]
            }
        })
        self.bot.handle_hl_ws_message(init_msg, now_ms)
        self.assertIsNotNone(self.bot.engine.active_quotes['A']['PURR']['BUY'])

        # Advance fake clock by 3000ms
        self.clock.advance_ms(3000)
        gap_now_ms = self.clock.now_ms()
        self.bot._hl_check_stale(gap_now_ms)

        self.assertTrue(self.bot.venue_stale['hyperliquid'])
        self.assertEqual(cancel_calls, 1)
        q_buy = self.bot.engine.active_quotes['A']['PURR']['BUY']
        self.assertTrue(q_buy is None or q_buy.cancel_pending_after_ms is not None)

        # Recovery on next bbo message
        self.clock.advance_ms(100)
        rec_now_ms = self.clock.now_ms()
        rec_msg = json.dumps({
            "channel": "bbo",
            "data": {
                "coin": "PURR",
                "time": rec_now_ms,
                "bbo": [{"px": "0.50", "sz": "100.0"}, {"px": "0.51", "sz": "100.0"}]
            }
        })
        self.bot.handle_hl_ws_message(rec_msg, rec_now_ms)
        self.assertFalse(self.bot.venue_stale['hyperliquid'])
        # Ensure no additional cancel call occurred
        self.assertEqual(cancel_calls, 1)

        # Verify downtime row
        rows = self._read_downtime_rows()
        self.assertEqual(len(rows), 1)
        parts = rows[0].split(',')
        self.assertEqual(parts[0], "stale_feed")
        dur = float(parts[3])
        self.assertAlmostEqual(dur, 3.10, places=2)

    def test_case_c_trades_message_during_stale_clears_it(self):
        """Case C: trades message during stale clears it exactly as bbo does"""
        now_ms = self.clock.now_ms()
        init_msg = json.dumps({
            "channel": "bbo",
            "data": {
                "coin": "PURR",
                "time": now_ms,
                "bbo": [{"px": "0.50", "sz": "100.0"}, {"px": "0.51", "sz": "100.0"}]
            }
        })
        self.bot.handle_hl_ws_message(init_msg, now_ms)

        # Advance fake clock by 2500ms -> triggers stall
        self.clock.advance_ms(2500)
        stall_now_ms = self.clock.now_ms()
        self.bot._hl_check_stale(stall_now_ms)
        self.assertTrue(self.bot.venue_stale['hyperliquid'])

        # Trades message arrives during stale
        self.clock.advance_ms(200)
        trade_now_ms = self.clock.now_ms()
        trade_msg = json.dumps({
            "channel": "trades",
            "data": [{
                "coin": "PURR",
                "side": "B",
                "px": "0.505",
                "sz": "10.0",
                "time": trade_now_ms
            }]
        })
        self.bot.handle_hl_ws_message(trade_msg, trade_now_ms)
        self.assertFalse(self.bot.venue_stale['hyperliquid'])
        rows = self._read_downtime_rows()
        self.assertEqual(len(rows), 1)

    def test_case_d_malformed_bbo_guarded_and_does_not_reset_stale_timer(self):
        """Case D: malformed bbo (empty, 1-sided, None px/sz, non-numeric) through the real handler
        => no exception, book unchanged, M4 timer not reset by the malformed message"""
        now_ms = self.clock.now_ms()
        init_msg = json.dumps({
            "channel": "bbo",
            "data": {
                "coin": "PURR",
                "time": now_ms,
                "bbo": [{"px": "0.50", "sz": "100.0"}, {"px": "0.51", "sz": "100.0"}]
            }
        })
        self.bot.handle_hl_ws_message(init_msg, now_ms)
        prev_update_ms = self.bot.last_book_update_ms['hyperliquid']
        prev_bid = self.bot.books['PURR'].best_bid

        malformed_payloads = [
            # empty
            {"channel": "bbo", "data": {"coin": "PURR", "bbo": []}},
            # 1-sided
            {"channel": "bbo", "data": {"coin": "PURR", "bbo": [{"px": "0.52", "sz": "100.0"}]}},
            # None px
            {"channel": "bbo", "data": {"coin": "PURR", "bbo": [{"px": None, "sz": "100.0"}, {"px": "0.53", "sz": "100.0"}]}},
            # None sz
            {"channel": "bbo", "data": {"coin": "PURR", "bbo": [{"px": "0.52", "sz": None}, {"px": "0.53", "sz": "100.0"}]}},
            # non-numeric
            {"channel": "bbo", "data": {"coin": "PURR", "bbo": [{"px": "bad_price", "sz": "100.0"}, {"px": "0.53", "sz": "100.0"}]}},
            # missing data dict
            {"channel": "bbo", "data": None}
        ]

        for p in malformed_payloads:
            self.clock.advance_ms(100)
            cur_ms = self.clock.now_ms()
            try:
                self.bot.handle_hl_ws_message(json.dumps(p), cur_ms)
            except Exception as e:
                self.fail(f"Malformed payload raised unexpected exception: {e}")

            # Book unchanged
            self.assertEqual(self.bot.books['PURR'].best_bid, prev_bid)
            # M4 timer not reset by malformed message
            self.assertEqual(self.bot.last_book_update_ms['hyperliquid'], prev_update_ms)

if __name__ == '__main__':
    unittest.main()
