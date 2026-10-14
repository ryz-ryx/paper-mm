#!/usr/bin/env python3
"""
summary.py: Pre-Start Spread & Tick Measurement Telemetry Processor (PREREG v1.05 §3.3)
Processes spread_log.csv across 5 trading days in the session window (07:00-16:00 UTC Mon-Fri).

Outputs:
- Sample count (n) per symbol over session samples with spread > 0 ONLY
- 60th percentile observed spread (spread > 0)
- Baseline mean spread (S_pre-test, spread > 0)
- Symbol spread gate: min(0.3 pip, p60)
- Zero/inverted spread share
- Share of M1 closes with tick age <= 500 ms, <= 1000 ms, <= 3000 ms
- Median ticks per minute
- Markdown template formatted for ACCOUNT.md Section 3
"""

import sys
import os
import argparse
import csv
from datetime import datetime
from collections import defaultdict
import numpy as np


def is_in_session(dt: datetime) -> bool:
    """Verifies if timestamp falls strictly in session: Mon-Fri 07:00:00 - 16:00:00 UTC."""
    # Monday is 0, Friday is 4 in Python
    if dt.weekday() > 4:
        return False
    sec_of_day = dt.hour * 3600 + dt.minute * 60 + dt.second
    return (7 * 3600) <= sec_of_day < (16 * 3600)


def parse_timestamp(ts_str: str) -> datetime:
    ts_str = ts_str.strip()
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y.%m.%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S"):
        try:
            return datetime.strptime(ts_str, fmt)
        except ValueError:
            pass
    raise ValueError(f"Unrecognized timestamp format: {ts_str}")


def process_spread_rows(rows):
    """Processes iterable of dictionary rows from spread_log.csv."""
    symbol_data = defaultdict(lambda: {
        "all_spreads": [],
        "pos_spreads": [],
        "zero_count": 0,
        "tick_ages": [],
        "tick_counts": []
    })

    total_rows = 0
    in_session_rows = 0

    for row in rows:
        total_rows += 1
        ts_str = row.get("time_utc", "")
        sym = row.get("symbol", "").strip()
        spread_str = row.get("spread_pips", "")

        try:
            dt = parse_timestamp(ts_str)
            spread = float(spread_str)
        except Exception:
            continue

        if not is_in_session(dt):
            continue

        in_session_rows += 1
        data = symbol_data[sym]
        data["all_spreads"].append(spread)

        if spread <= 0.0:
            data["zero_count"] += 1
        else:
            data["pos_spreads"].append(spread)

        age_val = row.get("tick_age_ms", "")
        if age_val != "":
            try:
                data["tick_ages"].append(float(age_val))
            except ValueError:
                pass

        cnt_val = row.get("ticks_prev_60s", "")
        if cnt_val != "":
            try:
                data["tick_counts"].append(float(cnt_val))
            except ValueError:
                pass

    results = {}
    for sym in ("EURUSD", "USDJPY"):
        d = symbol_data.get(sym)
        if not d or len(d["all_spreads"]) == 0:
            results[sym] = {
                "total_samples": 0,
                "n": 0,
                "zero_count": 0,
                "zero_share": 0.0,
                "p60": 0.0,
                "mean": 0.0,
                "gate": 0.30,
                "share_lte_500": 0.0,
                "share_lte_1000": 0.0,
                "share_lte_3000": 0.0,
                "median_ticks_per_min": 0.0
            }
            continue

        pos_arr = np.array(d["pos_spreads"])
        total_n = len(d["all_spreads"])
        pos_n = len(pos_arr)
        zero_cnt = d["zero_count"]
        zero_sh = (zero_cnt / total_n) if total_n > 0 else 0.0

        if pos_n > 0:
            p60 = float(np.percentile(pos_arr, 60))
            mean = float(np.mean(pos_arr))
            gate = min(0.30, p60)
        else:
            p60 = 0.0
            mean = 0.0
            gate = 0.30

        # Tick age metrics
        ages = np.array(d["tick_ages"]) if d["tick_ages"] else np.array([])
        if len(ages) > 0:
            sh_500 = float(np.mean(ages <= 500.0))
            sh_1000 = float(np.mean(ages <= 1000.0))
            sh_3000 = float(np.mean(ages <= 3000.0))
        else:
            sh_500 = 0.0
            sh_1000 = 0.0
            sh_3000 = 0.0

        counts = np.array(d["tick_counts"]) if d["tick_counts"] else np.array([])
        med_ticks = float(np.median(counts)) if len(counts) > 0 else 0.0

        results[sym] = {
            "total_samples": total_n,
            "n": pos_n,
            "zero_count": zero_cnt,
            "zero_share": zero_sh,
            "p60": p60,
            "mean": mean,
            "gate": gate,
            "share_lte_500": sh_500,
            "share_lte_1000": sh_1000,
            "share_lte_3000": sh_3000,
            "median_ticks_per_min": med_ticks
        }

    return results, total_rows, in_session_rows


