#!/usr/bin/env python3
"""
gate_t8.py: One-command Gate Script for Pre-Start Baseline Evaluation (PREREG v1.06 §3.3)
Processes spread_log.csv, applies pre-registered day-coverage rule (>= 95% of 540 session minutes),
excludes partial/gapped days from p60 / S_pre-test / gate, derives ACCOUNT.md Section 3 parameters,
checks signal pass rates, and issues the official T8 gate verdict (PASS / MISS / BLOCKED).

Day-Coverage Rule (Pre-registered 2026-10-15 prior to gate evaluation):
- Expected session minutes per weekday (07:00-16:00 UTC): 540 minutes.
- Minimum required coverage: >= 95% of 540 minutes (i.e. >= 513 rows per symbol per day).
- Partial / gapped days (< 95% coverage) are logged as GAPPED and EXCLUDED from p60,
  S_pre-test (mean), and gate derivation, and do NOT count toward the 5 required days.
"""

import sys
import os
import argparse
import csv
import io
from datetime import datetime
from collections import defaultdict
import numpy as np

try:
    from slow_strategies.scalper.summary import (
        read_text_any,
        is_in_session,
        parse_timestamp,
        _float_or_none,
        account_block,
        MIN_TRADING_DAYS,
        GATE_CAP,
        SYMBOLS
    )
except ImportError:
    from summary import (
        read_text_any,
        is_in_session,
        parse_timestamp,
        _float_or_none,
        account_block,
        MIN_TRADING_DAYS,
        GATE_CAP,
        SYMBOLS
    )

SESSION_MINUTES_PER_DAY = 540
DAY_COVERAGE_THRESHOLD = 0.95
MIN_ROWS_PER_DAY = int(np.ceil(SESSION_MINUTES_PER_DAY * DAY_COVERAGE_THRESHOLD))  # 513


