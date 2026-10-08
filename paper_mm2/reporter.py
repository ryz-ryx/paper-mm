"""
Read-only analysis reporter for Phase 1 pre-registered paper trading.
Implements:
1. 6 arms split: (venue, arm) for venue in ['hyperliquid', 'binance'] and arm in ['A', 'B', 'C'].
   Hyperliquid decision metric: rt_net_hl.
   Binance decision metric: rt_net_zero_fee (with VIP0 and BNB shown for information).
2. Fixed calendar boundaries:
   Dev: 2026-10-07..2026-10-10 UTC
   Hold-out: 2026-10-11..2026-10-14 UTC
   Default shows Dev only. Hold-out printed ONLY when run with --final.
3. Decision rules per arm on hold-out:
   >= 2,000 primary fills, mean >= +0.3 bps, block-bootstrap lower bound > 0 (alpha = 0.0083),
   positive mean in >= 2 of 3 volatility terciles (terciles computed within each instrument, then pooled counts),
   and in both weekday and weekend.
   STOP check on dev only: bootstrap upper bound < 0 at >= 1,000 fills, printed daily.
4. Evaluation set: primary (trade-through) fills only. No fallback to all fills.
   Queue-depleted fills reported separately.
"""
import os
import sys
import json
import argparse
import pandas as pd
import numpy as np
from datetime import datetime, timezone, date
from typing import Dict, Any, Tuple, Optional

# Fixed calendar boundaries: loaded from EPOCH.json
def load_calendar_boundaries(base_dir: str) -> Tuple[date, date, date, date]:
    epoch_file = os.path.join(base_dir, "EPOCH.json")
    if os.path.exists(epoch_file):
        try:
            with open(epoch_file, 'r', encoding='utf-8') as f:
                d = json.load(f)
            return (
                date.fromisoformat(d['dev_start']),
                date.fromisoformat(d['dev_end']),
                date.fromisoformat(d['holdout_start']),
                date.fromisoformat(d['holdout_end'])
            )
        except Exception:
            pass
    return date(2026, 10, 8), date(2026, 10, 11), date(2026, 10, 12), date(2026, 10, 15)

def block_bootstrap(df: pd.DataFrame, col: str, n_resamples: int = 10000, alpha: float = 0.0083) -> Dict[str, float]:
    if len(df) == 0:
        return {'mean': 0.0, 'ci_lower': 0.0, 'ci_upper': 0.0}
    
    # 5-minute bucket (300,000 ms)
    buckets = df['timestamp_ms'] // 300000
    grouped = df.groupby(buckets)[col]
    b_sums = grouped.sum().values
    b_counts = grouped.count().values
    n_b = len(b_sums)

    if n_b == 0:
        return {'mean': 0.0, 'ci_lower': 0.0, 'ci_upper': 0.0}

    # Resample
    idx = np.random.randint(0, n_b, size=(n_resamples, n_b))
    sample_sums = np.take(b_sums, idx).sum(axis=1)
    sample_counts = np.take(b_counts, idx).sum(axis=1)
    
    valid = sample_counts > 0
    resampled_means = sample_sums[valid] / sample_counts[valid]
    
    mean_val = float(df[col].mean())
    ci_lower = float(np.percentile(resampled_means, alpha * 100))
    ci_upper = float(np.percentile(resampled_means, (1.0 - alpha) * 100))
    
    return {'mean': mean_val, 'ci_lower': ci_lower, 'ci_upper': ci_upper}

