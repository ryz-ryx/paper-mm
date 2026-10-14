#!/usr/bin/env python3
"""
test_analyze.py: Unit tests for Scalper Statistical Evaluator
Verifies PREREG v1.02 evaluation logic:
- Known HIT case
- Known MISS case
- Burn-in handling
- Plumbing rows exclusion
- Spread fidelity check
- Insufficient data handling (INVALID-not-evaluable)
"""

import pytest
import math
from slow_strategies.scalper.analyze import evaluate_scalper
from slow_strategies.scalper.summary import process_spread_rows


def generate_synthetic_trades(
    n_burn: int = 100,
    n_eval: int = 900,
    burn_win_rate: float = 0.55,
    eval_win_rate: float = 0.65,
    win_net_pips: float = 4.6,
    loss_net_pips: float = -5.4,
    spread_eur: float = 0.22,
    spread_jpy: float = 0.30,
    n_plumbing: int = 0
):
    rows = []
    ticket = 100000

    # 1. Plumbing trades if requested (evidential=0)
    for i in range(n_plumbing):
        ticket += 1
        rows.append({
            "ticket": str(ticket),
            "evidential": "0",
            "window_id": str(1000 + i),
            "symbol": "EURUSD",
            "side": "BUY",
            "spread_at_fill": "0.80",
            "net_pips": "50.0",
            "commission_pips": "0.2"
        })

    # 2. Burn-in trades (evidential=1)
    for i in range(n_burn):
        ticket += 1
        is_win = (i < int(n_burn * burn_win_rate))
        net = win_net_pips if is_win else loss_net_pips
        sym = "EURUSD" if i % 2 == 0 else "USDJPY"
        spread = spread_eur if sym == "EURUSD" else spread_jpy
        rows.append({
            "ticket": str(ticket),
            "evidential": "1",
            "window_id": str(2000 + i),
            "symbol": sym,
            "side": "BUY" if i % 2 == 0 else "SELL",
            "spread_at_fill": str(spread),
            "net_pips": str(net),
            "commission_pips": "0.2"
        })

    # 3. Evaluation trades (evidential=1)
    for i in range(n_eval):
        ticket += 1
        is_win = (i < int(n_eval * eval_win_rate))
        net = win_net_pips if is_win else loss_net_pips
        sym = "EURUSD" if i % 2 == 0 else "USDJPY"
        spread = spread_eur if sym == "EURUSD" else spread_jpy
        rows.append({
            "ticket": str(ticket),
            "evidential": "1",
            "window_id": str(3000 + i),
            "symbol": sym,
            "side": "BUY" if i % 2 == 0 else "SELL",
            "spread_at_fill": str(spread),
            "net_pips": str(net),
            "commission_pips": "0.2"
        })

    return rows


def test_known_hit_case():
    """Confirms HIT verdict when win rate and t-test pass, and spread fidelity is maintained."""
    rows = generate_synthetic_trades(
        n_burn=100,
        n_eval=900,
        burn_win_rate=0.55,
        eval_win_rate=0.68,
        win_net_pips=4.6,
        loss_net_pips=-5.4,
        spread_eur=0.22,
        spread_jpy=0.30
    )

    res = evaluate_scalper(
        rows=rows,
        s_pretest_eurusd=0.25,
        s_pretest_usdjpy=0.35,
        alpha=0.025,
        burn_in_n=100,
        target_n=900
    )

    assert res["verdict"] == "HIT"
    assert res["evaluation"]["binom_pass"] is True
    assert res["evaluation"]["t_pass"] is True
    assert res["evaluation"]["spread_fidelity_pass"] is True
    assert res["evaluation"]["n_reached_pass"] is True
    assert res["evaluation"]["n"] == 900
    assert res["burn_in"]["n"] == 100


def test_known_miss_case():
    """Confirms MISS verdict when strategy fails to outperform null break-even rate."""
    rows = generate_synthetic_trades(
        n_burn=100,
        n_eval=900,
        burn_win_rate=0.55,
        eval_win_rate=0.50, # 50% win rate under 54% break-even hurdle
        win_net_pips=4.6,
        loss_net_pips=-5.4,
        spread_eur=0.22,
        spread_jpy=0.30
    )

    res = evaluate_scalper(
        rows=rows,
        s_pretest_eurusd=0.25,
        s_pretest_usdjpy=0.35,
        alpha=0.025
    )

    assert res["verdict"] == "MISS"
    assert res["evaluation"]["binom_pass"] is False
    assert res["evaluation"]["t_pass"] is False


def test_burn_in_handling():
    """Verifies that first 100 trades accurately calibrate p0 and are excluded from evaluation."""
    rows = generate_synthetic_trades(
        n_burn=100,
        n_eval=900,
        burn_win_rate=0.60,
        eval_win_rate=0.68,
        win_net_pips=4.5,
        loss_net_pips=-5.5
    )

    res = evaluate_scalper(rows=rows, s_pretest_eurusd=0.25, s_pretest_usdjpy=0.35)

    burn = res["burn_in"]
    assert burn["n"] == 100
    assert math.isclose(burn["w_bar"], 4.5, rel_tol=1e-5)
    assert math.isclose(burn["abs_l_bar"], 5.5, rel_tol=1e-5)
    expected_p0 = 5.5 / (4.5 + 5.5) # 0.55
    assert math.isclose(burn["p0"], expected_p0, rel_tol=1e-5)
    assert res["evaluation"]["n"] == 900