def evaluate_t8(csv_path: str, min_trading_days: int = MIN_TRADING_DAYS):
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Spread log not found: {csv_path}")

    text = read_text_any(csv_path)
    reader = csv.DictReader(io.StringIO(text))

    # Ingest rows grouped by symbol and date
    rows_by_sym_date = defaultdict(lambda: defaultdict(list))
    total_rows = 0
    in_session_rows = 0

    for row in reader:
        total_rows += 1
        sym = row.get("symbol", "").strip()
        if sym not in SYMBOLS:
            continue
        try:
            dt = parse_timestamp(row.get("time_utc", ""))
            spread = float(row.get("spread_pips", ""))
        except Exception:
            continue

        if not is_in_session(dt):
            continue

        in_session_rows += 1
        d_date = dt.date()
        age = _float_or_none(row.get("tick_age_ms", ""))
        cnt = _float_or_none(row.get("ticks_in_prev_60s", ""))

        rows_by_sym_date[sym][d_date].append({
            "dt": dt,
            "spread": spread,
            "age": age,
            "cnt": cnt
        })

    # Evaluate day-coverage per symbol and partition into valid vs gapped
    summaries = {}
    day_coverage_report = {}
    blocking_metrics = {}

    for sym in SYMBOLS:
        sym_dates = rows_by_sym_date[sym]
        valid_days = set()
        gapped_days = {}

        pos_spreads = []
        all_spreads = []
        zero_count = 0
        tick_ages = []
        tick_counts = []
        valid_raw_rows = []

        for d_date in sorted(sym_dates.keys()):
            rows_on_date = sym_dates[d_date]
            cnt_rows = len(rows_on_date)
            coverage = cnt_rows / float(SESSION_MINUTES_PER_DAY)

            if cnt_rows >= MIN_ROWS_PER_DAY:
                valid_days.add(d_date)
                for r in rows_on_date:
                    spr = r["spread"]
                    all_spreads.append(spr)
                    if spr <= 0.0:
                        zero_count += 1
                    else:
                        pos_spreads.append(spr)
                    if r["age"] is not None:
                        tick_ages.append(r["age"])
                    if r["cnt"] is not None:
                        tick_counts.append(r["cnt"])
                    valid_raw_rows.append(r)
            else:
                gapped_days[d_date] = {
                    "rows": cnt_rows,
                    "expected": SESSION_MINUTES_PER_DAY,
                    "coverage": coverage,
                    "status": "GAPPED"
                }

        day_coverage_report[sym] = {
            "valid_days": sorted(valid_days),
            "gapped_days": gapped_days,
            "valid_day_count": len(valid_days),
            "gapped_day_count": len(gapped_days)
        }

        # Calculate metrics over valid days only
        total_samples = len(all_spreads)
        n_pos = len(pos_spreads)
        zero_share = (zero_count / total_samples) if total_samples > 0 else 0.0

        p60 = mean = gate = None
        if n_pos > 0:
            pos_arr = np.array(pos_spreads)
            p60 = float(np.percentile(pos_arr, 60))
            mean = float(np.mean(pos_arr))
            gate = min(GATE_CAP, p60)

        ages_arr = np.array(tick_ages) if tick_ages else np.array([])
        cnts_arr = np.array(tick_counts) if tick_counts else np.array([])

        sh_500 = float(np.mean(ages_arr <= 500.0)) if len(ages_arr) else 0.0
        sh_1000 = float(np.mean(ages_arr <= 1000.0)) if len(ages_arr) else 0.0
        sh_3000 = float(np.mean(ages_arr <= 3000.0)) if len(ages_arr) else 0.0
        med_ticks = float(np.median(cnts_arr)) if len(cnts_arr) else 0.0

        summaries[sym] = {
            "total_samples": total_samples,
            "n": n_pos,
            "zero_count": zero_count,
            "zero_share": zero_share,
            "p60": p60,
            "mean": mean,
            "gate": gate,
            "trading_days": len(valid_days),
            "share_lte_500": sh_500,
            "share_lte_1000": sh_1000,
            "share_lte_3000": sh_3000,
            "median_ticks_per_min": med_ticks
        }

        # Signal blocking telemetry over valid rows
        tot_valid = len(valid_raw_rows)
        if tot_valid == 0 or gate is None:
            blocking_metrics[sym] = {
                "total": tot_valid,
                "pass_spread": 0.0,
                "pass_freshness": 0.0,
                "pass_joint": 0.0,
                "blocked_joint": 1.0
            }
        else:
            pass_spread_cnt = sum(1 for r in valid_raw_rows if r["spread"] <= gate)
            pass_fresh_cnt = sum(1 for r in valid_raw_rows if r["age"] is not None and r["age"] <= 3000.0)
            pass_joint_cnt = sum(1 for r in valid_raw_rows if r["spread"] <= gate and (r["age"] is not None and r["age"] <= 3000.0))

            blocking_metrics[sym] = {
                "total": tot_valid,
                "pass_spread": pass_spread_cnt / tot_valid,
                "pass_freshness": pass_fresh_cnt / tot_valid,
                "pass_joint": pass_joint_cnt / tot_valid,
                "blocked_joint": 1.0 - (pass_joint_cnt / tot_valid)
            }

    # Verdict determination
    refusal_reasons = []
    for sym in SYMBOLS:
        rep = day_coverage_report[sym]
        s = summaries[sym]
        if rep["valid_day_count"] < min_trading_days:
            refusal_reasons.append(
                f"{sym}: insufficient valid trading days ({rep['valid_day_count']}/{min_trading_days} required, {rep['gapped_day_count']} gapped days excluded)"
            )
        if s["n"] == 0:
            refusal_reasons.append(f"{sym}: 0 valid positive spread samples")
        elif s["gate"] is None or s["gate"] <= 0.001:
            refusal_reasons.append(f"{sym}: degenerate gate ({s['gate']})")

    if refusal_reasons:
        verdict = "MISS"
        verdict_detail = "; ".join(refusal_reasons)
    else:
        # Check signal blocking rate
        high_blocking = False
        block_reasons = []
        for sym in SYMBOLS:
            bm = blocking_metrics[sym]
            if bm["blocked_joint"] > 0.50:
                high_blocking = True
                block_reasons.append(f"{sym}: {bm['blocked_joint']*100:.1f}% signals blocked (> 50%)")

        if high_blocking:
            verdict = "BLOCKED"
            verdict_detail = "; ".join(block_reasons)
        else:
            verdict = "PASS"
            verdict_detail = "All gate criteria satisfied; signal blocking within operating limits"

    return {
        "verdict": verdict,
        "detail": verdict_detail,
        "summaries": summaries,
        "day_coverage": day_coverage_report,
        "blocking": blocking_metrics,
        "total_rows": total_rows,
        "in_session_rows": in_session_rows
    }