def assign_instrument_vol_terciles(df_arm: pd.DataFrame) -> pd.DataFrame:
    """
    Computes volatility terciles within each instrument, then returns dataframe with 'vol_tercile'.
    """
    if len(df_arm) == 0:
        df_arm = df_arm.copy()
        df_arm['vol_tercile'] = 'mid_vol'
        return df_arm
    
    df_arm = df_arm.copy()
    df_arm['vol_tercile'] = 'mid_vol'
    
    for inst in df_arm['instrument'].unique():
        inst_mask = (df_arm['instrument'] == inst)
        inst_vols = df_arm.loc[inst_mask, 'realised_vol_10s'].dropna()
        if len(inst_vols) >= 3:
            q33 = inst_vols.quantile(0.3333)
            q66 = inst_vols.quantile(0.6667)
            low_mask = inst_mask & (df_arm['realised_vol_10s'] <= q33)
            mid_mask = inst_mask & (df_arm['realised_vol_10s'] > q33) & (df_arm['realised_vol_10s'] <= q66)
            high_mask = inst_mask & (df_arm['realised_vol_10s'] > q66)
            df_arm.loc[low_mask, 'vol_tercile'] = 'low_vol'
            df_arm.loc[mid_mask, 'vol_tercile'] = 'mid_vol'
            df_arm.loc[high_mask, 'vol_tercile'] = 'high_vol'
        else:
            df_arm.loc[inst_mask, 'vol_tercile'] = 'mid_vol'
    return df_arm

