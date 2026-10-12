import os
import json
import tempfile
import pandas as pd
import pytest
from datetime import datetime, timezone
from paper_mm2.reporter import load_venue_boundaries, filter_df_for_venue_window, generate_report

def test_venue_boundaries_loading():
    with tempfile.TemporaryDirectory() as tmpdir:
        epoch_path = os.path.join(tmpdir, "EPOCH.json")
        epoch_content = {
            "venues": {
                "binance": {
                    "dev_start": "2026-10-09",
                    "dev_end": "2026-10-12",
                    "holdout_start": "2026-10-13",
                    "holdout_end": "2026-10-18"
                },
                "hyperliquid": {
                    "epoch_start": "2026-10-12T09:08:48Z",
                    "dev_start": "2026-10-12T09:08:48Z",
                    "dev_end": "2026-10-14T09:08:48Z",
                    "holdout_start": "2026-10-14T09:08:48Z",
                    "holdout_end": "2026-10-20T09:08:48Z"
                }
            }
        }
        with open(epoch_path, 'w', encoding='utf-8') as f:
            json.dump(epoch_content, f)

        bounds = load_venue_boundaries(tmpdir)
        assert bounds['hyperliquid']['epoch_start'] == datetime(2026, 10, 12, 9, 8, 48, tzinfo=timezone.utc)
        assert bounds['hyperliquid']['dev_end'] == datetime(2026, 10, 14, 9, 8, 48, tzinfo=timezone.utc)
        assert bounds['binance']['holdout_start'] == datetime(2026, 10, 13, 0, 0, 0, tzinfo=timezone.utc)