def print_t8_report(res: dict) -> None:
    print("=" * 78)
    print(" T8 GATE EVALUATION REPORT: PRE-START SPREAD BASELINE (PREREG v1.06 §3.3)")
    print(" Day-Coverage Rule: >= 95% of 540 session min (>= 513 rows); partial = GAPPED")
    print("=" * 78)
    print(f"Total CSV Rows Ingested : {res['total_rows']}")
    print(f"In-Session Rows (07-16) : {res['in_session_rows']}")
    print(f"T8 GATE VERDICT         : {res['verdict']}")
    print(f"Verdict Details         : {res['detail']}\n")

    for sym in SYMBOLS:
        d = res["summaries"][sym]
        cov = res["day_coverage"][sym]
        bm = res["blocking"][sym]
        print(f"[{sym}]")
        print(f"  Valid Trading Days (>=95%)   : {cov['valid_day_count']} / {MIN_TRADING_DAYS} required")
        if cov["valid_days"]:
            print(f"    Valid Dates                : {', '.join(str(x) for x in cov['valid_days'])}")
        if cov["gapped_days"]:
            print(f"    Gapped/Excluded Days       : {cov['gapped_day_count']}")
            for g_date, g_info in cov["gapped_days"].items():
                print(f"      - {g_date}: {g_info['rows']}/{g_info['expected']} rows ({g_info['coverage']*100:.1f}%) -> EXCLUDED")
        print(f"  Valid Session M1 Bars (N)    : {d['total_samples']}")
        print(f"  Valid Positive Samples (n)   : {d['n']}")
        print(f"  Zero/Inverted Spread Share   : {d['zero_share'] * 100:.2f}% ({d['zero_count']} bars)")
        p60_str = f"{d['p60']:.3f} pips" if d['p60'] is not None else "n/a"
        mean_str = f"{d['mean']:.3f} pips" if d['mean'] is not None else "n/a"
        gate_str = f"{d['gate']:.3f} pips" if d['gate'] is not None else "n/a"
        print(f"  60th Percentile Spread (>0)  : {p60_str}")
        print(f"  Mean Spread (S_pre-test, >0) : {mean_str}")
        print(f"  Derived Gate (min(0.3, P60)) : {gate_str}")
        print(f"  Tick Age <= 500 ms Share     : {d['share_lte_500'] * 100:.2f}%")
        print(f"  Tick Age <= 1000 ms Share    : {d['share_lte_1000'] * 100:.2f}%")
        print(f"  Tick Age <= 3000 ms Share    : {d['share_lte_3000'] * 100:.2f}%")
        print(f"  Median Ticks per Minute      : {d['median_ticks_per_min']:.1f}")
        print(f"  Signal Pass Rate (Spread)    : {bm['pass_spread'] * 100:.2f}%")
        print(f"  Signal Pass Rate (Freshness) : {bm['pass_freshness'] * 100:.2f}%")
        print(f"  Joint Signal Pass Rate       : {bm['pass_joint'] * 100:.2f}%")
        print(f"  Joint Signal Blocked Rate    : {bm['blocked_joint'] * 100:.2f}%\n")

    print("=" * 78)
    if res["verdict"] == "PASS":
        print(" ACCOUNT.md SECTION 3 (VERIFIED READY FOR COMMIT):")
        print("=" * 78)
        print(account_block("EURUSD", res["summaries"]["EURUSD"]) + "\n")
        print(account_block("USDJPY", res["summaries"]["USDJPY"]))
    elif res["verdict"] == "BLOCKED":
        print(" GATE VERDICT: BLOCKED")
        print(" More than half of expected breakout signals would be blocked by spread/freshness gates.")
        print(" Options per protocol:")
        print("  1) Extend observation window or wait for calmer market conditions.")
        print("  2) Document market liquidity regime in trial records without modifying PREREG parameters.")
        print("  3) Halt trial before freeze without spending evidential sample.")
    else:
        print(" GATE VERDICT: MISS")
        print(" Dataset does not meet minimum pre-start requirements:")
        print(f"  {res['detail']}")
    print("=" * 78)


def main():
    parser = argparse.ArgumentParser(description="T8 Gate Automated Evaluator for SpreadLog Baseline")
    parser.add_argument("--csv", type=str, required=True, help="Path to spread_log.csv")
    args = parser.parse_args()

    try:
        res = evaluate_t8(args.csv)
        print_t8_report(res)
        if res["verdict"] == "PASS":
            sys.exit(0)
        elif res["verdict"] == "BLOCKED":
            sys.exit(2)
        else:
            sys.exit(1)
    except Exception as e:
        print(f"Error executing T8 evaluation: {e}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
