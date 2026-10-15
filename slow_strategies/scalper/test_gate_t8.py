#!/usr/bin/env python3
"""
test_gate_t8.py: Unit tests for T8 Gate Automation Script & Day-Coverage Rule
Tests:
1. Full Days Pass: 5 full weekdays (540 session rows each) -> 5 valid days, 0 gapped -> PASS.
2. 94% Day is Gapped & Excluded:
   - A day with 507/540 rows (93.9% / 94%) is detected as GAPPED and excluded.
   - Outlier spreads from that 94% day do not contaminate p60 or S_pre-test.
   - If only 4 full days exist alongside the 94% day -> MISS (insufficient valid trading days).
3. Day 1 of 2026-10-15 is Gapped:
   - Partial day with 48 rows (15:12-15:59 UTC) is explicitly identified as GAPPED and excluded.
4. Signal Blocking Check (> 50% blocked -> BLOCKED).
5. Degenerate gate check (all zero spread -> MISS).
"""

import os
import pytest
import tempfile
from datetime import datetime, timedelta
import numpy as np

try:
    from slow_strategies.scalper.gate_t8 import evaluate_t8, MIN_ROWS_PER_DAY, SESSION_MINUTES_PER_DAY
except ImportError:
    from gate_t8 import evaluate_t8, MIN_ROWS_PER_DAY, SESSION_MINUTES_PER_DAY


def create_spread_log(filepath: str, day_specs: list):
    """
    day_specs: list of dicts:
      {
        'date': 'YYYY-MM-DD',
        'start_minute': int (0 to 539, minute offset from 07:00 UTC),
        'row_count': int,
        'spread_fn': func(symbol, dt) -> float,
        'age_fn': func(symbol, dt) -> float,
        'cnt_fn': func(symbol, dt) -> int
      }
    """
    with open(filepath, "w", encoding="utf-8") as f:
        f.write("time_utc,symbol,spread_pips,zero_spread,tick_age_ms,ticks_in_prev_60s\n")
        for spec in day_specs:
            d_date = datetime.strptime(spec["date"], "%Y-%m-%d")
            base_time = d_date.replace(hour=7, minute=0, second=0)
            start_m = spec.get("start_minute", 0)
            n_rows = spec.get("row_count", 540)
            spread_fn = spec.get("spread_fn", lambda s, dt: 0.10)
            age_fn = spec.get("age_fn", lambda s, dt: 100.0)
            cnt_fn = spec.get("cnt_fn", lambda s, dt: 80)

            for i in range(n_rows):
                dt = base_time + timedelta(minutes=(start_m + i))
                ts_str = dt.strftime("%Y-%m-%d %H:%M:%S")
                for sym in ("EURUSD", "USDJPY"):
                    spr = spread_fn(sym, dt)
                    zero_flag = 1 if spr <= 0.0 else 0
                    age = age_fn(sym, dt)
                    ticks = cnt_fn(sym, dt)
                    f.write(f"{ts_str},{sym},{spr:.3f},{zero_flag},{age:.1f},{ticks}\n")


def test_full_days_pass():
    """5 full weekdays with 540 rows each must PASS."""
    days = ["2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22"]
    day_specs = [{"date": d, "start_minute": 0, "row_count": 540} for d in days]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf:
        csv_path = tf.name

    try:
        create_spread_log(csv_path, day_specs)
        res = evaluate_t8(csv_path)

        assert res["verdict"] == "PASS"
        for sym in ("EURUSD", "USDJPY"):
            rep = res["day_coverage"][sym]
            assert rep["valid_day_count"] == 5
            assert rep["gapped_day_count"] == 0
            assert res["summaries"][sym]["n"] == 5 * 540
            assert res["summaries"][sym]["gate"] == 0.10
    finally:
        if os.path.exists(csv_path):
            os.remove(csv_path)