def test_plumbing_rows_excluded():
    """Verifies that plumbing rows (evidential=0) are strictly excluded from statistical analysis."""
    rows = generate_synthetic_trades(
        n_burn=100,
        n_eval=900,
        burn_win_rate=0.55,
        eval_win_rate=0.68,
        n_plumbing=50
    )

    res = evaluate_scalper(rows=rows, s_pretest_eurusd=0.25, s_pretest_usdjpy=0.35)

    assert res["total_rows"] == 1050
    assert res["plumbing_rows"] == 50
    assert res["evidential_rows"] == 1000
    assert res["verdict"] == "HIT"


def test_spread_fidelity_breach():
    """Verifies that realized spread exceeding 1.20 * S_pre-test results in MISS."""
    rows = generate_synthetic_trades(
        n_burn=100,
        n_eval=900,
        burn_win_rate=0.55,
        eval_win_rate=0.68,
        spread_eur=0.35 # > 1.20 * 0.25 = 0.30
    )

    res = evaluate_scalper(rows=rows, s_pretest_eurusd=0.25, s_pretest_usdjpy=0.35)

    assert res["evaluation"]["eur_spread_pass"] is False
    assert res["evaluation"]["spread_fidelity_pass"] is False
    assert res["verdict"] == "MISS"


def test_insufficient_evidential_data():
    """Verifies that fewer than 1000 evidential trades returns INVALID-not-evaluable."""
    rows = generate_synthetic_trades(n_burn=100, n_eval=500) # Only 600 total

    res = evaluate_scalper(rows=rows, s_pretest_eurusd=0.25, s_pretest_usdjpy=0.35)

    assert res["verdict"] == "INVALID-not-evaluable"
    assert "Insufficient evidential trades" in res["reason"]


def test_summary_zero_spread_exclusion():
    """Verifies that summary.py excludes spread <= 0 from p60 and mean, and tracks zero share accurately."""
    rows = []
    # 20 rows with spread = 0.0 (in-session Monday 08:00)
    for i in range(20):
        rows.append({
            "time_utc": f"2026-10-19 08:00:{i:02d}",
            "symbol": "EURUSD",
            "spread_pips": "0.0",
            "zero_spread": "1",
            "tick_age_ms": "100.0",
            "ticks_prev_60s": "30"
        })
    # 80 rows with spread = 0.20 (in-session Monday 09:00+)
    for i in range(80):
        m = i // 60
        s = i % 60
        rows.append({
            "time_utc": f"2026-10-19 09:{m:02d}:{s:02d}",
            "symbol": "EURUSD",
            "spread_pips": "0.20",
            "zero_spread": "0",
            "tick_age_ms": "150.0",
            "ticks_prev_60s": "35"
        })

    results, total_rows, in_session_rows = process_spread_rows(rows)

    assert total_rows == 100
    assert in_session_rows == 100

    eur = results["EURUSD"]
    assert eur["total_samples"] == 100
    assert eur["zero_count"] == 20
    assert math.isclose(eur["zero_share"], 0.20, rel_tol=1e-5)
    assert eur["n"] == 80 # Only positive spreads counted for ACCOUNT.md
    assert math.isclose(eur["p60"], 0.20, rel_tol=1e-5)
    assert math.isclose(eur["mean"], 0.20, rel_tol=1e-5)
    assert math.isclose(eur["gate"], 0.20, rel_tol=1e-5)


def test_summary_tick_age_shares():
    """Verifies that summary.py computes tick-age shares (<=500, <=1000, <=3000 ms) and median ticks/min."""
    rows = []
    # 10 rows age 400 ms
    for i in range(10):
        rows.append({
            "time_utc": f"2026-10-19 10:00:{i:02d}",
            "symbol": "USDJPY",
            "spread_pips": "0.15",
            "zero_spread": "0",
            "tick_age_ms": "400.0",
            "ticks_prev_60s": "20"
        })
    # 10 rows age 800 ms
    for i in range(10):
        rows.append({
            "time_utc": f"2026-10-19 10:01:{i:02d}",
            "symbol": "USDJPY",
            "spread_pips": "0.15",
            "zero_spread": "0",
            "tick_age_ms": "800.0",
            "ticks_prev_60s": "30"
        })
    # 10 rows age 2000 ms
    for i in range(10):
        rows.append({
            "time_utc": f"2026-10-19 10:02:{i:02d}",
            "symbol": "USDJPY",
            "spread_pips": "0.15",
            "zero_spread": "0",
            "tick_age_ms": "2000.0",
            "ticks_prev_60s": "40"
        })
    # 10 rows age 4000 ms
    for i in range(10):
        rows.append({
            "time_utc": f"2026-10-19 10:03:{i:02d}",
            "symbol": "USDJPY",
            "spread_pips": "0.15",
            "zero_spread": "0",
            "tick_age_ms": "4000.0",
            "ticks_prev_60s": "50"
        })

    results, total_rows, in_session_rows = process_spread_rows(rows)

    jpy = results["USDJPY"]
    assert jpy["total_samples"] == 40
    assert math.isclose(jpy["share_lte_500"], 10.0 / 40.0, rel_tol=1e-5)
    assert math.isclose(jpy["share_lte_1000"], 20.0 / 40.0, rel_tol=1e-5)
    assert math.isclose(jpy["share_lte_3000"], 30.0 / 40.0, rel_tol=1e-5)
    # ticks_prev_60s are 10 of 20, 10 of 30, 10 of 40, 10 of 50 -> median = (30 + 40)/2 = 35.0
    assert math.isclose(jpy["median_ticks_per_min"], 35.0, rel_tol=1e-5)

