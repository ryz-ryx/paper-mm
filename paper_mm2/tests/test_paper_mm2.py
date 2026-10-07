"""
Unit tests for paper_mm2:
- Fill model: 450 ms latency enforcement, trade-through primary fill, queue-depleted secondary fill.
- Exit pricing: far-touch exit (+10s), mid prices (+1s, +10s, +60s).
- Imbalance filter (Arm B vs A).
- Flow filter (Arm C vs B).
"""
import unittest
import os
import sys
import shutil
import time

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from models import OrderBook
from engine import StrategyEngine

class TestPaperMM2(unittest.TestCase):
    def setUp(self):
        self.test_dir = os.path.join(os.path.dirname(__file__), "test_data")
        if os.path.exists(self.test_dir):
            shutil.rmtree(self.test_dir)
        os.makedirs(self.test_dir, exist_ok=True)
        self.engine = StrategyEngine(self.test_dir)

    def tearDown(self):
        if os.path.exists(self.test_dir):
            shutil.rmtree(self.test_dir)

    def test_latency_and_fill_model(self):
        """
        Test that resting bid does not fill before 450 ms,
        and fills ONLY on trade-through (trade printed strictly below bid price).
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        # Spread: 100.0 / 100.05 => spread 5 bps (>= 3 bps)
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Confirm quotes placed for Arm A
        q_bid = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q_bid)
        self.assertEqual(q_bid.price, 100.0)
        self.assertEqual(q_bid.live_after_ms, now_ms + 450)

        # 1. Trade occurs BEFORE 450 ms (e.g. at +200 ms) strictly below bid price (99.98)
        self.engine.process_trade(book, now_ms + 200, 99.98, 1.0, 'SELL')
        # Should NOT fill because latency has not elapsed
        self.assertTrue(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 0)

        # 2. Trade occurs AFTER 450 ms (at +500 ms) but AT the bid price (100.0)
        # Should deplete queue, but NOT trigger primary pessimistic trade-through fill
        self.engine.process_trade(book, now_ms + 500, 100.0, 5.0, 'SELL')
        self.assertEqual(q_bid.queue_ahead_remaining, 5.0)  # was 10.0, depleted by 5.0
        self.assertTrue(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 0)

        # 3. Trade occurs at +600 ms strictly BELOW bid price (99.99)
        self.engine.process_trade(book, now_ms + 600, 99.99, 1.0, 'SELL')
        # Now primary trade-through fill occurs!
        self.assertFalse(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 1)
        pending = self.engine.pending_exits[0]
        self.assertEqual(pending.fill_record['fill_reason'], 'trade_through')
        self.assertTrue(pending.fill_record['is_primary_pessimistic_fill'])

    def test_queue_depleted_secondary_fill(self):
        """
        Test that when trade volume completely depletes queue ahead at bid price,
        it registers as queue_depleted fill.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 5.0)], [(100.05, 5.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        q_bid = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q_bid)
        
        # Trade at touch price depleting full 5.0 size after 450ms
        self.engine.process_trade(book, now_ms + 500, 100.0, 5.0, 'SELL')
        self.assertFalse(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 1)
        pending = self.engine.pending_exits[0]
        self.assertEqual(pending.fill_record['fill_reason'], 'queue_depleted')
        self.assertFalse(pending.fill_record['is_primary_pessimistic_fill'])
        self.assertTrue(pending.fill_record['is_queue_depleted_fill'])

    def test_exit_pricing_and_inventory_reset(self):
        """
        Verify that at +10s, far-touch exit is recorded (sell at bid for long fill)
        and inventory resets to flat.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 1.0)], [(100.05, 1.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Fill long at 100.0 via trade-through at 99.98
        self.engine.process_trade(book, now_ms + 500, 99.98, 1.0, 'SELL')
        st = self.engine.get_instrument_state('A', 'TESTUSDT')
        self.assertEqual(st['inventory'], 1.0)

        # Advance time to +10.5 s (10500 ms) and update book
        book.update_bids_asks([(100.10, 1.0)], [(100.15, 1.0)], now_ms + 10500)
        self.engine.check_pending_exits({'TESTUSDT': book}, now_ms + 10500)

        pending = self.engine.pending_exits[0]
        # For a long fill, far-touch exit is current best bid (100.10)
        self.assertEqual(pending.far_touch_exit_10s, 100.10)
        self.assertIsNotNone(pending.mid_10s)
        # Inventory must reset to flat (0.0)
        self.assertEqual(st['inventory'], 0.0)

        # Advance to +60.5 s to finalize
        self.engine.check_pending_exits({'TESTUSDT': book}, now_ms + 60500)
        # Should be logged and removed from pending
        self.assertEqual(len(self.engine.pending_exits), 0)

    def test_imbalance_filter_arm_b(self):
        """
        Arm B quotes bid only if top-5 bid depth / (bid + ask depth) >= 0.60;
        mirror for ask (top-5 ask depth ratio >= 0.60 => imbalance <= 0.40).
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        # Bid depth: 10, Ask depth: 90 => imbalance = 10/100 = 0.10 (< 0.60, so no bid; ask ratio = 0.90 >= 0.60 => ask allowed)
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 90.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Arm A quotes both
        self.assertIsNotNone(self.engine.active_quotes['A']['TESTUSDT']['BUY'])
        self.assertIsNotNone(self.engine.active_quotes['A']['TESTUSDT']['SELL'])

        # Arm B quotes only ASK, not BID
        self.assertIsNone(self.engine.active_quotes['B']['TESTUSDT']['BUY'])
        self.assertIsNotNone(self.engine.active_quotes['B']['TESTUSDT']['SELL'])

    def test_cancel_on_flow_filter_arm_c(self):
        """
        Arm C pulls bid if 1s taker-sell volume exceeds rolling 80th percentile.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        # Set balanced book with spread
        book.update_bids_asks([(100.0, 60.0)], [(100.05, 40.0)], now_ms)  # Imbalance = 0.60

        # Simulate 1 hour history of small trades (80th pct around 5.0)
        for i in range(100):
            t_ms = now_ms - (100 - i) * 1000
            book.record_trade(t_ms, 'SELL', 2.0)

        # Now massive taker sell of 100.0 occurs at now_ms
        book.record_trade(now_ms, 'SELL', 100.0)

        # Evaluate quote logic
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Arm B allows bid (imbalance is 0.60)
        self.assertIsNotNone(self.engine.active_quotes['B']['TESTUSDT']['BUY'])
        # Arm C pulls/disallows bid because taker sell volume > 80th percentile
        self.assertIsNone(self.engine.active_quotes['C']['TESTUSDT']['BUY'])

    def test_control_actions_and_params(self):
        """
        Test cancel_all_global, flatten_all_inventory, and dynamic params override.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Quotes active
        self.assertIsNotNone(self.engine.active_quotes['A']['TESTUSDT']['BUY'])

        # 1. Test cancel_all_global (e.g. paused)
        self.engine.cancel_all_global(now_ms, "TEST_PAUSE")
        q = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q.cancel_pending_after_ms)

        # 2. Test flatten_all_inventory
        st = self.engine.get_instrument_state('A', 'TESTUSDT')
        st['inventory'] = 2.5
        self.engine.flatten_all_inventory({'TESTUSDT': book}, now_ms)
        self.assertEqual(st['inventory'], 0.0)

        # 3. Test dynamic params
        self.engine.params['min_spread_bps'] = 10.0  # require 10 bps spread
        # current spread is 5 bps, so quotes should be cancelled / rejected
        self.engine.update_quote_logic(book, now_ms + 1000, quote_size=1.0, min_spread_bps=3.0)
        q_bid = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertTrue(q_bid is None or q_bid.cancel_pending_after_ms is not None)

if __name__ == '__main__':
    unittest.main()
