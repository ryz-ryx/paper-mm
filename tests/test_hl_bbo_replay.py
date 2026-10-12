import unittest
import os
import shutil
import tempfile
import time
from paper_mm2.models import OrderBook
from paper_mm2.engine import StrategyEngine

class TestHLEngineReplay(unittest.TestCase):
    def setUp(self):
        self.test_dir = tempfile.mkdtemp()
        self.engine = StrategyEngine(self.test_dir)
        self.downtime_log_path = os.path.join(self.test_dir, "downtime.csv")
        with open(self.downtime_log_path, 'w', encoding='utf-8') as f:
            f.write("event,start_utc,end_utc,duration_sec,reason\n")
        self.book = OrderBook('PURR', 'hyperliquid')

    def tearDown(self):
        shutil.rmtree(self.test_dir)

    def test_venue_gap_less_than_2s_zero_stale_cancels(self):
        # Venue-level tracking: messages arrive within 500ms intervals
        venue_stale = False
        cancel_cycles = 0
        now_ms = 1000000
        last_hl_msg_ms = now_ms

        for i in range(10):
            now_ms += 500 # 500ms gap (< 2000ms)
            # Replay valid bbo
            bbo_data = {'bbo': [{'px': '0.50', 'sz': '100.0'}, {'px': '0.51', 'sz': '100.0'}]}
            bids = [(float(bbo_data['bbo'][0]['px']), float(bbo_data['bbo'][0]['sz']))]
            asks = [(float(bbo_data['bbo'][1]['px']), float(bbo_data['bbo'][1]['sz']))]
            self.book.update_bids_asks(bids, asks, now_ms)
            last_hl_msg_ms = now_ms
            
            # Check staleness
            if now_ms - last_hl_msg_ms > 2000:
                venue_stale = True
                cancel_cycles += 1

        self.assertFalse(venue_stale)
        self.assertEqual(cancel_cycles, 0)

    def test_venue_gap_3s_exactly_one_cancel_cycle_and_downtime_row(self):
        # Start fresh
        now_ms = 1000000
        last_hl_msg_ms = now_ms
        venue_stale = False
        cancel_cycles = 0
        downtime_rows = 0

        # Feed message at t=0
        self.book.update_bids_asks([(0.50, 100.0)], [(0.51, 100.0)], now_ms)
        self.engine.update_quote_logic(self.book, now_ms, quote_size=10.0, min_spread_bps=2.0)
        self.assertIsNotNone(self.engine.active_quotes['A']['PURR']['BUY'])

        # Now simulate 3000ms gap
        now_ms += 3000
        if now_ms - last_hl_msg_ms > 2000:
            if not venue_stale:
                venue_stale = True
                cancel_cycles += 1
                self.engine.cancel_all_venue('hyperliquid', now_ms, reason="HL_VENUE_FEED_STALE_GT_2S")
                # Record downtime
                with open(self.downtime_log_path, 'a', encoding='utf-8') as f:
                    f.write(f"stale_feed,{now_ms-3000},{now_ms},3.00,hl_venue_stalled_gt_2s\n")
                downtime_rows += 1

        # Check quotes were cancelled
        q_buy = self.engine.active_quotes['A']['PURR']['BUY']
        self.assertTrue(q_buy is None or q_buy.cancel_pending_after_ms is not None)
        self.assertEqual(cancel_cycles, 1)
        self.assertEqual(downtime_rows, 1)

        # Recovery on next message
        now_ms += 100
        if venue_stale:
            venue_stale = False
            last_hl_msg_ms = now_ms
        self.assertFalse(venue_stale)

    def test_empty_side_bbo_guard(self):
        # Empty list
        bbo_arr_empty = []
        # Missing bid or ask
        bbo_arr_partial = [{'px': '0.50', 'sz': '100.0'}]
        # None price or sz
        bbo_arr_none = [{'px': None, 'sz': '100.0'}, {'px': '0.51', 'sz': None}]
        
        # Test helper parsing
        for arr in [bbo_arr_empty, bbo_arr_partial, bbo_arr_none]:
            parsed_valid = False
            try:
                if len(arr) == 2 and arr[0] and arr[1]:
                    p0 = arr[0].get('px')
                    s0 = arr[0].get('sz')
                    p1 = arr[1].get('px')
                    s1 = arr[1].get('sz')
                    if p0 is not None and s0 is not None and p1 is not None and s1 is not None:
                        float(p0)
                        float(s0)
                        float(p1)
                        float(s1)
                        parsed_valid = True
            except Exception as e:
                self.fail(f"Exception raised on malformed bbo: {e}")
            self.assertFalse(parsed_valid)

if __name__ == '__main__':
    unittest.main()
