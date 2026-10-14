#!/usr/bin/env python3
"""
summary.py: Pre-Start Spread Measurement Telemetry Processor (PREREG §3.3)
Processes spread_log.csv across 5 trading days in the session window (07:00-16:00 UTC Mon-Fri).

Outputs:
- Sample count (n) per symbol
- 60th percentile observed spread
- Baseline mean spread (S_pre-test)
- Symbol spread gate: min(0.3 pip, 60th percentile)
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


def process_spread_log(csv_path: str):
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Spread log not found: {csv_path}")

    symbol_data = defaultdict(list)
    total_rows = 0
    in_session_rows = 0

    with open(csv_path, mode="r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            total_rows += 1
            ts_str = row.get("time_utc", "")
            sym = row.get("symbol", "").strip()
            spread_str = row.get("spread_pips", "")

            try:
                dt = parse_timestamp(ts_str)
                spread = float(spread_str)
            except Exception:
                continue

            if is_in_session(dt):
                in_session_rows += 1
                symbol_data[sym].append(spread)

    results = {}
    for sym in ("EURUSD", "USDJPY"):
        spreads = symbol_data.get(sym, [])
        if not spreads:
            results[sym] = {
                "n": 0,
                "p60": 0.0,
                "mean": 0.0,
                "gate": 0.30
            }
            continue

        arr = np.array(spreads)
        p60 = float(np.percentile(arr, 60))
        mean = float(np.mean(arr))
        gate = min(0.30, p60)

        results[sym] = {
            "n": len(spreads),
            "p60": p60,
            "mean": mean,
            "gate": gate
        }

    return results, total_rows, in_session_rows


def print_summary(results: dict, total_rows: int, in_session_rows: int):
    print("=" * 72)
    print(" PRE-START SPREAD MEASUREMENT SUMMARY (PREREG §3.3)")
    print("=" * 72)
    print(f"Total Rows Ingested     : {total_rows}")
    print(f"Session Rows (07-16 UTC): {in_session_rows}\n")

    for sym in ("EURUSD", "USDJPY"):
        data = results[sym]
        print(f"[{sym}]")
        print(f"  Observed M1 Samples (n)     : {data['n']}")
        print(f"  60th Percentile Spread      : {data['p60']:.3f} pips")
        print(f"  Mean Spread (S_pre-test)    : {data['mean']:.3f} pips")
        print(f"  Calculated Gate (min(0.3,p)): {data['gate']:.3f} pips\n")

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
    parser = argparse.ArgumentParser(description="Process spread_log.csv for ACCOUNT.md parameters")
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
