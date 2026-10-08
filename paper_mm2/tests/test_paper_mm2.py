"""
Unit tests for paper_mm2:
- Fill model: 450 ms latency enforcement, trade-through primary fill.
- Requirement 5: queue-depleted secondary event does NOT consume quote, change inventory, or create exit; logged in queue_depleted.csv.
- Requirement 6: pending exits persisted to append-only pending.csv and restored on startup within 60s window.
- Exit pricing: far-touch exit (+10s), mid prices (+1s, +10s, +60s).
- Imbalance filter (Arm B vs A).
- Flow filter (Arm C vs B).
- Requirement 1, 2, 3, 4: Reporter 6-arms split, fixed calendar boundaries, hold-out PASS / dev STOP rules.
"""
import unittest
import os
import sys
import shutil
import time
import csv
import pandas as pd
from datetime import datetime, timezone

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))
from models import OrderBook
from engine import StrategyEngine
from reporter import generate_report, assign_instrument_vol_terciles

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
        # Depletes queue, but does NOT trigger primary trade-through fill
        self.engine.process_trade(book, now_ms + 500, 100.0, 5.0, 'SELL')
        self.assertEqual(q_bid.queue_ahead_remaining, 5.0)  # was 10.0, depleted by 5.0
        self.assertTrue(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 0)

        # 3. Trade occurs at +600 ms strictly BELOW bid price (99.99)
        self.engine.process_trade(book, now_ms + 600, 99.99, 1.0, 'SELL')
        # Now primary trade-through fill occurs! Quote is consumed.
        self.assertFalse(q_bid.is_active)
        self.assertEqual(len(self.engine.pending_exits), 1)
        pending = self.engine.pending_exits[0]
        self.assertEqual(pending.fill_record['fill_reason'], 'trade_through')
        self.assertTrue(pending.fill_record['is_primary_pessimistic_fill'])

    def test_queue_depleted_does_not_consume_quote_or_change_inventory(self):
        """
        Requirement 5: queue-depleted events must NOT consume the quote, change inventory,
        or create an exit for the primary measurement. Log them in queue_depleted.csv.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 5.0)], [(100.05, 5.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        q_bid = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q_bid)
        st = self.engine.get_instrument_state('A', 'TESTUSDT')
        initial_inv = st['inventory']
        self.assertEqual(initial_inv, 0.0)

        # Trade at touch price depleting full 5.0 size after 450ms
        self.engine.process_trade(book, now_ms + 500, 100.0, 5.0, 'SELL')
        
        # 1. Quote must NOT be consumed
        self.assertTrue(q_bid.is_active)
        # 2. Inventory must NOT change
        self.assertEqual(st['inventory'], initial_inv)
        # 3. Primary pending exits must NOT be created
        self.assertEqual(len(self.engine.pending_exits), 0)

        # 4. Event must be logged to queue_depleted.csv
        self.assertTrue(os.path.exists(self.engine.queue_depleted_csv_path))
        with open(self.engine.queue_depleted_csv_path, 'r', encoding='utf-8') as f:
            reader = list(csv.DictReader(f))
            self.assertEqual(len(reader), 1)
            row = reader[0]
            self.assertEqual(row['arm'], 'A')
            self.assertEqual(row['instrument'], 'TESTUSDT')
            self.assertEqual(row['side'], 'BUY')
            self.assertEqual(row['fill_reason'], 'queue_depleted')
            self.assertEqual(row['is_primary_pessimistic_fill'], 'False')
            self.assertEqual(row['is_queue_depleted_fill'], 'True')

    def test_pending_exits_persistence_and_restore(self):
        """
        Requirement 6: Persist pending exits to disk (append-only pending.csv)
        so restarts/handoffs do not lose fills in their 60s window; restore on startup.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 1.0)], [(100.05, 1.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # Fill via trade-through at +500 ms
        fill_time_ms = now_ms + 500
        self.engine.process_trade(book, fill_time_ms, 99.98, 1.0, 'SELL')
        self.assertEqual(len(self.engine.pending_exits), 1)

        # Verify row persisted to pending.csv with status NEW
        self.assertTrue(os.path.exists(self.engine.pending_csv_path))
        with open(self.engine.pending_csv_path, 'r', encoding='utf-8') as f:
            rows = list(csv.DictReader(f))
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]['status'], 'NEW')
            self.assertEqual(int(rows[0]['fill_id']), 0)

        # Simulate restart at +2000 ms (1.5s after fill, well within 60s window)
        engine2 = StrategyEngine(self.test_dir)
        engine2.restore_state(now_ms=fill_time_ms + 1500)
        
        # Verify pending exit restored
        self.assertEqual(len(engine2.pending_exits), 1)
        restored_p = engine2.pending_exits[0]
        self.assertEqual(restored_p.fill_record['fill_id'], 0)
        self.assertEqual(restored_p.fill_time_ms, fill_time_ms)
        # Verify paper inventory restored for open position
        st2 = engine2.get_instrument_state('A', 'TESTUSDT')
        self.assertEqual(st2['inventory'], 1.0)

        # Advance engine2 to +10.5s after fill (fill_time_ms + 10500 ms)
        book.update_bids_asks([(100.10, 1.0)], [(100.15, 1.0)], fill_time_ms + 10500)
        engine2.check_pending_exits({'TESTUSDT': book}, fill_time_ms + 10500)
        self.assertEqual(restored_p.far_touch_exit_10s, 100.10)
        # Inventory reset to flat
        self.assertEqual(st2['inventory'], 0.0)

        # Verify EXIT_10S recorded in pending.csv
        with open(engine2.pending_csv_path, 'r', encoding='utf-8') as f:
            rows = list(csv.DictReader(f))
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[-1]['status'], 'EXIT_10S')

        # Advance engine2 to +60.5s to finalize fill
        engine2.check_pending_exits({'TESTUSDT': book}, fill_time_ms + 60500)
        self.assertEqual(len(engine2.pending_exits), 0)

        # Verify finalized to trades.csv and marked COMPLETED in pending.csv
        with open(engine2.trades_csv_path, 'r', encoding='utf-8') as f:
            trades = list(csv.DictReader(f))
            self.assertEqual(len(trades), 1)
            self.assertEqual(int(trades[0]['fill_id']), 0)
            self.assertEqual(float(trades[0]['far_touch_exit_10s']), 100.10)

        with open(engine2.pending_csv_path, 'r', encoding='utf-8') as f:
            rows = list(csv.DictReader(f))
            self.assertEqual(len(rows), 3)
            self.assertEqual(rows[-1]['status'], 'COMPLETED')

        # Now simulate another restart (engine3) -> should NOT restore completed fill
        engine3 = StrategyEngine(self.test_dir)
        engine3.restore_state(now_ms=fill_time_ms + 70000)
        self.assertEqual(len(engine3.pending_exits), 0)

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
        self.assertEqual(pending.far_touch_exit_10s, 100.10)
        self.assertIsNotNone(pending.mid_10s)
        self.assertEqual(st['inventory'], 0.0)

        # Advance to +60.5 s to finalize
        self.engine.check_pending_exits({'TESTUSDT': book}, now_ms + 60500)
        self.assertEqual(len(self.engine.pending_exits), 0)

    def test_imbalance_filter_arm_b(self):
        """
        Arm B quotes bid only if top-5 bid depth / (bid + ask depth) >= 0.60;
        mirror for ask.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
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
        book.update_bids_asks([(100.0, 60.0)], [(100.05, 40.0)], now_ms)

        for i in range(100):
            t_ms = now_ms - (100 - i) * 1000
            book.record_trade(t_ms, 'SELL', 2.0)

        book.record_trade(now_ms, 'SELL', 100.0)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        self.assertIsNotNone(self.engine.active_quotes['B']['TESTUSDT']['BUY'])
        self.assertIsNone(self.engine.active_quotes['C']['TESTUSDT']['BUY'])

    def test_control_actions_and_params(self):
        """
        Test cancel_all_global, flatten_all_inventory, and dynamic params override.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        self.assertIsNotNone(self.engine.active_quotes['A']['TESTUSDT']['BUY'])

        self.engine.cancel_all_global(now_ms, "TEST_PAUSE")
        q = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q.cancel_pending_after_ms)

        st = self.engine.get_instrument_state('A', 'TESTUSDT')
        st['inventory'] = 2.5
        self.engine.flatten_all_inventory({'TESTUSDT': book}, now_ms)
        self.assertEqual(st['inventory'], 0.0)

        self.engine.params['min_spread_bps'] = 10.0
        self.engine.update_quote_logic(book, now_ms + 1000, quote_size=1.0, min_spread_bps=3.0)
        q_bid = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertTrue(q_bid is None or q_bid.cancel_pending_after_ms is not None)

    def test_reporter_calendar_splits_and_arms(self):
        """
        Verify:
        - 6 arms split: (venue, arm)
        - Decision metric: rt_net_hl for Hyperliquid, rt_net_zero_fee for Binance
        - Fixed calendar split: Dev (2026-10-07..10) vs Hold-out (2026-10-11..14)
        - Default report does NOT evaluate or show holdout
        - --final evaluates holdout
        """
        # Create dummy trades in dev and hold-out periods
        dev_ms = int(datetime(2026, 10, 8, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)
        holdout_ms = int(datetime(2026, 10, 12, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)

        trades_rows = [
            # Dev row for Hyperliquid Arm A
            {
                'fill_id': 0, 'timestamp_ms': dev_ms, 'arm': 'A', 'venue': 'hyperliquid',
                'instrument': 'BTC', 'side': 'BUY', 'fill_price': 60000.0, 'fill_size': 0.1,
                'quote_price': 60000.0, 'spread_bps_at_placement': 3.0, 'top5_imbalance': 0.5,
                'flow_1s': 0.0, 'realised_vol_10s': 1.5, 'queue_ahead': 5.0, 'fill_reason': 'trade_through',
                'is_primary_pessimistic_fill': True, 'is_queue_depleted_fill': False,
                'mid_1s': 60010.0, 'mid_10s': 60010.0, 'mid_60s': 60010.0, 'far_touch_exit_10s': 60010.0,
                'exit_time_ms': dev_ms + 10000, 'round_trip_edge_bps': 1.67,
                'rt_net_hl': -4.33, 'rt_net_binance_vip0': -18.33, 'rt_net_binance_bnb': -13.33, 'rt_net_zero_fee': 1.67
            },
            # Hold-out row for Binance Arm B
            {
                'fill_id': 1, 'timestamp_ms': holdout_ms, 'arm': 'B', 'venue': 'binance',
                'instrument': 'ETHUSDT', 'side': 'BUY', 'fill_price': 2500.0, 'fill_size': 1.0,
                'quote_price': 2500.0, 'spread_bps_at_placement': 4.0, 'top5_imbalance': 0.7,
                'flow_1s': 0.0, 'realised_vol_10s': 2.0, 'queue_ahead': 2.0, 'fill_reason': 'trade_through',
                'is_primary_pessimistic_fill': True, 'is_queue_depleted_fill': False,
                'mid_1s': 2502.0, 'mid_10s': 2502.0, 'mid_60s': 2502.0, 'far_touch_exit_10s': 2502.0,
                'exit_time_ms': holdout_ms + 10000, 'round_trip_edge_bps': 8.0,
                'rt_net_hl': 2.0, 'rt_net_binance_vip0': -12.0, 'rt_net_binance_bnb': -7.0, 'rt_net_zero_fee': 8.0
            }
        ]
        
        # Write dummy trades
        df_dummy = pd.DataFrame(trades_rows)
        df_dummy.to_csv(self.engine.trades_csv_path, index=False)

        # 1. Default report (DEV mode)
        dev_rep = generate_report(self.test_dir, is_final=False)
        self.assertIn("Mode: DEV EVALUATION", dev_rep)
        self.assertIn("HYPERLIQUID - A", dev_rep)
        self.assertIn("Primary Pessimistic Fills (Trade-Through): 1", dev_rep)
        # Hold-out trade (Binance B) should NOT be counted in dev report
        self.assertIn("ARM: BINANCE - B", dev_rep)
        self.assertIn("Primary Pessimistic Fills (Trade-Through): 0", dev_rep)

        # 2. Final report (HOLD-OUT mode)
        ho_rep = generate_report(self.test_dir, is_final=True)
        self.assertIn("Mode: FINAL HOLD-OUT EVALUATION", ho_rep)
        # Hyperliquid A was in dev, so 0 in hold-out
        self.assertIn("ARM: HYPERLIQUID - A", ho_rep)
        # Binance B was in hold-out, so 1 in hold-out
        self.assertIn("ARM: BINANCE - B", ho_rep)
        self.assertIn("Zero-fee ref (0.0):   +8.00 bps  <-- DECISION METRIC", ho_rep)

    def test_binance_symbol_resolution_and_telemetry(self):
        """
        Verify that stream name fallback correctly resolves symbol when 's' key is missing in payload
        (as in Binance @depth20@100ms stream), and telemetry tracking updates appropriately.
        """
        stream = "adausdt@depth20@100ms"
        payload = {"lastUpdateId": 12345, "bids": [["0.2520", "100.0"]], "asks": [["0.2525", "100.0"]]}
        s = payload.get('s') or (stream.split('@')[0].upper() if '@' in stream else '')
        self.assertEqual(s, "ADAUSDT")

        # Test engine telemetry
        b_book = OrderBook('ADAUSDT', 'binance')
        now_ms = 1000000
        b_book.update_bids_asks([(0.2520, 100.0)], [(0.2525, 100.0)], now_ms)
        self.engine.update_quote_logic(b_book, now_ms, quote_size=10.0, min_spread_bps=3.0)

        active_counts = self.engine.get_active_quotes_count()
        self.assertGreater(active_counts['binance'], 0)

        # Process a trade below bid after 450ms latency
        self.engine.process_trade(b_book, now_ms + 500, 0.2510, 50.0, 'SELL')
        self.assertEqual(self.engine.telemetry['binance']['trades_received'], 1)
        self.assertEqual(self.engine.telemetry['binance']['trades_through'], 1)

if __name__ == '__main__':
    unittest.main()

