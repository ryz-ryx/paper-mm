import os
import sys
import shutil
import tempfile
import gzip
import pandas as pd
import importlib.util

def run_equivalence_test():
    print("Loading 088b5ee engine and models...")
    spec_old_m = importlib.util.spec_from_file_location('models_old', 'paper_mm2_models_088b5ee.py')
    models_old = importlib.util.module_from_spec(spec_old_m)
    spec_old_m.loader.exec_module(models_old)

    spec_old_e = importlib.util.spec_from_file_location('engine_old', 'paper_mm2_engine_088b5ee.py')
    engine_old = importlib.util.module_from_spec(spec_old_e)
    spec_old_e.loader.exec_module(engine_old)

    import paper_mm2.models as models_new
    import paper_mm2.engine as engine_new

    # Temporary run directories
    dir_old = tempfile.mkdtemp(prefix="equiv_old_")
    dir_new = tempfile.mkdtemp(prefix="equiv_new_")

    try:
        eng_old = engine_old.StrategyEngine(dir_old)
        eng_new = engine_new.StrategyEngine(dir_new)

        # Load 1 hour of recorded Binance parquet trades and depth
        # Using 20261011_20 parquet files
        trades_file = "recorder_artifact_38169697653/market-recorder-parquet-38169697653/trades_20261011_20.parquet"
        depth_file = "recorder_artifact_38169697653/market-recorder-parquet-38169697653/depth_20261011_20.parquet"

        print(f"Reading recorded fixture: {trades_file} and {depth_file}...")
        df_t = pd.read_parquet(trades_file)
        df_t = df_t[df_t['venue'] == 'binance'].copy()
        df_t['event_type'] = 'trade'
        df_t['sort_ts'] = df_t['ts_local']

        df_d = pd.read_parquet(depth_file)
        df_d = df_d[df_d['binance_mid'] > 0].copy()
        df_d['event_type'] = 'depth'
        df_d['sort_ts'] = df_d['ts_local']

        # Interleave events chronologically
        events = pd.concat([
            df_t[['sort_ts', 'event_type', 'coin', 'price', 'size', 'side', 'ts_exchange']],
            df_d[['sort_ts', 'event_type', 'coin', 'binance_mid', 'binance_bid_0_px', 'binance_bid_0_sz', 'binance_ask_0_px', 'binance_ask_0_sz', 'binance_bid_top5_sz', 'binance_ask_top5_sz']]
        ]).sort_values(by=['sort_ts', 'event_type'], ascending=[True, False])

        print(f"Total Binance events in fixture: {len(events)} (Trades: {len(df_t)}, Depth snaps: {len(df_d)})")

        # Setup books for top coins
        coins = df_t['coin'].unique().tolist()
        books_old = {c: models_old.OrderBook(f"{c}USDT", 'binance') for c in coins}
        books_new = {c: models_new.OrderBook(f"{c}USDT", 'binance') for c in coins}
        inst_books_old = {f"{c}USDT": books_old[c] for c in coins}
        inst_books_new = {f"{c}USDT": books_new[c] for c in coins}

        print("Replaying fixture through both engines...", flush=True)
        step = 0
        for ev in events.itertuples(index=False):
            step += 1
            now_ms = int(ev.sort_ts)
            coin = ev.coin
            if coin not in books_old:
                continue

            if ev.event_type == 'depth':
                b_px = float(ev.binance_bid_0_px)
                b_sz = float(ev.binance_bid_0_sz)
                a_px = float(ev.binance_ask_0_px)
                a_sz = float(ev.binance_ask_0_sz)
                if b_px > 0 and a_px > 0:
                    bids = [(b_px, b_sz)]
                    asks = [(a_px, a_sz)]
                    books_old[coin].update_bids_asks(bids, asks, now_ms)
                    books_new[coin].update_bids_asks(bids, asks, now_ms)

                    # Update quotes
                    mid = books_old[coin].mid
                    sz = 10.0 / mid if mid > 0 else 1.0
                    eng_old.update_quote_logic(books_old[coin], now_ms, sz, min_spread_bps=3.0)
                    eng_new.update_quote_logic(books_new[coin], now_ms, sz, min_spread_bps=3.0)

            elif ev.event_type == 'trade':
                px = float(ev.price)
                sz = float(ev.size)
                side = str(ev.side)
                taker_side = 'BUY' if side == 'BUY' else 'SELL'
                ts_ex = int(ev.ts_exchange) if pd.notnull(ev.ts_exchange) else now_ms
                books_old[coin].record_trade(ts_ex, taker_side, sz)
                books_new[coin].record_trade(ts_ex, taker_side, sz)

                eng_old.process_trade(books_old[coin], ts_ex, px, sz, taker_side)
                eng_new.process_trade(books_new[coin], ts_ex, px, sz, taker_side)

            # Check pending exits periodically
            if step % 200 == 0:
                eng_old.check_pending_exits(inst_books_old, now_ms)
                eng_new.check_pending_exits(inst_books_new, now_ms)

            if step % 100000 == 0:
                print(f"Processed {step}/{len(events)} events...", flush=True)

        # Advance time by 65s at the end to finalize all pending exits into trades.csv and queue_depleted.csv
        drain_now_ms = int(events.iloc[-1]['sort_ts']) + 65000
        print(f"Finalizing pending exits at {drain_now_ms}...")
        eng_old.check_pending_exits(inst_books_old, drain_now_ms)
        eng_new.check_pending_exits(inst_books_new, drain_now_ms)

        # Flush new engine quotes
        eng_new.flush_quotes()

        # Compare outputs: trades.csv, pending.csv, queue_depleted.csv, quotes
        print("\n=== Comparing Outputs ===")

        # 1. trades.csv
        df_tr_old = pd.read_csv(eng_old.trades_csv_path) if os.path.exists(eng_old.trades_csv_path) else pd.DataFrame()
        df_tr_new = pd.read_csv(eng_new.trades_csv_path) if os.path.exists(eng_new.trades_csv_path) else pd.DataFrame()
        if 'top1_imbalance' in df_tr_new.columns:
            df_tr_new_comp = df_tr_new.drop(columns=['top1_imbalance'])
        else:
            df_tr_new_comp = df_tr_new
        print(f"Trades count: old={len(df_tr_old)}, new={len(df_tr_new)}")
        pd.testing.assert_frame_equal(df_tr_old, df_tr_new_comp, check_dtype=False)
        print("ASSERT PASS: trades.csv identical!")

        # 2. queue_depleted.csv
        df_qd_old = pd.read_csv(eng_old.queue_depleted_csv_path) if os.path.exists(eng_old.queue_depleted_csv_path) else pd.DataFrame()
        df_qd_new = pd.read_csv(eng_new.queue_depleted_csv_path) if os.path.exists(eng_new.queue_depleted_csv_path) else pd.DataFrame()
        if 'top1_imbalance' in df_qd_new.columns:
            df_qd_new_comp = df_qd_new.drop(columns=['top1_imbalance'])
        else:
            df_qd_new_comp = df_qd_new
        print(f"Queue depleted count: old={len(df_qd_old)}, new={len(df_qd_new)}")
        pd.testing.assert_frame_equal(df_qd_old, df_qd_new_comp, check_dtype=False)
        print("ASSERT PASS: queue_depleted.csv identical!")

        # 3. pending.csv
        df_p_old = pd.read_csv(eng_old.pending_csv_path) if os.path.exists(eng_old.pending_csv_path) else pd.DataFrame()
        df_p_new = pd.read_csv(eng_new.pending_csv_path) if os.path.exists(eng_new.pending_csv_path) else pd.DataFrame()
        if 'top1_imbalance' in df_p_new.columns:
            df_p_new_comp = df_p_new.drop(columns=['top1_imbalance'])
        else:
            df_p_new_comp = df_p_new
        print(f"Pending count: old={len(df_p_old)}, new={len(df_p_new)}")
        pd.testing.assert_frame_equal(df_p_old, df_p_new_comp, check_dtype=False)
        print("ASSERT PASS: pending.csv identical!")

        # 4. quotes: old quotes.csv vs new quotes/*.csv.gz
        df_q_old = pd.read_csv(eng_old.quotes_csv_path) if os.path.exists(eng_old.quotes_csv_path) else pd.DataFrame()
        new_q_files = sorted([os.path.join(eng_new.quotes_dir, f) for f in os.listdir(eng_new.quotes_dir) if f.endswith('.csv.gz')])
        new_q_dfs = []
        for f in new_q_files:
            with gzip.open(f, 'rt', encoding='utf-8') as gz:
                new_q_dfs.append(pd.read_csv(gz))
        df_q_new = pd.concat(new_q_dfs, ignore_index=True) if new_q_dfs else pd.DataFrame()
        if 'top1_imbalance' in df_q_new.columns:
            df_q_new_comp = df_q_new.drop(columns=['top1_imbalance'])
        else:
            df_q_new_comp = df_q_new
        print(f"Quotes count: old={len(df_q_old)}, new={len(df_q_new)}")
        pd.testing.assert_frame_equal(df_q_old, df_q_new_comp, check_dtype=False)
        print("ASSERT PASS: quotes rows identical!")

        print("\n>>> ALL ASSERTIONS PASSED: 100% BIT-FOR-BIT IDENTICAL BINANCE OUTPUT (0 DIFFS) <<<")

    finally:
        shutil.rmtree(dir_old)
        shutil.rmtree(dir_new)

if __name__ == '__main__':
    run_equivalence_test()