def generate_report(data_dir: str, is_final: bool = False) -> str:
    trades_path = os.path.join(data_dir, "trades.csv")
    queue_depleted_path = os.path.join(data_dir, "queue_depleted.csv")

    base_dir = os.path.dirname(os.path.abspath(data_dir))
    dev_start, dev_end, holdout_start, holdout_end = load_calendar_boundaries(base_dir)

    lines = []
    lines.append("=" * 80)
    lines.append("PHASE 1 PRE-REGISTRATION REPORT: FILTERED PASSIVE QUOTING")
    lines.append(f"Generated at: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    
    if is_final:
        eval_mode = "FINAL HOLD-OUT"
        window_start, window_end = holdout_start, holdout_end
        lines.append(f"Mode: FINAL HOLD-OUT EVALUATION (--final)")
        lines.append(f"Calendar Window: {window_start} to {window_end} UTC")
    else:
        eval_mode = "DEV"
        window_start, window_end = dev_start, dev_end
        lines.append(f"Mode: DEV EVALUATION (Default)")
        lines.append(f"Calendar Window: {window_start} to {window_end} UTC")
        lines.append(f"Note: Hold-out data is excluded and evaluated only when run with --final.")
    lines.append("=" * 80)

    # 1. Load trades.csv
    df_raw = pd.DataFrame()
    if os.path.exists(trades_path):
        try:
            df_raw = pd.read_csv(trades_path)
        except Exception as e:
            lines.append(f"Warning: could not read trades.csv: {e}")

    # 2. Load queue_depleted.csv
    qd_raw = pd.DataFrame()
    if os.path.exists(queue_depleted_path):
        try:
            qd_raw = pd.read_csv(queue_depleted_path)
        except Exception as e:
            lines.append(f"Warning: could not read queue_depleted.csv: {e}")

    # Process trades.csv numeric & date fields
    df = pd.DataFrame()
    if len(df_raw) > 0:
        df = df_raw.copy()
        numeric_cols = [
            'fill_price', 'fill_size', 'round_trip_edge_bps',
            'rt_net_hl', 'rt_net_binance_vip0', 'rt_net_binance_bnb', 'rt_net_zero_fee',
            'realised_vol_10s'
        ]
        for c in numeric_cols:
            if c in df.columns:
                df[c] = pd.to_numeric(df[c], errors='coerce')
        if 'timestamp_ms' in df.columns:
            df['dt'] = pd.to_datetime(df['timestamp_ms'], unit='ms', utc=True)
            df['date'] = df['dt'].dt.date
            df['is_weekend'] = df['dt'].dt.dayofweek >= 5
            # Filter strictly to the target window
            df = df[(df['date'] >= window_start) & (df['date'] <= window_end)]

    # Process queue_depleted.csv date fields
    qd_df = pd.DataFrame()
    if len(qd_raw) > 0 and 'timestamp_ms' in qd_raw.columns:
        qd_df = qd_raw.copy()
        qd_df['dt'] = pd.to_datetime(qd_df['timestamp_ms'], unit='ms', utc=True)
        qd_df['date'] = qd_df['dt'].dt.date
        qd_df = qd_df[(qd_df['date'] >= window_start) & (qd_df['date'] <= window_end)]

    lines.append(f"Trades in Window: {len(df)}")
    lines.append(f"Queue-Depleted Events in Window: {len(qd_df)}")

    # 6 Pre-registered arms
    arms_config = [
        {'venue': 'hyperliquid', 'arm': 'A', 'metric': 'rt_net_hl', 'name': 'Hyperliquid Arm A (Spread >= 2 bps)'},
        {'venue': 'hyperliquid', 'arm': 'B', 'metric': 'rt_net_hl', 'name': 'Hyperliquid Arm B (A + Top-5 Imbalance >= 0.60)'},
        {'venue': 'hyperliquid', 'arm': 'C', 'metric': 'rt_net_hl', 'name': 'Hyperliquid Arm C (B + Cancel on 1s Flow 80th)'},
        {'venue': 'binance',     'arm': 'A', 'metric': 'rt_net_zero_fee', 'name': 'Binance Arm A (Spread >= 3 bps)'},
        {'venue': 'binance',     'arm': 'B', 'metric': 'rt_net_zero_fee', 'name': 'Binance Arm B (A + Top-5 Imbalance >= 0.60)'},
        {'venue': 'binance',     'arm': 'C', 'metric': 'rt_net_zero_fee', 'name': 'Binance Arm C (B + Cancel on 1s Flow 80th)'},
    ]

    arm_eval_data = {}

    for arm_cfg in arms_config:
        venue = arm_cfg['venue']
        arm = arm_cfg['arm']
        metric = arm_cfg['metric']
        arm_title = arm_cfg['name']

        lines.append("")
        lines.append("-" * 80)
        lines.append(f"ARM: {venue.upper()} - {arm} | {arm_title}")
        lines.append(f"Decision Metric: {metric}")
        lines.append("-" * 80)

        # Primary fills: STRICTLY primary pessimistic trade-through fills only. NO fallback.
        arm_df = df[(df['venue'] == venue) & (df['arm'] == arm)] if len(df) > 0 else pd.DataFrame()
        pessimistic_fills = arm_df[arm_df['is_primary_pessimistic_fill'] == True] if len(arm_df) > 0 else pd.DataFrame()
        
        # Queue-depleted count: from queue_depleted.csv, plus any in trades.csv
        qd_count = 0
        if len(qd_df) > 0:
            qd_count += len(qd_df[(qd_df['venue'] == venue) & (qd_df['arm'] == arm)])
        if len(arm_df) > 0 and 'is_queue_depleted_fill' in arm_df.columns:
            qd_count += len(arm_df[arm_df['is_queue_depleted_fill'] == True])

        lines.append(f"Primary Pessimistic Fills (Trade-Through): {len(pessimistic_fills)}")
        lines.append(f"Secondary Fills (Queue Depleted):          {qd_count}")

        eval_df = pessimistic_fills
        arm_eval_data[(venue, arm)] = eval_df

        if len(eval_df) == 0:
            lines.append("No primary pessimistic fills recorded in this window.")
            if is_final:
                lines.append("HOLD-OUT VERDICT: IN PROGRESS (n=0 < 2,000 threshold)")
            else:
                lines.append("DEV STOP CHECK: IN PROGRESS (n=0 < 1,000 threshold)")
            continue

        # Means across fee scenarios
        lines.append("\nRound-Trip Performance (bps to far-touch exit at +10s):")
        lines.append(f"  Gross Edge:          {eval_df['round_trip_edge_bps'].mean():+6.2f} bps")
        if venue == 'hyperliquid':
            lines.append(f"  HL Net (6.0 fee):    {eval_df['rt_net_hl'].mean():+6.2f} bps  <-- DECISION METRIC")
        else:
            lines.append(f"  Zero-fee ref (0.0):  {eval_df['rt_net_zero_fee'].mean():+6.2f} bps  <-- DECISION METRIC")
            lines.append(f"  Binance VIP0 (20.0): {eval_df['rt_net_binance_vip0'].mean():+6.2f} bps (for information)")
            lines.append(f"  Binance BNB (15.0):  {eval_df['rt_net_binance_bnb'].mean():+6.2f} bps (for information)")

        # Block Bootstrap CI (alpha=0.0083)
        boot = block_bootstrap(eval_df, metric, n_resamples=10000, alpha=0.0083)
        lines.append(f"\nBlock-Bootstrap CI on {metric} (5-min buckets, 10,000 resamples, alpha=0.0083):")
        lines.append(f"  Mean:     {boot['mean']:+6.2f} bps")
        lines.append(f"  99.17% CI: [{boot['ci_lower']:+6.2f}, {boot['ci_upper']:+6.2f}] bps")

        # Volatility terciles (computed within each instrument, then pooled)
        eval_df = assign_instrument_vol_terciles(eval_df)
        lines.append(f"\nVolatility Terciles ({metric}, computed per-instrument, pooled counts):")
        pos_vol_count = 0
        for vt in ['low_vol', 'mid_vol', 'high_vol']:
            sub_vt = eval_df[eval_df['vol_tercile'] == vt]
            n_vt = len(sub_vt)
            m_vt = float(sub_vt[metric].mean()) if n_vt > 0 else 0.0
            is_pos = (m_vt > 0.0) if n_vt > 0 else False
            if is_pos:
                pos_vol_count += 1
            status_str = "POSITIVE" if is_pos else ("NEGATIVE" if n_vt > 0 else "NO FILLS")
            lines.append(f"  {vt:10}: n={n_vt:4d}, mean={m_vt:+6.2f} bps [{status_str}]")
        lines.append(f"  Terciles Positive: {pos_vol_count} of 3 (required: >= 2)")

        # Weekday vs Weekend split
        lines.append(f"\nWeekday vs Weekend Split ({metric}):")
        wday = eval_df[~eval_df['is_weekend']]
        wend = eval_df[eval_df['is_weekend']]
        n_wday = len(wday)
        n_wend = len(wend)
        m_wday = float(wday[metric].mean()) if n_wday > 0 else 0.0
        m_wend = float(wend[metric].mean()) if n_wend > 0 else 0.0
        pos_wday = (m_wday > 0.0) if n_wday > 0 else False
        pos_wend = (m_wend > 0.0) if n_wend > 0 else False
        lines.append(f"  Weekday: n={n_wday:4d}, mean={m_wday:+6.2f} bps [{'POSITIVE' if pos_wday else 'NEGATIVE' if n_wday > 0 else 'NO FILLS'}]")
        lines.append(f"  Weekend: n={n_wend:4d}, mean={m_wend:+6.2f} bps [{'POSITIVE' if pos_wend else 'NEGATIVE' if n_wend > 0 else 'NO FILLS'}]")

        # Decision rules
        lines.append("\nPre-Registration Decision Check:")
        if is_final:
            # HOLD-OUT DECISION RULES:
            # >= 2,000 primary fills, mean >= +0.3 bps, CI lower > 0, >= 2 of 3 vol terciles positive, both weekday/weekend positive
            crit_fills = len(eval_df) >= 2000
            crit_mean = boot['mean'] >= 0.3
            crit_ci = boot['ci_lower'] > 0.0
            crit_vol = pos_vol_count >= 2
            crit_days = pos_wday and pos_wend

            if len(eval_df) < 2000:
                lines.append(f"  [IN PROGRESS] Holdout fills = {len(eval_df)} < 2,000 threshold.")
            elif crit_fills and crit_mean and crit_ci and crit_vol and crit_days:
                lines.append(f"  VERDICT: PASS (All 5 pre-registered hold-out criteria met)")
            else:
                failures = []
                if not crit_mean: failures.append(f"mean {boot['mean']:+.2f} < +0.3 bps")
                if not crit_ci: failures.append(f"CI lower {boot['ci_lower']:+.2f} <= 0")
                if not crit_vol: failures.append(f"vol terciles positive {pos_vol_count} < 2")
                if not crit_days: failures.append("weekday/weekend not both positive")
                lines.append(f"  VERDICT: FAIL ({', '.join(failures)})")
        else:
            # DEV STOP CHECK:
            # Check if bootstrap upper bound < 0 at >= 1,000 fills
            if len(eval_df) >= 1000:
                if boot['ci_upper'] < 0.0:
                    lines.append(f"  [STOP TRIGGERED] Bootstrap upper bound < 0 at >=1,000 fills ({boot['ci_upper']:+.2f} bps, n={len(eval_df)})")
                else:
                    lines.append(f"  [DEV STOP CHECK] NOT TRIGGERED (Upper CI {boot['ci_upper']:+.2f} bps >= 0, n={len(eval_df)})")
            else:
                lines.append(f"  [DEV STOP CHECK] IN PROGRESS (Fills = {len(eval_df)} < 1,000 threshold for stop check)")

    # Filter value test (B vs A, C vs B)
    lines.append("")
    lines.append("=" * 80)
    lines.append("FILTER-VALUE TESTS (B vs A, C vs B)")
    lines.append("Requirement: 10s markout improvement >= 0.5 bps (B) / >= 0.3 bps (C) with fill count falling <= 60%")
    lines.append("-" * 80)
    for venue in ['hyperliquid', 'binance']:
        df_a = arm_eval_data.get((venue, 'A'), pd.DataFrame())
        df_b = arm_eval_data.get((venue, 'B'), pd.DataFrame())
        df_c = arm_eval_data.get((venue, 'C'), pd.DataFrame())
        
        lines.append(f"Venue: {venue.upper()}")
        # B vs A
        if len(df_a) > 0 and len(df_b) > 0:
            m_a = df_a['round_trip_edge_bps'].mean()
            m_b = df_b['round_trip_edge_bps'].mean()
            diff_ba = m_b - m_a
            drop_ba = (len(df_a) - len(df_b)) / len(df_a) * 100.0
            pass_ba = (diff_ba >= 0.5) and (drop_ba <= 60.0)
            lines.append(f"  B vs A: Markout delta = {diff_ba:+.2f} bps (req >= +0.5), Count drop = {drop_ba:.1f}% (req <= 60%) -> {'PASS' if pass_ba else 'FAIL'}")
        else:
            lines.append("  B vs A: Insufficient data")

        # C vs B
        if len(df_b) > 0 and len(df_c) > 0:
            m_b = df_b['round_trip_edge_bps'].mean()
            m_c = df_c['round_trip_edge_bps'].mean()
            diff_cb = m_c - m_b
            drop_cb = (len(df_b) - len(df_c)) / len(df_b) * 100.0
            pass_cb = (diff_cb >= 0.3) and (drop_cb <= 60.0)
            lines.append(f"  C vs B: Markout delta = {diff_cb:+.2f} bps (req >= +0.3), Count drop = {drop_cb:.1f}% (req <= 60%) -> {'PASS' if pass_cb else 'FAIL'}")
        else:
            lines.append("  C vs B: Insufficient data")

    lines.append("=" * 80)
    report_text = "\n".join(lines)
    return report_text

def main():
    parser = argparse.ArgumentParser(description="Phase 1 Pre-Registration Reporter")
    parser.add_argument("--final", action="store_true", help="Evaluate hold-out period (2026-10-11..2026-10-14). Default evaluates dev period only.")
    parser.add_argument("--data-dir", default=None, help="Path to data directory")
    args = parser.parse_args()

    base_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = args.data_dir if args.data_dir else os.path.join(base_dir, "data")
    
    rep = generate_report(data_dir, is_final=args.final)
    print(rep)

    reports_dir = os.path.join(base_dir, "reports")
    os.makedirs(reports_dir, exist_ok=True)
    out_filename = "final_summary.txt" if args.final else "latest_summary.txt"
    with open(os.path.join(reports_dir, out_filename), "w", encoding="utf-8") as f:
        f.write(rep)

if __name__ == '__main__':
    main()
