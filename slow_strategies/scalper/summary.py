#!/usr/bin/env python3
"""
summary.py: Pre-Start Spread & Tick Measurement Telemetry Processor (PREREG v1.05 §3.3)
Processes spread_log.csv across 5 trading days in the session window (07:00-16:00 UTC Mon-Fri).

Outputs:
- Sample count (n) per symbol over session samples with spread > 0 ONLY
- 60th percentile observed spread (spread > 0, numpy linear interpolation)
- Baseline mean spread (S_pre-test, spread > 0)
- Symbol spread gate: min(0.3 pip, p60)
- Zero/inverted spread share
- Share of M1 closes with tick age <= 500 ms, <= 1000 ms, <= 3000 ms
- Median ticks per minute (field ticks_in_prev_60s)
- Markdown template formatted for ACCOUNT.md Section 3

The ACCOUNT.md block is refused (exit code 2) unless every symbol has positive-spread samples
and at least MIN_TRADING_DAYS distinct in-session trading days (PREREG 3.3 item 1).
"""

import sys
import os
import argparse
import csv
import io
from datetime import datetime
from collections import defaultdict
import numpy as np

MIN_TRADING_DAYS = 5  # PREREG 3.3: 5 trading days (Mon-Fri) of in-session sampling
GATE_CAP = 0.30
SYMBOLS = ("EURUSD", "USDJPY")


def read_text_any(path: str) -> str:
    """Reads a CSV written by MT5: UTF-8 (BOM tolerated), ANSI, or UTF-16 (BOM sniffed)."""
    with open(path, "rb") as f:
        raw = f.read()
    if raw.startswith((b"\xff\xfe", b"\xfe\xff")):
        return raw.decode("utf-16")
    if raw.startswith(b"\xef\xbb\xbf"):
        return raw[3:].decode("utf-8")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return raw.decode("cp1252")


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


