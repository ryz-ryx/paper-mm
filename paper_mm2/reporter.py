"""
Read-only analysis reporter for Phase 1 pre-registered paper trading.
Outputs:
- Fills count per arm.
- Mean round-trip net under each fee set (Hyperliquid, Binance VIP0, Binance BNB, Zero-fee).
- Block-bootstrap (5-min buckets, 10,000 resamples) confidence interval (alpha = 0.0083).
- Volatility terciles (low/mid/high) split.
- Weekday vs weekend split.
- Dev set vs hold-out split (first half vs second half of calendar days).
- Pre-registration Decision rules check (>= 2,000 fills, >= +0.3 bps, CI lower > 0).
"""
import os
import sys
import pandas as pd
import numpy as np
from datetime import datetime, timezone
from typing import Dict, Any

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

def generate_report(data_dir: str) -> str:
    trades_path = os.path.join(data_dir, "trades.csv")
    if not os.path.exists(trades_path):
        return f"No trades file found at {trades_path}"

    df = pd.read_csv(trades_path)
    if len(df) == 0:
        return "trades.csv is empty."

    # Convert numeric fields
    numeric_cols = [
        'fill_price', 'fill_size', 'round_trip_edge_bps',
        'rt_net_hl', 'rt_net_binance_vip0', 'rt_net_binance_bnb', 'rt_net_zero_fee',
        'realised_vol_10s'
    ]
    for c in numeric_cols:
        if c in df.columns:
            df[c] = pd.to_numeric(df[c], errors='coerce')

    # Date and calendar splits
    df['dt'] = pd.to_datetime(df['timestamp_ms'], unit='ms', utc=True)
    df['date'] = df['dt'].dt.date
    df['is_weekend'] = df['dt'].dt.dayofweek >= 5

    # Unique calendar days for dev / hold-out split
    unique_dates = sorted(df['date'].unique())
    n_days = len(unique_dates)
    mid_day_idx = max(1, n_days // 2)
    dev_dates = set(unique_dates[:mid_day_idx])
    holdout_dates = set(unique_dates[mid_day_idx:])

    df['split'] = df['date'].apply(lambda d: 'dev' if d in dev_dates else 'holdout')

    lines = []
    lines.append("=" * 80)
    lines.append("PHASE 1 PRE-REGISTRATION REPORT: FILTERED PASSIVE QUOTING")
    lines.append(f"Generated at: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')}")
    lines.append(f"Total Fills Recorded: {len(df)}")
    lines.append(f"Calendar Days Range: {unique_dates[0]} to {unique_dates[-1]} ({n_days} days)")
    lines.append(f"Dev Days ({len(dev_dates)}): {min(dev_dates)} to {max(dev_dates)}")
    if holdout_dates:
        lines.append(f"Hold-out Days ({len(holdout_dates)}): {min(holdout_dates)} to {max(holdout_dates)}")
    else:
        lines.append("Hold-out Days: (insufficient days elapsed)")
    lines.append("=" * 80)

    # Volatility terciles
    if 'realised_vol_10s' in df.columns and df['realised_vol_10s'].notna().sum() > 3:
        q33 = df['realised_vol_10s'].quantile(0.333)
        q66 = df['realised_vol_10s'].quantile(0.666)
        def get_vol_tercile(v):
            if v <= q33: return 'low_vol'
            elif v <= q66: return 'mid_vol'
            else: return 'high_vol'
        df['vol_tercile'] = df['realised_vol_10s'].apply(get_vol_tercile)
    else:
        df['vol_tercile'] = 'mid_vol'

    arms = ['A', 'B', 'C']
    for arm in arms:
        arm_df = df[df['arm'] == arm]
        lines.append("")
        lines.append("-" * 80)
        lines.append(f"ARM {arm} PERFORMANCE SUMMARY")
        lines.append("-" * 80)
        lines.append(f"Total Fills: {len(arm_df)}")

        pessimistic_fills = arm_df[arm_df['is_primary_pessimistic_fill'] == True]
        queue_depleted_fills = arm_df[arm_df['is_queue_depleted_fill'] == True]
        lines.append(f"  - Primary Pessimistic (Trade-Through): {len(pessimistic_fills)}")
        lines.append(f"  - Secondary (Queue Depleted):          {len(queue_depleted_fills)}")

        if len(arm_df) == 0:
            lines.append("No fills recorded for this arm yet.")
            continue

        # Evaluate against the primary pessimistic fills as per pre-registration
        eval_df = pessimistic_fills if len(pessimistic_fills) > 0 else arm_df

        # Means across fee scenarios
        lines.append("\nRound-Trip Net Performance (bps to far-touch exit at +10s):")
        lines.append(f"  Gross Edge:          {eval_df['round_trip_edge_bps'].mean():+6.2f} bps")
        lines.append(f"  HL Net (6.0 fee):    {eval_df['rt_net_hl'].mean():+6.2f} bps")
        lines.append(f"  Binance VIP0 (20.0): {eval_df['rt_net_binance_vip0'].mean():+6.2f} bps")
        lines.append(f"  Binance BNB (15.0):  {eval_df['rt_net_binance_bnb'].mean():+6.2f} bps")
        lines.append(f"  Zero-fee ref (0.0):  {eval_df['rt_net_zero_fee'].mean():+6.2f} bps")

        # Bootstrap CI (alpha=0.0083)
        hl_boot = block_bootstrap(eval_df, 'rt_net_hl')
        zero_boot = block_bootstrap(eval_df, 'rt_net_zero_fee')
        lines.append("\nBlock-Bootstrap CI (5-min buckets, 10,000 resamples, alpha=0.0083):")
        lines.append(f"  HL Net CI:     [{hl_boot['ci_lower']:+6.2f}, {hl_boot['ci_upper']:+6.2f}] bps (mean: {hl_boot['mean']:+6.2f})")
        lines.append(f"  Zero-fee CI:   [{zero_boot['ci_lower']:+6.2f}, {zero_boot['ci_upper']:+6.2f}] bps (mean: {zero_boot['mean']:+6.2f})")

        # Volatility Terciles split
        lines.append("\nPerformance by Volatility Tercile (Zero-fee Net):")
        for vt in ['low_vol', 'mid_vol', 'high_vol']:
            sub = eval_df[eval_df['vol_tercile'] == vt]
            m = sub['rt_net_zero_fee'].mean() if len(sub) > 0 else 0.0
            lines.append(f"  {vt:10}: n={len(sub):4d}, mean={m:+6.2f} bps")

        # Weekday vs Weekend split
        lines.append("\nWeekday vs Weekend Split (Zero-fee Net):")
        wday = eval_df[~eval_df['is_weekend']]
        wend = eval_df[eval_df['is_weekend']]
        m_wday = wday['rt_net_zero_fee'].mean() if len(wday) > 0 else 0.0
        m_wend = wend['rt_net_zero_fee'].mean() if len(wend) > 0 else 0.0
        lines.append(f"  Weekday: n={len(wday):4d}, mean={m_wday:+6.2f} bps")
        lines.append(f"  Weekend: n={len(wend):4d}, mean={m_wend:+6.2f} bps")

        # Dev vs Hold-out split
        lines.append("\nDev vs Hold-out Split (Zero-fee Net):")
        dev_sub = eval_df[eval_df['split'] == 'dev']
        ho_sub = eval_df[eval_df['split'] == 'holdout']
        m_dev = dev_sub['rt_net_zero_fee'].mean() if len(dev_sub) > 0 else 0.0
        m_ho = ho_sub['rt_net_zero_fee'].mean() if len(ho_sub) > 0 else 0.0
        lines.append(f"  Dev:     n={len(dev_sub):4d}, mean={m_dev:+6.2f} bps")
        lines.append(f"  Holdout: n={len(ho_sub):4d}, mean={m_ho:+6.2f} bps")

        # Decision rules check
        lines.append("\nPre-Registration Decision Check:")
        if len(ho_sub) < 2000:
            lines.append(f"  [IN PROGRESS] Holdout fills = {len(ho_sub)} < 2,000 threshold.")
        else:
            ho_boot = block_bootstrap(ho_sub, 'rt_net_hl')
            pass_fills = len(ho_sub) >= 2000
            pass_net = ho_sub['rt_net_hl'].mean() >= 0.3
            pass_ci = ho_boot['ci_lower'] > 0.0
            verdict = "PASS" if (pass_fills and pass_net and pass_ci) else "FAIL"
            lines.append(f"  VERDICT: {verdict} (Holdout fills={len(ho_sub)}, Mean={ho_sub['rt_net_hl'].mean():+.2f} bps, CI lower={ho_boot['ci_lower']:+.2f})")

    lines.append("=" * 80)
    report_text = "\n".join(lines)
    return report_text

if __name__ == '__main__':
    base_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(base_dir, "data")
    rep = generate_report(data_dir)
    print(rep)
    report_out_path = os.path.join(base_dir, "reports", "latest_summary.txt")
    with open(report_out_path, 'w', encoding='utf-8') as f:
        f.write(rep)