def test_hyperliquid_pre_epoch_exclusion():
    bounds = {
        'binance': {
            'dev_start': datetime(2026, 10, 9, 0, 0, 0, tzinfo=timezone.utc),
            'dev_end': datetime(2026, 10, 12, 23, 59, 59, 999999, tzinfo=timezone.utc),
            'holdout_start': datetime(2026, 10, 13, 0, 0, 0, tzinfo=timezone.utc),
            'holdout_end': datetime(2026, 10, 18, 23, 59, 59, 999999, tzinfo=timezone.utc),
        },
        'hyperliquid': {
            'epoch_start': datetime(2026, 10, 12, 9, 8, 48, tzinfo=timezone.utc),
            'dev_start': datetime(2026, 10, 12, 9, 8, 48, tzinfo=timezone.utc),
            'dev_end': datetime(2026, 10, 14, 9, 8, 48, tzinfo=timezone.utc),
            'holdout_start': datetime(2026, 10, 14, 9, 8, 48, tzinfo=timezone.utc),
            'holdout_end': datetime(2026, 10, 20, 9, 8, 48, tzinfo=timezone.utc),
        }
    }

    # Simulate rows: pre-epoch HL, post-epoch HL, and valid Binance
    ts_pre_epoch = int(datetime(2026, 10, 12, 8, 30, 0, tzinfo=timezone.utc).timestamp() * 1000)
    ts_post_epoch = int(datetime(2026, 10, 12, 10, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)
    ts_binance = int(datetime(2026, 10, 11, 12, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)

    df = pd.DataFrame([
        {'fill_id': 'hl_old', 'venue': 'hyperliquid', 'arm': 'A', 'timestamp_ms': ts_pre_epoch, 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 2.0, 'rt_net_hl': -4.0},
        {'fill_id': 'hl_new', 'venue': 'hyperliquid', 'arm': 'A', 'timestamp_ms': ts_post_epoch, 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 3.0, 'rt_net_hl': -3.0},
        {'fill_id': 'bn_valid', 'venue': 'binance', 'arm': 'A', 'timestamp_ms': ts_binance, 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 1.0, 'rt_net_zero_fee': 1.0},
    ])
    df['dt'] = pd.to_datetime(df['timestamp_ms'], unit='ms', utc=True)

    # Filter HL dev window
    hl_dev = filter_df_for_venue_window(df, 'hyperliquid', bounds, is_final=False)
    assert len(hl_dev) == 1
    assert hl_dev.iloc[0]['fill_id'] == 'hl_new'

    # Filter Binance dev window
    bn_dev = filter_df_for_venue_window(df, 'binance', bounds, is_final=False)
    assert len(bn_dev) == 1
    assert bn_dev.iloc[0]['fill_id'] == 'bn_valid'

    # Filter HL holdout window (ts_post_epoch is dev, so 0 rows in holdout)
    hl_ho = filter_df_for_venue_window(df, 'hyperliquid', bounds, is_final=True)
    assert len(hl_ho) == 0

def test_generate_report_end_to_end():
    with tempfile.TemporaryDirectory() as tmpdir:
        base_dir = tmpdir
        data_dir = os.path.join(base_dir, "data")
        os.makedirs(data_dir, exist_ok=True)

        epoch_path = os.path.join(base_dir, "EPOCH.json")
        epoch_content = {
            "venues": {
                "binance": {
                    "dev_start": "2026-10-09",
                    "dev_end": "2026-10-12",
                    "holdout_start": "2026-10-13",
                    "holdout_end": "2026-10-18"
                },
                "hyperliquid": {
                    "epoch_start": "2026-10-12T09:08:48Z",
                    "dev_start": "2026-10-12T09:08:48Z",
                    "dev_end": "2026-10-14T09:08:48Z",
                    "holdout_start": "2026-10-14T09:08:48Z",
                    "holdout_end": "2026-10-20T09:08:48Z"
                }
            }
        }
        with open(epoch_path, 'w', encoding='utf-8') as f:
            json.dump(epoch_content, f)

        # Write dummy trades.csv
        ts_old_hl = int(datetime(2026, 10, 12, 7, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)
        ts_new_hl = int(datetime(2026, 10, 12, 10, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)
        df_trades = pd.DataFrame([
            {'fill_id': '1', 'venue': 'hyperliquid', 'arm': 'A', 'instrument': 'BTC', 'timestamp_ms': ts_old_hl, 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 2.0, 'rt_net_hl': -4.0, 'realised_vol_10s': 0.001},
            {'fill_id': '2', 'venue': 'hyperliquid', 'arm': 'A', 'instrument': 'BTC', 'timestamp_ms': ts_new_hl, 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 2.5, 'rt_net_hl': -3.5, 'realised_vol_10s': 0.001},
        ])
        df_trades.to_csv(os.path.join(data_dir, "trades.csv"), index=False)

        rep = generate_report(data_dir, is_final=False)
        assert "Primary Pessimistic Fills (Trade-Through): 1" in rep
        assert "epoch_start: 2026-10-12 09:08:48 UTC" in rep

def test_recovered_data_deduplication():
    with tempfile.TemporaryDirectory() as tmpdir:
        base_dir = tmpdir
        data_dir = os.path.join(base_dir, "data")
        rec_dir = os.path.join(base_dir, "data_recovered")
        os.makedirs(data_dir, exist_ok=True)
        os.makedirs(rec_dir, exist_ok=True)

        epoch_path = os.path.join(base_dir, "EPOCH.json")
        epoch_content = {
            "venues": {
                "binance": {
                    "dev_start": "2026-10-09",
                    "dev_end": "2026-10-12",
                    "holdout_start": "2026-10-13",
                    "holdout_end": "2026-10-18"
                },
                "hyperliquid": {
                    "epoch_start": "2026-10-12T09:08:48Z",
                    "dev_start": "2026-10-12T09:08:48Z",
                    "dev_end": "2026-10-14T09:08:48Z",
                    "holdout_start": "2026-10-14T09:08:48Z",
                    "holdout_end": "2026-10-20T09:08:48Z"
                }
            }
        }
        with open(epoch_path, 'w', encoding='utf-8') as f:
            json.dump(epoch_content, f)

        # ts in dev window for Binance
        ts1 = int(datetime(2026, 10, 11, 10, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)
        ts2 = int(datetime(2026, 10, 11, 11, 0, 0, tzinfo=timezone.utc).timestamp() * 1000)

        # live trades: contains row 1
        df_live = pd.DataFrame([
            {'fill_id': 'f1', 'timestamp_ms': ts1, 'venue': 'binance', 'arm': 'A', 'instrument': 'BTCUSDT', 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 2.0, 'rt_net_zero_fee': 2.0, 'realised_vol_10s': 0.001}
        ])
        df_live.to_csv(os.path.join(data_dir, "trades.csv"), index=False)

        # recovered trades: contains row 1 (duplicate) and row 2 (new recovered row)
        df_rec = pd.DataFrame([
            {'fill_id': 'f1', 'timestamp_ms': ts1, 'venue': 'binance', 'arm': 'A', 'instrument': 'BTCUSDT', 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 2.0, 'rt_net_zero_fee': 2.0, 'realised_vol_10s': 0.001},
            {'fill_id': 'f2', 'timestamp_ms': ts2, 'venue': 'binance', 'arm': 'A', 'instrument': 'ETHUSDT', 'is_primary_pessimistic_fill': True, 'round_trip_edge_bps': 3.0, 'rt_net_zero_fee': 3.0, 'realised_vol_10s': 0.001}
        ])
        df_rec.to_csv(os.path.join(rec_dir, "trades_recovered.csv"), index=False)

        rep = generate_report(data_dir, is_final=False)
        # Should have exactly 2 fills (f1 once, f2 once), NOT 3
        assert "Primary Pessimistic Fills (Trade-Through): 2" in rep
        assert "Trades in Window: 2 (binance: 2 trades" in rep

def test_gap_exclusion_from_quote_denominator():
    import gzip
    with tempfile.TemporaryDirectory() as tmpdir:
        base_dir = tmpdir
        data_dir = os.path.join(base_dir, "data")
        rec_dir = os.path.join(base_dir, "data_recovered")
        quotes_dir = os.path.join(data_dir, "quotes")
        os.makedirs(data_dir, exist_ok=True)
        os.makedirs(rec_dir, exist_ok=True)
        os.makedirs(quotes_dir, exist_ok=True)

        epoch_path = os.path.join(base_dir, "EPOCH.json")
        epoch_content = {
            "venues": {
                "binance": {
                    "dev_start": "2026-10-09",
                    "dev_end": "2026-10-12",
                    "holdout_start": "2026-10-13",
                    "holdout_end": "2026-10-18"
                },
                "hyperliquid": {
                    "epoch_start": "2026-10-12T09:08:48Z",
                    "dev_start": "2026-10-12T09:08:48Z",
                    "dev_end": "2026-10-14T09:08:48Z",
                    "holdout_start": "2026-10-14T09:08:48Z",
                    "holdout_end": "2026-10-20T09:08:48Z"
                }
            }
        }
        with open(epoch_path, 'w', encoding='utf-8') as f:
            json.dump(epoch_content, f)

        # Write gaps.csv with GAP_20261012_01
        gaps_path = os.path.join(rec_dir, "gaps.csv")
        df_gaps = pd.DataFrame([{
            'gap_id': 'GAP_20261012_01',
            'start_utc': '2026-10-12T08:30:57Z',
            'end_utc': '2026-10-12T09:08:48Z',
            'duration_s': 2271,
            'affected_files': 'trades.csv, pending.csv, queue_depleted.csv',
            'cause': 'Test gap',
            'impact': 'Test gap impact'
        }])
        df_gaps.to_csv(gaps_path, index=False)

        # Timestamps:
        # q1: inside gap (2026-10-12 08:45:00 UTC) -> should be dropped
        # q2: outside gap, in dev window (2026-10-12 08:15:00 UTC) -> should be kept
        # q3: outside gap, in dev window (2026-10-12 09:15:00 UTC) -> should be kept
        ts_in_gap = int(datetime(2026, 10, 12, 8, 45, 0, tzinfo=timezone.utc).timestamp() * 1000)
        ts_before_gap = int(datetime(2026, 10, 12, 8, 15, 0, tzinfo=timezone.utc).timestamp() * 1000)
        ts_after_gap = int(datetime(2026, 10, 12, 9, 15, 0, tzinfo=timezone.utc).timestamp() * 1000)

        df_quotes = pd.DataFrame([
            {'quote_id': 'q_inside', 'timestamp_ms': ts_in_gap, 'arm': 'A', 'venue': 'binance', 'instrument': 'BTCUSDT', 'action': 'PLACE', 'side': 'BUY', 'price': 60000.0, 'size': 1.0, 'spread_bps': 3.5},
            {'quote_id': 'q_before', 'timestamp_ms': ts_before_gap, 'arm': 'A', 'venue': 'binance', 'instrument': 'BTCUSDT', 'action': 'PLACE', 'side': 'BUY', 'price': 60000.0, 'size': 1.0, 'spread_bps': 3.5},
            {'quote_id': 'q_after', 'timestamp_ms': ts_after_gap, 'arm': 'A', 'venue': 'binance', 'instrument': 'BTCUSDT', 'action': 'PLACE', 'side': 'BUY', 'price': 60000.0, 'size': 1.0, 'spread_bps': 3.5},
        ])
        gz_path = os.path.join(quotes_dir, "quotes_20261012_08.csv.gz")
        df_quotes.to_csv(gz_path, compression='gzip', index=False)

        from paper_mm2.reporter import load_quotes_in_window, load_venue_boundaries, load_gaps
        bounds = load_venue_boundaries(base_dir)
        gaps_list = load_gaps(base_dir)
        filtered_q = load_quotes_in_window(quotes_dir, 'binance', bounds, is_final=False, gaps=gaps_list)

        # q_inside must be dropped; q_before and q_after must be kept
        assert len(filtered_q) == 2
        assert 'q_inside' not in filtered_q['quote_id'].values
        assert 'q_before' in filtered_q['quote_id'].values
        assert 'q_after' in filtered_q['quote_id'].values

        # Full report verify
        rep = generate_report(data_dir, is_final=False)
        assert "Quotes Placed (Denominator):             2" in rep
        assert "Excluded Gaps: 1 gap window(s) excluded" in rep
        assert "GAP_20261012_01" in rep