def test_94_percent_day_is_gapped_and_excluded():
    """
    A day with 507 rows out of 540 (93.88% / 94%) must be flagged as GAPPED and excluded.
    Test both:
    1) 4 full days + 1 94% day -> MISS (insufficient valid days).
    2) 5 full days + 1 94% day with outlier spreads (10.0 pips) -> 94% day spreads excluded from p60 and mean!
    """
    # Case 1: 4 full days + 1 day with 507 rows (93.88%)
    day_specs_case1 = [
        {"date": "2026-10-16", "row_count": 540},
        {"date": "2026-10-19", "row_count": 540},
        {"date": "2026-10-20", "row_count": 540},
        {"date": "2026-10-21", "row_count": 540},
        {"date": "2026-10-22", "row_count": 507},  # 507 < 513 (93.88% coverage)
    ]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf:
        csv_path = tf.name

    try:
        create_spread_log(csv_path, day_specs_case1)
        res = evaluate_t8(csv_path)

        assert res["verdict"] == "MISS"
        for sym in ("EURUSD", "USDJPY"):
            rep = res["day_coverage"][sym]
            assert rep["valid_day_count"] == 4
            assert rep["gapped_day_count"] == 1
            gapped_info = rep["gapped_days"][datetime.strptime("2026-10-22", "%Y-%m-%d").date()]
            assert gapped_info["status"] == "GAPPED"
            assert gapped_info["rows"] == 507
            assert pytest.approx(gapped_info["coverage"], 0.001) == 507 / 540.0
    finally:
        if os.path.exists(csv_path):
            os.remove(csv_path)

    # Case 2: 5 full days (spread = 0.10) + 1 day with 507 rows and outlier spread = 15.0 pips
    day_specs_case2 = [
        {"date": "2026-10-16", "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-19", "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-20", "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-21", "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-22", "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-23", "row_count": 507, "spread_fn": lambda s, dt: 15.0},  # Gapped day with contaminated spread
    ]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf2:
        csv_path2 = tf2.name

    try:
        create_spread_log(csv_path2, day_specs_case2)
        res2 = evaluate_t8(csv_path2)

        assert res2["verdict"] == "PASS"
        for sym in ("EURUSD", "USDJPY"):
            rep = res2["day_coverage"][sym]
            assert rep["valid_day_count"] == 5
            assert rep["gapped_day_count"] == 1
            # Verify outlier spread of 15.0 was completely EXCLUDED from p60 and mean!
            assert res2["summaries"][sym]["n"] == 5 * 540
            assert pytest.approx(res2["summaries"][sym]["mean"], 0.001) == 0.10
            assert pytest.approx(res2["summaries"][sym]["p60"], 0.001) == 0.10
            assert pytest.approx(res2["summaries"][sym]["gate"], 0.001) == 0.10
    finally:
        if os.path.exists(csv_path2):
            os.remove(csv_path2)


def test_day1_2026_10_15_is_gapped():
    """
    Day 1 of 2026-10-15 with ~48 rows (from 15:12 to 15:59 UTC) must be explicitly flagged
    as GAPPED and excluded from all metrics.
    """
    # 48 rows starting at minute 492 (15:12 UTC)
    day_specs = [
        {"date": "2026-10-15", "start_minute": 492, "row_count": 48, "spread_fn": lambda s, dt: 0.12},
        {"date": "2026-10-16", "start_minute": 0, "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-19", "start_minute": 0, "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-20", "start_minute": 0, "row_count": 540, "spread_fn": lambda s, dt: 0.10},
        {"date": "2026-10-21", "start_minute": 0, "row_count": 540, "spread_fn": lambda s, dt: 0.10},
    ]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf:
        csv_path = tf.name

    try:
        create_spread_log(csv_path, day_specs)
        res = evaluate_t8(csv_path)

        # 4 valid days + 1 gapped day (2026-10-15) -> MISS (< 5 valid required)
        assert res["verdict"] == "MISS"
        assert "insufficient valid trading days" in res["detail"]

        for sym in ("EURUSD", "USDJPY"):
            rep = res["day_coverage"][sym]
            d_oct15 = datetime.strptime("2026-10-15", "%Y-%m-%d").date()
            assert d_oct15 in rep["gapped_days"]
            assert rep["gapped_days"][d_oct15]["status"] == "GAPPED"
            assert rep["gapped_days"][d_oct15]["rows"] == 48
            assert pytest.approx(rep["gapped_days"][d_oct15]["coverage"], 0.001) == 48 / 540.0
            # Rows on 2026-10-15 were NOT included in sample count
            assert res["summaries"][sym]["n"] == 4 * 540
    finally:
        if os.path.exists(csv_path):
            os.remove(csv_path)


def test_high_signal_blocking_verdict():
    """When spreads or stale tick ages block > 50% of signals, verdict must be BLOCKED."""
    days = ["2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22"]
    # Gate capped at 0.30; spread = 0.50 will fail spread check; tick age 4000 ms will fail freshness check
    day_specs = [{"date": d, "row_count": 540, "spread_fn": lambda s, dt: 0.50, "age_fn": lambda s, dt: 4000.0} for d in days]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf:
        csv_path = tf.name

    try:
        create_spread_log(csv_path, day_specs)
        res = evaluate_t8(csv_path)

        assert res["verdict"] == "BLOCKED"
        assert "signals blocked (> 50%)" in res["detail"]
        for sym in ("EURUSD", "USDJPY"):
            assert res["blocking"][sym]["blocked_joint"] > 0.50
    finally:
        if os.path.exists(csv_path):
            os.remove(csv_path)


def test_degenerate_gate():
    """All zero spreads result in degenerate gate -> MISS."""
    days = ["2026-10-16", "2026-10-19", "2026-10-20", "2026-10-21", "2026-10-22"]
    day_specs = [{"date": d, "row_count": 540, "spread_fn": lambda s, dt: 0.0} for d in days]

    with tempfile.NamedTemporaryFile(suffix=".csv", delete=False) as tf:
        csv_path = tf.name

    try:
        create_spread_log(csv_path, day_specs)
        res = evaluate_t8(csv_path)

        assert res["verdict"] == "MISS"
        for sym in ("EURUSD", "USDJPY"):
            assert res["summaries"][sym]["n"] == 0
    finally:
        if os.path.exists(csv_path):
            os.remove(csv_path)