def process_spread_log(csv_path: str):
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Spread log not found: {csv_path}")

    with open(csv_path, mode="r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        return process_spread_rows(reader)


def print_summary(results: dict, total_rows: int, in_session_rows: int):
    print("=" * 72)
    print(" PRE-START SPREAD & TICK MEASUREMENT SUMMARY (PREREG v1.05 §3.3)")
    print("=" * 72)
    print(f"Total Rows Ingested     : {total_rows}")
    print(f"Session Rows (07-16 UTC): {in_session_rows}\n")

    for sym in ("EURUSD", "USDJPY"):
        data = results[sym]
        print(f"[{sym}]")
        print(f"  Total Session Samples (N)    : {data['total_samples']}")
        print(f"  Zero/Inverted Spread Share   : {data['zero_share'] * 100:.2f}% ({data['zero_count']} bars)")
        print(f"  Valid Positive Samples (n)   : {data['n']}")
        print(f"  60th Percentile Spread (>0)  : {data['p60']:.3f} pips")
        print(f"  Mean Spread (S_pre-test, >0) : {data['mean']:.3f} pips")
        print(f"  Calculated Gate (min(0.3,p)) : {data['gate']:.3f} pips")
        print(f"  Tick Age <= 500 ms Share     : {data['share_lte_500'] * 100:.2f}%")
        print(f"  Tick Age <= 1000 ms Share    : {data['share_lte_1000'] * 100:.2f}%")
        print(f"  Tick Age <= 3000 ms Share    : {data['share_lte_3000'] * 100:.2f}%")
        print(f"  Median Ticks per Minute      : {data['median_ticks_per_min']:.1f}\n")

    print("=" * 72)
    print(" COPY-PASTE READY FOR ACCOUNT.md Section 3:")
    print("=" * 72)
    eur = results["EURUSD"]
    jpy = results["USDJPY"]
    print(fr"""### EURUSD
- **Observed Sample Size (M1 bars)**: `{eur['n']}`
- **60th Percentile Observed Session Spread**: `{eur['p60']:.3f} pips`
- **Spread Gate ($\min(0.3\text{{ pip}}, \text{{60th percentile}})$)**: `{eur['gate']:.3f} pips`
- **$S_{{\text{{pre-test}}}}$ (Mean Observed Session Spread)**: `{eur['mean']:.3f} pips`

### USDJPY
- **Observed Sample Size (M1 bars)**: `{jpy['n']}`
- **60th Percentile Observed Session Spread**: `{jpy['p60']:.3f} pips`
- **Spread Gate ($\min(0.3\text{{ pip}}, \text{{60th percentile}})$)**: `{jpy['gate']:.3f} pips`
- **$S_{{\text{{pre-test}}}}$ (Mean Observed Session Spread)**: `{jpy['mean']:.3f} pips`""")
    print("=" * 72)


def main():
    parser = argparse.ArgumentParser(description="Process spread_log.csv for ACCOUNT.md parameters per PREREG v1.05")
    parser.add_argument("--csv", type=str, default="spread_log.csv", help="Path to spread_log.csv")
    args = parser.parse_args()

    try:
        results, total_rows, in_session_rows = process_spread_log(args.csv)
        print_summary(results, total_rows, in_session_rows)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