def _float_or_none(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def process_spread_rows(rows):
    """Processes iterable of dictionary rows from spread_log.csv."""
    symbol_data = defaultdict(lambda: {
        "all_spreads": [],
        "pos_spreads": [],
        "zero_count": 0,
        "tick_ages": [],
        "tick_counts": [],
        "days": set()
    })

    total_rows = 0
    in_session_rows = 0

    for row in rows:
        total_rows += 1
        sym = row.get("symbol", "").strip()
        try:
            dt = parse_timestamp(row.get("time_utc", ""))
            spread = float(row.get("spread_pips", ""))
        except Exception:
            continue

        if not is_in_session(dt):
            continue

        in_session_rows += 1
        data = symbol_data[sym]
        data["days"].add(dt.date())
        data["all_spreads"].append(spread)

        if spread <= 0.0:
            data["zero_count"] += 1
        else:
            data["pos_spreads"].append(spread)

        age = _float_or_none(row.get("tick_age_ms", ""))
        if age is not None:
            data["tick_ages"].append(age)
        cnt = _float_or_none(row.get("ticks_in_prev_60s", ""))
        if cnt is not None:
            data["tick_counts"].append(cnt)

    results = {sym: _summarise_symbol(symbol_data.get(sym)) for sym in SYMBOLS}
    return results, total_rows, in_session_rows


def _summarise_symbol(d):
    if not d or len(d["all_spreads"]) == 0:
        return {"total_samples": 0, "n": 0, "zero_count": 0, "zero_share": 0.0,
                "p60": None, "mean": None, "gate": None, "trading_days": 0,
                "share_lte_500": 0.0, "share_lte_1000": 0.0, "share_lte_3000": 0.0,
                "median_ticks_per_min": 0.0}

    pos_arr = np.array(d["pos_spreads"])
    total_n = len(d["all_spreads"])
    p60 = mean = gate = None
    if len(pos_arr) > 0:
        p60 = float(np.percentile(pos_arr, 60))
        mean = float(np.mean(pos_arr))
        gate = min(GATE_CAP, p60)

    ages = np.array(d["tick_ages"])
    counts = np.array(d["tick_counts"])
    return {
        "total_samples": total_n,
        "n": len(pos_arr),
        "zero_count": d["zero_count"],
        "zero_share": d["zero_count"] / total_n,
        "p60": p60,
        "mean": mean,
        "gate": gate,
        "trading_days": len(d["days"]),
        "share_lte_500": float(np.mean(ages <= 500.0)) if len(ages) else 0.0,
        "share_lte_1000": float(np.mean(ages <= 1000.0)) if len(ages) else 0.0,
        "share_lte_3000": float(np.mean(ages <= 3000.0)) if len(ages) else 0.0,
        "median_ticks_per_min": float(np.median(counts)) if len(counts) else 0.0,
    }


def process_spread_log(csv_path: str):
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Spread log not found: {csv_path}")
    reader = csv.DictReader(io.StringIO(read_text_any(csv_path)))
    return process_spread_rows(reader)


def refusal_reasons(results: dict) -> list:
    """Reasons the ACCOUNT.md block must not be printed (empty list = OK)."""
    reasons = []
    for sym in SYMBOLS:
        d = results[sym]
        if d["n"] == 0:
            reasons.append(f"{sym}: no in-session samples with spread > 0 (n == 0)")
        if d["trading_days"] < MIN_TRADING_DAYS:
            reasons.append(f"{sym}: {d['trading_days']} distinct in-session trading days, need >= {MIN_TRADING_DAYS}")
    return reasons


def fmt(value, spec: str = ".3f") -> str:
    return "n/a" if value is None else format(value, spec)


def print_symbol_stats(sym: str, data: dict) -> None:
    print(f"[{sym}]")
    print(f"  Total Session Samples (N)    : {data['total_samples']}")
    print(f"  Distinct Trading Days        : {data['trading_days']}")
    print(f"  Zero/Inverted Spread Share   : {data['zero_share'] * 100:.2f}% ({data['zero_count']} bars)")
    print(f"  Valid Positive Samples (n)   : {data['n']}")
    print(f"  60th Percentile Spread (>0)  : {fmt(data['p60'])} pips")
    print(f"  Mean Spread (S_pre-test, >0) : {fmt(data['mean'])} pips")
    print(f"  Calculated Gate (min(0.3,p)) : {fmt(data['gate'])} pips")
    print(f"  Tick Age <= 500 ms Share     : {data['share_lte_500'] * 100:.2f}%")
    print(f"  Tick Age <= 1000 ms Share    : {data['share_lte_1000'] * 100:.2f}%")
    print(f"  Tick Age <= 3000 ms Share    : {data['share_lte_3000'] * 100:.2f}%")
    print(f"  Median Ticks per Minute      : {data['median_ticks_per_min']:.1f}\n")


def account_block(sym: str, d: dict) -> str:
    return fr"""### {sym}
- **Observed Sample Size (M1 bars)**: `{d['n']}`
- **60th Percentile Observed Session Spread**: `{d['p60']:.3f} pips`
- **Spread Gate ($\min(0.3\text{{ pip}}, \text{{60th percentile}})$)**: `{d['gate']:.3f} pips`
- **$S_{{\text{{pre-test}}}}$ (Mean Observed Session Spread)**: `{d['mean']:.3f} pips`"""


def print_summary(results: dict, total_rows: int, in_session_rows: int) -> bool:
    """Prints the report; returns False (and no ACCOUNT.md block) when refusal_reasons() is non-empty."""
    print("=" * 72)
    print(" PRE-START SPREAD & TICK MEASUREMENT SUMMARY (PREREG v1.05 §3.3)")
    print("=" * 72)
    print(f"Total Rows Ingested     : {total_rows}")
    print(f"Session Rows (07-16 UTC): {in_session_rows}\n")
    for sym in SYMBOLS:
        print_symbol_stats(sym, results[sym])

    reasons = refusal_reasons(results)
    if reasons:
        print("=" * 72)
        print(" REFUSED: ACCOUNT.md block not printed")
        for r in reasons:
            print(f"  - {r}")
        print("=" * 72)
        return False

    print("=" * 72)
    print(" COPY-PASTE READY FOR ACCOUNT.md Section 3:")
    print("=" * 72)
    print(account_block("EURUSD", results["EURUSD"]) + "\n")
    print(account_block("USDJPY", results["USDJPY"]))
    print("=" * 72)
    return True


def main():
    parser = argparse.ArgumentParser(description="Process spread_log.csv for ACCOUNT.md parameters per PREREG v1.05")
    parser.add_argument("--csv", type=str, default="spread_log.csv", help="Path to spread_log.csv")
    args = parser.parse_args()

    try:
        results, total_rows, in_session_rows = process_spread_log(args.csv)
        if not print_summary(results, total_rows, in_session_rows):
            sys.exit(2)
    except SystemExit:
        raise
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
