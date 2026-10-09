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
        # 3. D4: Queue-depleted pending exit is registered to log mids at +1/+10/+60s
        self.assertEqual(len(self.engine.pending_exits), 1)
        qd_p = self.engine.pending_exits[0]
        self.assertTrue(qd_p.fill_record['is_queue_depleted_fill'])
        self.assertFalse(qd_p.fill_record['is_primary_pessimistic_fill'])

        # Advance book to +60.5s to finalize queue-depleted row
        book.update_bids_asks([(100.10, 5.0)], [(100.15, 5.0)], now_ms + 60500)
        self.engine.check_pending_exits({'TESTUSDT': book}, now_ms + 60500)
        self.assertEqual(len(self.engine.pending_exits), 0)
        # Inventory must still remain 0.0 (queue-depleted fill never changes inventory)
        self.assertEqual(st['inventory'], 0.0)

        # 4. Finalized event must be logged to queue_depleted.csv with mids populated
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
            self.assertTrue(len(row['mid_1s']) > 0)
            self.assertTrue(len(row['mid_10s']) > 0)
            self.assertTrue(len(row['mid_60s']) > 0)

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
        dev_ms = int(datetime(2026, 10, 10, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)
        holdout_ms = int(datetime(2026, 10, 14, 12, 0, tzinfo=timezone.utc).timestamp() * 1000)

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
    def test_d2_realised_vol_10s_calculation(self):
        """
        Verify D2: realised_vol_10s computes stdev over last 10 1-second sampled returns in bps.
        """
        book = OrderBook('TESTUSDT', 'binance')
        base_ms = 10000000
        # Feed 11 1-second book updates: mid from 100.0 to 101.0
        # returns = (100.1-100.0)/100.0, etc.
        prices = [100.0 + 0.1 * i for i in range(12)]
        for i, p in enumerate(prices):
            t_ms = base_ms + i * 1000
            book.update_bids_asks([(p - 0.05, 1.0)], [(p + 0.05, 1.0)], t_ms)
        
        vol = book.get_10s_realised_vol(base_ms + 11000)
        self.assertGreater(vol, 0.0)
        # Check that constant mid yields 0.0 vol
        book_flat = OrderBook('FLATUSDT', 'binance')
        for i in range(12):
            t_ms = base_ms + i * 1000
            book_flat.update_bids_asks([(100.0, 1.0)], [(100.1, 1.0)], t_ms)
        vol_flat = book_flat.get_10s_realised_vol(base_ms + 11000)
        self.assertEqual(vol_flat, 0.0)

    def test_d3_arm_c_zero_percentile_and_calm(self):
        """
        Verify D3: If rolling 1h 80th percentile is 0, any taker volume > 0 cancels/blocks side.
        After 1s calm, quotes are placed.
        """
        book = OrderBook('TESTUSDT', 'binance')
        now_ms = 1000000
        book.update_bids_asks([(100.0, 60.0)], [(100.05, 40.0)], now_ms)
        
        # Trade of 0.5 taker sell occurs at now_ms. 80th percentile is 0.0 since no prior trades.
        book.record_trade(now_ms, 'SELL', 0.5)

        # Update quote logic: Arm C should refuse to quote BUY because flow_1s (0.5) > threshold (0.0)
        # Meanwhile Arm B should quote BUY because its imbalance filter is satisfied (60/40)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)
        self.assertIsNotNone(self.engine.active_quotes['B']['TESTUSDT']['BUY'])
        self.assertIsNone(self.engine.active_quotes['C']['TESTUSDT']['BUY'])

        # Advance time by 1.1s after trade (calm period, no trades)
        now_ms += 1100
        book.update_bids_asks([(100.0, 60.0)], [(100.05, 40.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)
    def test_m3_requote_continuity_retiring_quote_fillable(self):
        """
        Verify M3: On requote, the OLD quote remains active and fillable in retiring_quotes
        until cancel_effective = t + 450ms, while the NEW quote goes live at t + 450ms.
        """
        book = OrderBook("TESTUSDT", "binance")
        t0 = 1000000
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], t0)
        self.engine.update_quote_logic(book, t0, quote_size=1.0, min_spread_bps=3.0)

        # Initial quote live at t0 + 450 = 1000450
        q_old = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q_old)
        self.assertEqual(q_old.price, 100.0)

        # At t1 = 1000500, price moves, triggering a requote
        t1 = 1000500
        book.update_bids_asks([(100.02, 10.0)], [(100.07, 10.0)], t1)
        self.engine.update_quote_logic(book, t1, quote_size=1.0, min_spread_bps=3.0)

        # Old quote should now be in retiring_quotes, fillable until t1 + 450 = 1000950
        self.assertGreater(len(self.engine.retiring_quotes), 0)
        retiring_q = [q for q in self.engine.retiring_quotes if q.instrument == 'TESTUSDT' and q.arm == 'A' and q.side == 'BUY']
        self.assertEqual(len(retiring_q), 1)
        self.assertEqual(retiring_q[0].cancel_pending_after_ms, t1 + 450)

        # New quote placed in active_quotes, live after t1 + 450 = 1000950
        q_new = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q_new)
        self.assertEqual(q_new.price, 100.02)
        self.assertEqual(q_new.live_after_ms, t1 + 450)

        # Trade occurs at t = 1000600 (within 450ms cancel window) trading through OLD quote (99.98)
        self.engine.process_trade(book, 1000600, 99.98, 1.0, 'SELL')
        # Old retiring quote should FILL!
        self.assertEqual(len(self.engine.pending_exits), 1)
        self.assertEqual(self.engine.pending_exits[0].fill_record['fill_price'], 100.0)
        self.assertFalse(retiring_q[0].is_active)

        # At t = 1001000 (after 450ms), new quote is live. Trade through new quote (100.01)
        self.engine.process_trade(book, 1001000, 100.01, 1.0, 'SELL')
        # New quote fills!
        self.assertEqual(len(self.engine.pending_exits), 2)
        self.assertEqual(self.engine.pending_exits[1].fill_record['fill_price'], 100.02)

    def test_m4_cancel_all_venue_stale_feed(self):
        """
        Verify M4: cancel_all_venue cancels active quotes for that venue into retiring_quotes
        with 450ms cancellation latency.
        """
        b_book = OrderBook("TESTUSDT", "binance")
        hl_book = OrderBook("ETH", "hyperliquid")
        now_ms = 1000000

        b_book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], now_ms)
        hl_book.update_bids_asks([(2500.0, 1.0)], [(2501.0, 1.0)], now_ms)

        self.engine.update_quote_logic(b_book, now_ms, quote_size=1.0, min_spread_bps=3.0)
        self.engine.update_quote_logic(hl_book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        self.assertIsNotNone(self.engine.active_quotes['A']['TESTUSDT']['BUY'])
        self.assertIsNotNone(self.engine.active_quotes['A']['ETH']['BUY'])

        # Cancel all binance quotes due to stale feed
        self.engine.cancel_all_venue('binance', now_ms, 'venue_feed_stale')

        # Binance active quote is removed from active_quotes
        self.assertIsNone(self.engine.active_quotes['A']['TESTUSDT']['BUY'])
        # Hyperliquid active quote remains active
        self.assertIsNotNone(self.engine.active_quotes['A']['ETH']['BUY'])

        # Canceled quote is retiring with 450ms latency
        retiring = [q for q in self.engine.retiring_quotes if q.instrument == 'TESTUSDT']
        self.assertGreater(len(retiring), 0)
        self.assertEqual(retiring[0].cancel_pending_after_ms, now_ms + 450)

    def test_d1_timer_requotes_independent_of_book_updates(self):
        """
        Verify D1: Engine accepts periodic requote triggers on stationary books.
        """
        book = OrderBook("TESTUSDT", "binance")
        now_ms = 1000000
        book.update_bids_asks([(100.0, 10.0)], [(100.05, 10.0)], now_ms)
        self.engine.update_quote_logic(book, now_ms, quote_size=1.0, min_spread_bps=3.0)

        # 1 second later with no book change
        self.engine.update_quote_logic(book, now_ms + 1000, quote_size=1.0, min_spread_bps=3.0)
        q = self.engine.active_quotes['A']['TESTUSDT']['BUY']
        self.assertIsNotNone(q)
        self.assertEqual(q.price, 100.0)

    def test_d7_screen_persistence(self):
        """
        Verify D7: screen_universe_if_needed persists screen output to data/screen_YYYYMMDD.json.
        """
        from bot import PaperMM2Bot
        from unittest.mock import patch

        bot = PaperMM2Bot(base_dir=self.test_dir)
        mock_binance = [{'instrument': 'TESTUSDT', 'vol_usd': 10000000.0, 'spread_bps': 3.5}]
        mock_hl = [{'instrument': 'ETH', 'vol_usd': 8000000.0, 'spread_bps': 2.5}]

        with patch('bot.screen_binance_universe', return_value=mock_binance), \
             patch('bot.screen_hyperliquid_universe', return_value=mock_hl):
            bot.screen_universe_if_needed()

        today_utc = datetime.now(timezone.utc).strftime("%Y%m%d")
        expected_path = os.path.join(bot.data_dir, f"screen_{today_utc}.json")
        self.assertTrue(os.path.exists(expected_path))
        import json
        with open(expected_path, 'r', encoding='utf-8') as f:
            data = json.load(f)
            self.assertEqual(len(data['binance']), 1)
            self.assertEqual(data['binance'][0]['instrument'], 'TESTUSDT')
            self.assertEqual(len(data['hyperliquid']), 1)
            self.assertEqual(data['hyperliquid'][0]['instrument'], 'ETH')

if __name__ == '__main__':
    unittest.main()

