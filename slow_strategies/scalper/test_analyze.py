#!/usr/bin/env python3
"""
test_analyze.py: Unit tests for the Scalper Statistical Evaluator and Spread Summary (PREREG v1.05).

Deterministic: no network, no MT5, no wall clock (now_utc_ms is always passed explicitly).
Verifies:
- HIT / MISS / INVALID / NOT_YET_EVALUABLE verdicts and each HIT criterion in isolation
- burn-in calibration (first 100 only, non-constant magnitudes), p0, c_bar, s_burn
- cluster-robust one-sided t-test (several trades per window_id), alpha = 0.025 boundaries
- run_id filter, evidential fail-closed, hash / gate / exit_reason integrity, daily stop, hard stop
- D-4: EXTERNAL row / incident-file row -> INVALID; D-3: hard stop never derived from rows or restarts
- static source tests on ScalperEA.mq5 (D-1 adverse-side floating mark, D-4 incident log + operational halt)
- UTF-8 / ANSI / UTF-16 input, CLI (no --alpha etc.)
- summary.py: percentile / mean / gate cap, session filter, tick-age shares, median ticks,
  five-day and n == 0 refusal
"""

import ast
import math
import random
import re
from pathlib import Path

import pytest
import scipy.stats

from slow_strategies.scalper import analyze
from slow_strategies.scalper.analyze import evaluate_scalper
from slow_strategies.scalper import summary
from slow_strategies.scalper.summary import process_spread_rows

RUN = "RUN-A"
SHA = "ab" * 32
GATE_EUR = 0.30
GATE_JPY = 0.25
T0_MS = 1792483200000  # 2026-10-20 08:00:00 UTC (a Tuesday)
SPACING_MS = 6 * 3600 * 1000  # 4 trades per UTC day: no daily-stop breach by accident
FAR_FUTURE_MS = 4102444800000  # 2100-01-01
NOW_MS = T0_MS + 400 * 86400 * 1000
WIN_VALS = [4.6, 3.9, 4.9, 2.7, 4.1]
LOSS_VALS = [-5.4, -4.7, -5.9, -3.8, -5.1]


def nets(n, win_rate, wins=WIN_VALS, losses=LOSS_VALS):
    """Deterministic interleaved win/loss net pips with the requested win rate (cycled magnitudes)."""
    out, w, l = [], 0, 0
    for i in range(n):
        if math.floor((i + 1) * win_rate) > math.floor(i * win_rate):
            out.append(wins[w % len(wins)])
            w += 1
        else:
            out.append(losses[l % len(losses)])
            l += 1
    return out


def row(i, net, symbol=None, spread=0.22, window=None, run=RUN, evidential="1", exit_reason="TAKE_PROFIT",
        sha=SHA, gate=None, fill_ms=None, hold_ms=60000, restart="0", comm=0.2):
    symbol = symbol or ("EURUSD" if i % 2 == 0 else "USDJPY")
    return {
        "ticket": str(100000 + i), "evidential": evidential, "run_id": run, "account_md_sha256": sha,
        "window_id": str(window if window is not None else 5000 + i), "symbol": symbol,
        "symbol_gate": f"{(GATE_EUR if symbol == 'EURUSD' else GATE_JPY) if gate is None else gate:.3f}",
        "side": "BUY", "fill_time_msc": str(T0_MS + i * SPACING_MS if fill_ms is None else fill_ms),
        "hold_ms": str(hold_ms), "spread_at_fill": str(spread), "net_pips": str(net),
        "commission_pips": str(comm), "exit_reason": exit_reason, "restart": restart,
    }


def make_rows(n_burn=100, n_eval=900, burn_rate=0.55, eval_rate=0.68, burn_vals=None, eval_vals=None,
              spread_eur=0.22, spread_jpy=0.30, per_window=1, extra=0):
    """Burn-in rows, then evaluation rows (per_window trades share one window_id), then extra rows."""
    bw, bl = burn_vals or (WIN_VALS, LOSS_VALS)
    ew, el = eval_vals or (WIN_VALS, LOSS_VALS)
    rows = []
    for i, x in enumerate(nets(n_burn, burn_rate, bw, bl)):
        sym = "EURUSD" if i % 2 == 0 else "USDJPY"
        rows.append(row(i, x, sym, spread_eur if sym == "EURUSD" else spread_jpy))
    for j, x in enumerate(nets(n_eval + extra, eval_rate, ew, el)):
        i = n_burn + j
        sym = "EURUSD" if i % 2 == 0 else "USDJPY"
        rows.append(row(i, x, sym, spread_eur if sym == "EURUSD" else spread_jpy,
                        window=7000 + j // per_window))
    return rows


def evaluate(rows, run_id=RUN, sha=SHA, gate_eur=GATE_EUR, gate_jpy=GATE_JPY,
             s_eur=0.25, s_jpy=0.35, hard_stop=FAR_FUTURE_MS, now=NOW_MS, incidents=None):
    return evaluate_scalper(rows, run_id, sha, gate_eur, gate_jpy, s_eur, s_jpy, hard_stop, now,
                            incident_rows=incidents)


def find_wins_for_binom_p(n, p0, lo, hi):
    """Smallest win count k whose one-sided binomial p-value lies in [lo, hi]."""
    for k in range(n + 1):
        p = scipy.stats.binomtest(k, n, p0, alternative="greater").pvalue
        if lo <= p <= hi:
            return k
    raise AssertionError("no k found")


# --------------------------------------------------------------------------------------
# Verdicts
# --------------------------------------------------------------------------------------

def test_known_hit_case():
    res = evaluate(make_rows())
    ev = res["evaluation"]
    assert res["verdict"] == "HIT"
    assert ev["binom_pass"] is True and ev["t_pass"] is True
    assert ev["spread_fidelity_pass"] is True and ev["n_reached_pass"] is True
    assert ev["n"] == 900 and res["burn_in"]["n"] == 100


def test_known_miss_case():
    res = evaluate(make_rows(eval_rate=0.50))
    assert res["verdict"] == "MISS"
    assert res["evaluation"]["binom_pass"] is False
    assert res["evaluation"]["t_pass"] is False


def test_hit_requires_binomial_test():
    # p0 = 0.9 (small wins, large losses); win rate 0.85 < p0 while mean net is clearly positive
    rows = make_rows(burn_rate=0.5, burn_vals=([1.0], [-9.0]), eval_rate=0.85, eval_vals=([1.0], [-0.5]))
    res = evaluate(rows)
    assert res["evaluation"]["t_pass"] is True
    assert res["evaluation"]["binom_pass"] is False
    assert res["verdict"] == "MISS"


def test_hit_requires_t_test():
    # p0 = 0.1 (big wins, small losses); win rate 0.30 beats p0 while mean net is negative
    rows = make_rows(burn_rate=0.5, burn_vals=([9.0], [-1.0]), eval_rate=0.30, eval_vals=([1.0], [-5.0]))
    res = evaluate(rows)
    assert res["evaluation"]["binom_pass"] is True
    assert res["evaluation"]["t_pass"] is False
    assert res["verdict"] == "MISS"


def test_hit_requires_spread_fidelity():
    res = evaluate(make_rows(spread_eur=0.35))  # > 1.20 * 0.25
    assert res["evaluation"]["binom_pass"] and res["evaluation"]["t_pass"]
    assert res["evaluation"]["eur_spread_pass"] is False
    assert res["evaluation"]["spread_fidelity_pass"] is False
    assert res["verdict"] == "MISS"


def test_hit_requires_timeline():
    rows = make_rows()
    last_fill = int(rows[999]["fill_time_msc"])
    on_time = evaluate(rows, hard_stop=last_fill)  # on the hard stop itself: met (<=)
    late = evaluate(rows, hard_stop=last_fill - 1)
    assert on_time["verdict"] == "HIT" and on_time["evaluation"]["n_reached_pass"] is True
    assert late["evaluation"]["binom_pass"] and late["evaluation"]["t_pass"]
    assert late["evaluation"]["n_reached_pass"] is False
    assert late["verdict"] == "MISS"


def test_timeline_uses_900th_evaluation_trade_not_extras():
    rows = make_rows(extra=40)
    fill_900th = int(rows[999]["fill_time_msc"])
    res = evaluate(rows, hard_stop=fill_900th)
    assert res["evaluation"]["last_fill_time_msc"] == fill_900th
    assert res["verdict"] == "HIT"


# --------------------------------------------------------------------------------------
# Burn-in and sample slicing
# --------------------------------------------------------------------------------------

def test_burn_in_uses_only_first_100_trades():
    # burn magnitudes (4.5 / -5.5) differ from evaluation magnitudes (3.0 / -2.0)
    rows = make_rows(burn_rate=0.60, burn_vals=([4.5], [-5.5]), eval_vals=([3.0], [-2.0]))
    res = evaluate(rows)
    burn = res["burn_in"]
    assert burn["n"] == 100
    assert math.isclose(burn["w_bar"], 4.5, rel_tol=1e-9)
    assert math.isclose(burn["abs_l_bar"], 5.5, rel_tol=1e-9)
    assert math.isclose(burn["p0"], 5.5 / (4.5 + 5.5), rel_tol=1e-9)
    assert res["evaluation"]["n"] == 900


def test_evaluation_is_trades_101_to_1000_only():
    base = evaluate(make_rows())
    padded = evaluate(make_rows(extra=50))
    assert padded["evaluation"]["n"] == 900
    # the 50 extra trades (all appended after trade 1000) must not enter the statistics
    rows = make_rows()
    extra = [row(2000 + k, -2.0, window=9000 + k, fill_ms=T0_MS + (2000 + k) * SPACING_MS) for k in range(50)]
    again = evaluate(rows + extra)
    assert again["evaluation"]["wins_count"] == base["evaluation"]["wins_count"]
    assert math.isclose(again["evaluation"]["mean_cluster_net_pips"], base["evaluation"]["mean_cluster_net_pips"])
    # burn-in trades are not evaluated: dropping them from the sample changes n
    assert base["evaluation"]["wins_count"] == sum(1 for x in nets(900, 0.68) if x > 0)


def test_p0_formula_and_zero_net_counts_as_loser():
    rows = make_rows(burn_vals=([4.0], [-6.0]), burn_rate=0.6)
    for k in range(5):  # five break-even trades in the burn-in count as losers (net <= 0)
        rows[k]["net_pips"] = "0.0"
    burn = [float(r["net_pips"]) for r in rows[:100]]
    winners = [x for x in burn if x > 0]
    losers = [x for x in burn if x <= 0]
    w, l = sum(winners) / len(winners), abs(sum(losers) / len(losers))
    res = evaluate(rows)
    assert math.isclose(res["burn_in"]["p0"], l / (w + l), rel_tol=1e-12)
    assert math.isclose(res["burn_in"]["w_bar"], w, rel_tol=1e-12)
    assert math.isclose(res["burn_in"]["abs_l_bar"], l, rel_tol=1e-12)


def test_burn_in_c_bar_and_s_burn():
    rows = make_rows()
    for i in range(100):
        rows[i]["commission_pips"] = str(0.1 + 0.001 * i)
    res = evaluate(rows)
    comm = [0.1 + 0.001 * i for i in range(100)]
    assert math.isclose(res["burn_in"]["c_bar_info"], sum(2 * c for c in comm) / 100, rel_tol=1e-9)
    burn = [float(r["net_pips"]) for r in rows[:100]]
    mean = sum(burn) / 100
    sd = math.sqrt(sum((x - mean) ** 2 for x in burn) / 99)  # sample (n-1) std
    assert math.isclose(res["burn_in"]["s_burn"], sd, rel_tol=1e-9)


@pytest.mark.parametrize("burn_rate,desc", [(1.0, "no losers"), (0.0, "no winners")])
def test_burn_in_without_winner_or_loser_is_invalid_not_fallback(burn_rate, desc):
    res = evaluate(make_rows(burn_rate=burn_rate))
    assert res["verdict"] == "INVALID"
    assert "p0 undefined" in res["reason"]
    assert "evaluation" not in res


# --------------------------------------------------------------------------------------
# Row selection: evidential flag, run id
# --------------------------------------------------------------------------------------

def test_plumbing_rows_excluded():
    rows = make_rows()
    plumbing = [row(3000 + k, 50.0, evidential="0", window=1000 + k, fill_ms=T0_MS - 10 ** 7 + k) for k in range(50)]
    res = evaluate(plumbing + rows)
    assert res["total_rows"] == 1050 and res["plumbing_rows"] == 50 and res["evidential_rows"] == 1000
    assert res["verdict"] == "HIT"


def test_missing_or_blank_evidential_is_fail_closed():
    rows = make_rows()
    del rows[0]["evidential"]
    rows[1]["evidential"] = ""
    res = evaluate(rows)
    assert res["evidential_rows"] == 998
    assert res["verdict"] == "NOT_YET_EVALUABLE"


def test_run_id_filter_ignores_other_runs():
    rows = make_rows()
    foreign = [row(4000 + k, -30.0, run="RUN-OLD", window=2000 + k, fill_ms=T0_MS + k) for k in range(300)]
    res = evaluate(foreign + rows + foreign)
    assert res["verdict"] == "HIT"
    assert res["run_rows"] == 1000 and res["total_rows"] == 1600


def test_unknown_run_id_is_invalid():
    res = evaluate(make_rows(), run_id="RUN-MISSING")
    assert res["verdict"] == "INVALID"
    assert "RUN-MISSING" in res["reason"]


def test_restart_rows_with_real_exit_are_kept_and_reconciled_rows_are_invalid():
    rows = make_rows()
    rows[500]["restart"] = "1"  # restart row with real TAKE_PROFIT exit data: kept
    assert evaluate(rows)["verdict"] == "HIT"
    rows[501]["restart"] = "1"
    rows[501]["exit_reason"] = "RESTART_RECONCILED"  # fabricated exit marked evidential: INVALID
    assert evaluate(rows)["verdict"] == "INVALID"


# --------------------------------------------------------------------------------------
# Integrity: hash, gates, exit reasons
# --------------------------------------------------------------------------------------

def test_account_hash_mismatch_is_invalid():
    rows = make_rows()
    assert evaluate(rows, sha=SHA.upper())["verdict"] == "HIT"  # hex case is irrelevant
    rows[700]["account_md_sha256"] = "cd" * 32
    res = evaluate(rows)
    assert res["verdict"] == "INVALID" and "account_md_sha256" in res["reason"]
    assert evaluate(make_rows(), sha="cd" * 32)["verdict"] == "INVALID"


def test_gate_mismatch_is_invalid():
    rows = make_rows()
    assert evaluate(rows, gate_eur=0.2)["verdict"] == "INVALID"
    assert evaluate(rows, gate_jpy=0.3)["verdict"] == "INVALID"
    res = evaluate(rows)
    assert res["verdict"] == "HIT"


@pytest.mark.parametrize("reason", ["KILL_SWITCH", "DAILY_STOP", "EXTERNAL", "RESTART_RECONCILED", ""])
def test_non_registered_exit_reason_on_evidential_row_is_invalid(reason):
    rows = make_rows()
    rows[300]["exit_reason"] = reason
    res = evaluate(rows)
    assert res["verdict"] == "INVALID" and "exit_reason" in res["reason"]
    rows[300]["evidential"] = "0"  # the same row flagged non-evidential is simply excluded
    if reason == "EXTERNAL":  # ... except an EXTERNAL close, which invalidates the run whatever its flag (D-4)
        assert evaluate(rows)["verdict"] == "INVALID"
    else:
        assert evaluate(rows)["verdict"] != "INVALID"


@pytest.mark.parametrize("reason", ["TAKE_PROFIT", "STOP_LOSS", "TIME_STOP"])
def test_registered_exit_reasons_are_accepted(reason):
    rows = make_rows()
    rows[300]["exit_reason"] = reason
    assert evaluate(rows)["verdict"] == "HIT"


# --------------------------------------------------------------------------------------
# Daily stop, hard stop, not yet evaluable
# --------------------------------------------------------------------------------------

def day_rows(day_start_ms, values, run=RUN, evidential="1", exit_reason="TAKE_PROFIT"):
    return [row(9000 + k, v, window=8000 + k, fill_ms=day_start_ms + k * 3600 * 1000,
                evidential=evidential, exit_reason=exit_reason) for k, v in enumerate(values)]


def test_daily_net_loss_stop_is_miss_even_with_small_n():
    day = T0_MS - 8 * 3600 * 1000  # 2026-10-20 00:00 UTC
    breach = evaluate(day_rows(day, [-10.0, -10.0, -10.0]), now=day + 1000)  # exactly -30.0
    assert breach["verdict"] == "MISS" and "2026-10-20" in breach["reason"]
    near = evaluate(day_rows(day, [-10.0, -10.0, -9.99]), now=day + 1000)
    assert near["verdict"] == "NOT_YET_EVALUABLE"


def test_daily_stop_counts_operational_rows_and_uses_exit_day():
    day = T0_MS - 8 * 3600 * 1000
    rows = day_rows(day, [-15.0, -15.0], evidential="0", exit_reason="DAILY_STOP")
    assert evaluate(rows, now=day + 1000)["verdict"] == "MISS"
    # same net spread over two UTC days: no breach
    r2 = day_rows(day, [-15.0]) + day_rows(day + 86400 * 1000, [-15.0])
    assert evaluate(r2, now=day + 1000)["verdict"] == "NOT_YET_EVALUABLE"


def test_daily_stop_in_otherwise_hit_dataset_is_miss():
    rows = make_rows()
    rows += day_rows(T0_MS - 86400 * 1000 * 3, [-12.0, -12.0, -12.0])
    res = evaluate(rows)
    assert res["verdict"] == "MISS" and "daily net loss stop" in res["reason"]


def test_not_yet_evaluable_before_hard_stop_and_miss_after_it():
    rows = make_rows(n_eval=849)  # 949 evidential trades
    before = evaluate(rows, hard_stop=NOW_MS + 1, now=NOW_MS)
    after = evaluate(rows, hard_stop=NOW_MS - 1, now=NOW_MS)
    assert before["verdict"] == "NOT_YET_EVALUABLE" and "evaluation" not in before
    assert after["verdict"] == "MISS" and "evaluation" not in after
    # the boundary: still evaluable on the hard stop itself
    assert evaluate(rows, hard_stop=NOW_MS, now=NOW_MS)["verdict"] == "NOT_YET_EVALUABLE"


def test_999_and_1000_evidential_trades_boundary():
    assert evaluate(make_rows(n_eval=899), hard_stop=NOW_MS + 1)["verdict"] == "NOT_YET_EVALUABLE"
    assert evaluate(make_rows(n_eval=900), hard_stop=NOW_MS + 1)["verdict"] == "HIT"


def test_min_required_is_burn_in_plus_target():
    res = evaluate(make_rows(n_eval=500), hard_stop=NOW_MS + 1)
    assert res["required_rows"] == 1000 and res["verdict"] == "NOT_YET_EVALUABLE"


def test_hard_stop_date_is_inclusive_end_of_day():
    assert analyze.parse_hard_stop_utc("2026-12-01") == 1796169599999  # 2026-12-01 23:59:59.999 UTC
    assert analyze.parse_hard_stop_utc("2026-12-01 12:00:00") == 1796126400000
    with pytest.raises(ValueError):
        analyze.parse_hard_stop_utc("12/01/2026")


# --------------------------------------------------------------------------------------
# Spread fidelity
# --------------------------------------------------------------------------------------

def test_spread_fidelity_boundary_is_inclusive():
    ok = evaluate(make_rows(spread_eur=1.2, spread_jpy=1.2), s_eur=1.0, s_jpy=1.0)
    assert ok["evaluation"]["spread_fidelity_pass"] is True
    over = evaluate(make_rows(spread_eur=1.2001, spread_jpy=1.2), s_eur=1.0, s_jpy=1.0)
    assert over["evaluation"]["eur_spread_pass"] is False and over["evaluation"]["jpy_spread_pass"] is True
    assert over["verdict"] == "MISS"


def test_spread_fidelity_is_evaluated_per_symbol_against_its_own_pretest():
    res = evaluate(make_rows(spread_eur=0.30, spread_jpy=0.42), s_eur=0.25, s_jpy=0.35)  # both exactly 1.20x
    assert res["evaluation"]["spread_fidelity_pass"] is True
    res = evaluate(make_rows(spread_eur=0.22, spread_jpy=0.43), s_eur=0.25, s_jpy=0.35)
    assert res["evaluation"]["eur_spread_pass"] and not res["evaluation"]["jpy_spread_pass"]


def test_symbol_without_fills_is_not_met_not_vacuous_pass():
    rows = make_rows()
    for r in rows:
        r["symbol"] = "EURUSD"
        r["symbol_gate"] = f"{GATE_EUR:.3f}"
    res = evaluate(rows)
    assert res["evaluation"]["jpy_n"] == 0
    assert res["evaluation"]["jpy_spread_pass"] is False
    assert res["verdict"] == "MISS"


def test_spread_uses_evaluation_trades_only():
    rows = make_rows()
    for r in rows[:100]:
        r["spread_at_fill"] = "9.0"  # burn-in spreads are irrelevant
    assert evaluate(rows)["verdict"] == "HIT"


# --------------------------------------------------------------------------------------
# Co-primary statistics: clustering, sidedness, alpha
# --------------------------------------------------------------------------------------

def reference_cluster_test(eval_rows):
    by_win = {}
    for r in eval_rows:
        by_win.setdefault(r["window_id"], []).append(float(r["net_pips"]))
    means = [sum(v) / len(v) for v in by_win.values()]
    t = scipy.stats.ttest_1samp(means, 0.0, alternative="greater")
    return len(means), sum(means) / len(means), float(t.statistic), float(t.pvalue)


def test_clustering_by_window_id_with_multiple_trades_per_window():
    rows = make_rows(per_window=2, eval_rate=0.68)
    res = evaluate(rows)
    m, mean, t, p = reference_cluster_test(rows[100:1000])
    ev = res["evaluation"]
    assert m == 450 and ev["m_clusters"] == 450  # clusters = window_id, not tickets
    assert math.isclose(ev["mean_cluster_net_pips"], mean, rel_tol=1e-9)
    assert math.isclose(ev["t_stat"], t, rel_tol=1e-9)
    assert math.isclose(ev["p_val_t"], p, rel_tol=1e-9, abs_tol=1e-15)


def test_clustered_t_differs_from_trade_level_t_when_windows_hold_unequal_trades():
    rows = make_rows(per_window=3)
    rng = random.Random(7)
    for j, r in enumerate(rows[100:1000]):
        r["net_pips"] = str(round(rng.uniform(-6, 7) + (0.8 if (j // 3) % 2 == 0 else -0.2), 3))
    res = evaluate(rows)
    m, mean, t, p = reference_cluster_test(rows[100:1000])
    assert res["evaluation"]["m_clusters"] == m == 300
    assert math.isclose(res["evaluation"]["t_stat"], t, rel_tol=1e-9)
    assert math.isclose(res["evaluation"]["p_val_t"], p, rel_tol=1e-9, abs_tol=1e-15)


def two_point_rows(mu, d=5.0, n=900):
    """Evaluation trades with net = mu +/- d (each half): known mean, unique windows."""
    rows = make_rows()
    for j, r in enumerate(rows[100:100 + n]):
        r["net_pips"] = str(mu + (d if j % 2 == 0 else -d))
    return rows


def test_t_test_is_one_sided_p_between_alpha_and_twice_alpha_passes():
    res = evaluate(two_point_rows(0.34))
    ev = res["evaluation"]
    assert 0.0125 < ev["p_val_t"] < 0.025  # one-sided p passes, two-sided p (2x) would not
    assert ev["t_pass"] is True


def test_t_test_alpha_is_0025_not_005():
    res = evaluate(two_point_rows(0.29))
    ev = res["evaluation"]
    assert 0.025 < ev["p_val_t"] < 0.05
    assert ev["t_pass"] is False
    assert res["verdict"] == "MISS"


def test_t_test_negative_mean_does_not_pass_and_p_is_not_two_sided():
    res = evaluate(two_point_rows(-0.9))
    ev = res["evaluation"]
    assert ev["mean_cluster_net_pips"] < 0
    assert ev["p_val_t"] > 0.5  # one-sided p for a negative t; a two-sided p would be tiny
    assert ev["t_pass"] is False


def test_binomial_is_one_sided_greater_exact():
    rows = make_rows(eval_rate=0.68)
    res = evaluate(rows)
    ev, p0 = res["evaluation"], res["burn_in"]["p0"]
    assert math.isclose(ev["p_val_binom"], scipy.stats.binomtest(ev["wins_count"], 900, p0, alternative="greater").pvalue)
    low = evaluate(make_rows(eval_rate=0.30))
    assert low["evaluation"]["p_val_binom"] > 0.99 and low["evaluation"]["binom_pass"] is False


def test_binomial_alpha_is_0025_not_005():
    rows = make_rows()
    p0 = evaluate(rows)["burn_in"]["p0"]
    k = find_wins_for_binom_p(900, p0, 0.03, 0.045)  # between 0.025 and 0.05
    eval_rate = (k + 0.5) / 900
    res = evaluate(make_rows(eval_rate=eval_rate))
    assert res["evaluation"]["wins_count"] == k
    assert 0.025 < res["evaluation"]["p_val_binom"] < 0.05
    assert res["evaluation"]["binom_pass"] is False
    k2 = find_wins_for_binom_p(900, p0, 0.015, 0.024)
    res2 = evaluate(make_rows(eval_rate=(k2 + 0.5) / 900))
    assert res2["evaluation"]["binom_pass"] is True


# --------------------------------------------------------------------------------------
# Registered constants and CLI
# --------------------------------------------------------------------------------------

def test_registered_constants_and_versions():
    assert analyze.ALPHA == 0.025
    assert analyze.BURN_IN_N == 100 and analyze.TARGET_N == 900
    assert analyze.DAILY_LOSS_STOP == -30.0
    assert analyze.VERSION == "1.05"
    root = Path(__file__).parent
    for name in ("ScalperEA.mq5", "SpreadLog.mq5"):
        text = (root / name).read_text(encoding="utf-8")
        assert "v1.05" in text and "v1.02" not in text
    assert "v1.02" not in Path(analyze.__file__).read_text(encoding="utf-8")
    assert "PREREG v1.05" in (__doc__ or "")


def test_cli_has_no_alpha_or_sample_size_options():
    parser = analyze.build_parser()
    opts = {o for a in parser._actions for o in a.option_strings}
    assert not ({"--alpha", "--burn-in-n", "--target-n"} & opts)
    for required in ("--run-id", "--hard-stop-utc", "--s-pretest-eurusd", "--s-pretest-usdjpy",
                     "--gate-eurusd", "--gate-usdjpy", "--account-md-sha256", "--csv"):
        action = next(a for a in parser._actions if required in a.option_strings)
        assert action.required is True, required
    with pytest.raises(SystemExit) as exc:
        analyze.main(["--csv", "x.csv", "--alpha", "0.05"])
    assert exc.value.code == 2


CSV_FIELDS = ["ticket", "evidential", "run_id", "account_md_sha256", "window_id", "symbol", "symbol_gate",
              "side", "fill_time_msc", "hold_ms", "spread_at_fill", "net_pips", "commission_pips",
              "exit_reason", "restart"]


def write_csv(path, rows, encoding):
    lines = [",".join(CSV_FIELDS)] + [",".join(r[k] for k in CSV_FIELDS) for r in rows]
    path.write_bytes(("\r\n".join(lines) + "\r\n").encode(encoding))


@pytest.mark.parametrize("encoding", ["utf-8", "utf-8-sig", "utf-16", "cp1252"])
def test_roundtrips_readable_in_utf8_bom_utf16_and_ansi(tmp_path, encoding):
    rows = make_rows(n_burn=3, n_eval=2)
    p = tmp_path / "scalper_roundtrips.csv"
    write_csv(p, rows, encoding)
    loaded = analyze.load_roundtrips(str(p))
    assert len(loaded) == 5
    assert loaded[0]["run_id"] == RUN and loaded[0]["account_md_sha256"] == SHA
    assert loaded[4]["net_pips"] == rows[4]["net_pips"]


def test_cli_end_to_end_exit_codes(tmp_path, capsys):
    p = tmp_path / "rt.csv"
    write_csv(p, make_rows(), "utf-16")
    base = ["--csv", str(p), "--run-id", RUN, "--account-md-sha256", SHA, "--gate-eurusd", "0.30",
            "--gate-usdjpy", "0.25", "--s-pretest-eurusd", "0.25", "--s-pretest-usdjpy", "0.35"]
    with pytest.raises(SystemExit) as hit:
        analyze.main(base + ["--hard-stop-utc", "2100-01-01"])
    assert hit.value.code == 0 and "HIT" in capsys.readouterr().out
    with pytest.raises(SystemExit) as miss:
        analyze.main(base + ["--hard-stop-utc", "2026-10-21"])  # 900th trade is long after
    assert miss.value.code == 1
    with pytest.raises(SystemExit) as inv:
        analyze.main(["--csv", str(p), "--run-id", "nope", "--account-md-sha256", SHA, "--gate-eurusd", "0.30",
                      "--gate-usdjpy", "0.25", "--s-pretest-eurusd", "0.25", "--s-pretest-usdjpy", "0.35",
                      "--hard-stop-utc", "2100-01-01"])
    assert inv.value.code == 2


# --------------------------------------------------------------------------------------
# D-4: EXTERNAL close / incident file -> operational INVALID
# --------------------------------------------------------------------------------------

INCIDENT_FIELDS = ["utc_time", "run_id", "event", "position_ticket", "entry_deal_ticket", "exit_deal_ticket",
                   "deal_reason", "deal_comment", "details"]


def incident(run=RUN, event="EXTERNAL_CLOSE"):
    return dict(zip(INCIDENT_FIELDS, ["2026-10-21 09:00:00", run, event, "111", "222", "333", "0", "manual", "x"]))


def test_external_row_makes_run_invalid_whatever_its_evidential_flag():
    for evid in ("1", "0"):
        rows = make_rows()
        rows[300]["exit_reason"] = "EXTERNAL"
        rows[300]["evidential"] = evid
        res = evaluate(rows)
        assert res["verdict"] == "INVALID", evid
        assert "EXTERNAL" in res["reason"], evid
    assert evaluate(make_rows())["verdict"] == "HIT"


def test_external_row_of_another_run_is_ignored():
    rows = make_rows()
    foreign = row(4000, -3.0, run="RUN-OLD", evidential="0", exit_reason="EXTERNAL", window=2000, fill_ms=T0_MS)
    assert evaluate(rows + [foreign])["verdict"] == "HIT"


def test_external_invalid_outranks_daily_stop_miss():
    day = T0_MS - 8 * 3600 * 1000
    rows = day_rows(day, [-20.0, -20.0], evidential="0", exit_reason="EXTERNAL")
    res = evaluate(rows, now=day + 1000)
    assert res["verdict"] == "INVALID" and "EXTERNAL" in res["reason"]


def test_incident_file_row_makes_run_invalid():
    rows = make_rows()
    assert evaluate(rows, incidents=None)["verdict"] == "HIT"
    assert evaluate(rows, incidents=[])["verdict"] == "HIT"
    res = evaluate(rows, incidents=[incident()])
    assert res["verdict"] == "INVALID"
    assert "incident" in res["reason"] and "EXTERNAL_CLOSE" in res["reason"]
    assert evaluate(rows, incidents=[incident(event="ANYTHING_ELSE")])["verdict"] == "INVALID"


def test_incident_rows_of_another_run_are_ignored_but_blank_run_id_is_not():
    rows = make_rows()
    assert evaluate(rows, incidents=[incident(run="RUN-OLD")])["verdict"] == "HIT"
    assert evaluate(rows, incidents=[incident(run="RUN-OLD"), incident(run="")])["verdict"] == "INVALID"


def test_incident_csv_text_parses_with_the_ea_header_and_invalidates():
    text = "\r\n".join([",".join(INCIDENT_FIELDS),
                        '2026-10-21 09:00:00,RUN-A,EXTERNAL_CLOSE,111,222,333,0,"manual, close","a ""b"" c"']) + "\r\n"
    parsed = analyze.parse_csv_rows(text)
    assert len(parsed) == 1 and parsed[0]["run_id"] == RUN and parsed[0]["deal_comment"] == "manual, close"
    assert parsed[0]["details"] == 'a "b" c'
    assert evaluate(make_rows(), incidents=parsed)["verdict"] == "INVALID"


def test_cli_has_optional_incidents_option():
    parser = analyze.build_parser()
    action = next((a for a in parser._actions if "--incidents" in a.option_strings), None)
    assert action is not None, "--incidents option missing"
    assert action.required is False and action.default is None


def test_cli_incidents_file_makes_verdict_invalid_and_missing_file_is_an_error(tmp_path):
    p = tmp_path / "rt.csv"
    write_csv(p, make_rows(), "utf-8")
    inc = tmp_path / "scalper_incidents.csv"
    inc.write_bytes((",".join(INCIDENT_FIELDS) + "\r\n" +
                     ",".join(incident()[k] for k in INCIDENT_FIELDS) + "\r\n").encode("cp1252"))
    base = ["--csv", str(p), "--run-id", RUN, "--account-md-sha256", SHA, "--gate-eurusd", "0.30",
            "--gate-usdjpy", "0.25", "--s-pretest-eurusd", "0.25", "--s-pretest-usdjpy", "0.35",
            "--hard-stop-utc", "2100-01-01"]
    with pytest.raises(SystemExit) as clean:
        analyze.main(base)
    assert clean.value.code == 0
    with pytest.raises(SystemExit) as inv:
        analyze.main(base + ["--incidents", str(inc)])
    assert inv.value.code == 2
    with pytest.raises(SystemExit) as missing:
        analyze.main(base + ["--incidents", str(tmp_path / "nope.csv")])
    assert missing.value.code == 3


# --------------------------------------------------------------------------------------
# D-3: the hard stop is an explicit input, never derived from rows, never reset by a restart
# --------------------------------------------------------------------------------------

def test_hard_stop_is_not_derived_from_the_first_row():
    rows = make_rows()
    last_fill = int(rows[999]["fill_time_msc"])
    assert last_fill > T0_MS + 56 * 86400 * 1000  # first row + 8 weeks would already be over
    on_time = evaluate(rows, hard_stop=last_fill)
    late = evaluate(rows, hard_stop=last_fill - 1)
    assert on_time["verdict"] == "HIT" and on_time["evaluation"]["hard_stop_utc_ms"] == last_fill
    assert late["verdict"] == "MISS" and late["evaluation"]["hard_stop_utc_ms"] == last_fill - 1


def test_hard_stop_is_not_reset_by_an_operational_restart():
    rows = make_rows()
    last_fill = int(rows[999]["fill_time_msc"])
    rows[500]["restart"] = "1"  # a restart long before the end: a reset would give hard stop = that fill + 8 weeks
    assert evaluate(rows, hard_stop=last_fill)["verdict"] == "HIT"
    rows[998]["restart"] = "1"  # a restart right before the end: a reset would push the hard stop past it
    late = evaluate(rows, hard_stop=last_fill - 1)
    assert late["verdict"] == "MISS" and late["evaluation"]["n_reached_pass"] is False
    assert evaluate(rows, hard_stop=last_fill)["verdict"] == "HIT"


def test_not_yet_evaluable_timeline_ignores_restart_rows():
    rows = make_rows(n_eval=849)
    rows[10]["restart"] = "1"
    rows[948]["restart"] = "1"
    assert evaluate(rows, hard_stop=NOW_MS + 1, now=NOW_MS)["verdict"] == "NOT_YET_EVALUABLE"
    assert evaluate(rows, hard_stop=NOW_MS - 1, now=NOW_MS)["verdict"] == "MISS"


AN_SRC = Path(analyze.__file__).read_text(encoding="utf-8")


def py_function_source(src, name):
    node = next(n for n in ast.walk(ast.parse(src)) if isinstance(n, ast.FunctionDef) and n.name == name)
    return ast.get_source_segment(src, node)


def test_analyze_never_reads_the_restart_column_or_derives_a_hard_stop():
    src = py_function_source(AN_SRC, "evaluate_scalper") + py_function_source(AN_SRC, "finish_evaluation")
    assert "restart" not in src
    assert "weeks" not in src and "86400000 *" not in src
    assert "hard_stop_utc_ms: int," in py_function_source(AN_SRC, "evaluate_scalper")


# --------------------------------------------------------------------------------------
# ScalperEA.mq5 static source tests (D-1 floating mark side, D-4 incident log + halt, registered constants)
# --------------------------------------------------------------------------------------
EA_SRC = Path(__file__).with_name("ScalperEA.mq5").read_text(encoding="utf-8")
README_SRC = Path(__file__).with_name("README.md").read_text(encoding="utf-8")


def mq5_body(src, name):
    """Text of the first function definition called `name`, braces matched, whitespace collapsed."""
    m = re.search(r"^[ \t]*(?:bool|void|string|double|ulong|int)[ \t]+" + re.escape(name) + r"[ \t]*\(", src, re.M)
    assert m, f"function {name} not found"
    start = src.index("{", m.end())
    depth, i = 0, start
    while True:
        depth += {"{": 1, "}": -1}.get(src[i], 0)
        if depth == 0:
            break
        i += 1
    return re.sub(r"\s+", " ", src[start + 1:i]).strip()


def test_ea_registered_constants_unchanged():
    for decl in ("const double MAX_VOLUME       = 0.01;", "const int    TIME_STOP_SEC    = 300;",
                 "const double TARGET_BRACKET   = 5.0;", "const int    MAX_CONSEC_ERRS  = 5;",
                 "const double DAILY_LOSS_STOP  = -30.0;", "const int    MAX_TRADES_DAY   = 20;",
                 "const double TICK_MAX_AGE_MS  = 3000.0;", "const double GATE_CAP         = 0.3;"):
        assert decl in EA_SRC, decl
    assert "IsInSession" in EA_SRC and "secOfDay >= 7 * 3600 && secOfDay < 16 * 3600" in EA_SRC


def test_d1_floating_loss_is_marked_to_the_adverse_side():
    body = mq5_body(EA_SRC, "FloatingNetPips")
    assert ('(g_pos.side == "BUY") ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK)'
            in body), "long must be marked at BID, short at ASK"
    assert ('double gross = (g_pos.side == "BUY") ? (mark - g_pos.fillPrice) / pip : (g_pos.fillPrice - mark) / pip;'
            in body)
    for forbidden in ("SymbolInfoTick", "SYMBOL_LAST", "/ 2.0", "* 0.5"):  # no mid / last / other mark
        assert forbidden not in body, forbidden


def test_d1_floating_includes_entry_and_expected_exit_commission():
    body = mq5_body(EA_SRC, "FloatingNetPips")
    assert "double entryCommPips = g_pos.commEntryPips;" in body
    assert "double exitCommPips = g_pos.commEntryPips;" in body  # expected exit = entry per-side commission
    assert "floatingPips = gross - entryCommPips - exitCommPips;" in body


def test_d1_daily_stop_counts_realised_plus_adverse_floating_at_minus_30():
    body = mq5_body(EA_SRC, "MonitorOpenPosition")
    assert "FloatingNetPips(floating) && g_dailyNetPips + floating <= DAILY_LOSS_STOP" in body
    assert "SetIntent(INTENT_DAILY)" in body
    assert "const double DAILY_LOSS_STOP  = -30.0;" in EA_SRC


def test_d4_only_own_tp_sl_or_matching_intent_is_a_registered_exit():
    cls = mq5_body(EA_SRC, "ClassifyExit")
    assert 'if(x.dealReason == DEAL_REASON_TP) return "TAKE_PROFIT";' in cls
    assert 'if(x.dealReason == DEAL_REASON_SL) return "STOP_LOSS";' in cls
    assert "if(x.dealReason == DEAL_REASON_EXPERT) {" in cls
    assert cls.endswith('return "EXTERNAL";'), "every other DEAL_REASON must classify as EXTERNAL"
    assert mq5_body(EA_SRC, "IsRegisteredExit") == 'return (reason == "TAKE_PROFIT" || reason == "STOP_LOSS" || reason == "TIME_STOP");'
    fin = mq5_body(EA_SRC, "FinalizeClose")
    assert "bool evid = g_isEvidential && g_pos.evidential && commKnown && IsRegisteredExit(reason);" in fin


def test_d4_external_close_writes_incident_row_before_position_state_is_cleared():
    fin = mq5_body(EA_SRC, "FinalizeClose")
    call = 'if(reason == "EXTERNAL") RecordExternalClose(x);'
    assert call in fin and fin.index(call) < fin.index("ClearPositionAfterClose();")
    rec = mq5_body(EA_SRC, "RecordExternalClose")
    assert ('LogIncident("EXTERNAL_CLOSE", g_pos.ticket, entryDeal, x.dealTicket, x.dealReason, x.dealComment, details);'
            in rec)
    assert "FindEntryDealTicket(g_pos.ticket)" in rec


def test_d4_incident_file_contract_is_ansi_append_only_with_registered_fields():
    assert 'const string FILE_INCIDENTS   = "scalper_incidents.csv";' in EA_SRC
    m = re.search(r'#define HDR_INCIDENTS\s+"([^"]*)"', EA_SRC)
    assert m and m.group(1).split(",") == INCIDENT_FIELDS
    log = mq5_body(EA_SRC, "LogIncident")
    assert '"%s,%s,%s,%I64u,%I64u,%I64u,%d,%s,%s"' in log
    assert "AppendCsvLine(FILE_INCIDENTS, HDR_INCIDENTS, line);" in log
    app = mq5_body(EA_SRC, "AppendCsvLine")
    for flag in ("FILE_ANSI", "FILE_COMMON", "FILE_WRITE"):
        assert flag in app, flag
    assert "FileSeek(handle, 0, SEEK_END)" in app
    for forbidden in ("FILE_REWRITE", "FileDelete"):
        assert forbidden not in EA_SRC, forbidden


def test_d4_external_close_halts_operational_invalid_and_never_auto_clears():
    res = mq5_body(EA_SRC, "ResolveStateAfterClose")
    first = res.index('if(reason == "EXTERNAL")')
    assert first == res.index("if(") and first < res.index("INTENT_KILL"), "EXTERNAL must be checked first"
    assert 'HaltWith(HALT_OPERATIONAL, "operational INVALID: external close' in res
    halt = mq5_body(EA_SRC, "HaltWith")
    assert "g_state = STATE_HALTED;" in halt and "[HALTED]" in halt
    reset = mq5_body(EA_SRC, "CheckDailyReset")
    assert "g_state == STATE_HALTED && g_haltReason == HALT_DAILY" in reset


def test_d2_readme_says_hash_is_in_tag_message_and_status_never_in_account_md():
    flat = re.sub(r"\s+", " ", README_SRC)
    assert "tag message" in flat and "STATUS.md" in flat
    assert "never inside `ACCOUNT.md`" in flat
    assert "blob" in flat and "freeze commit" in flat


# --------------------------------------------------------------------------------------
# summary.py
# --------------------------------------------------------------------------------------

def spread_row(ts, symbol="EURUSD", spread="0.20", age="100.0", ticks="30"):
    return {"time_utc": ts, "symbol": symbol, "spread_pips": str(spread), "zero_spread": "0",
            "tick_age_ms": age, "ticks_in_prev_60s": ticks}


def test_summary_zero_spread_exclusion():
    rows = [spread_row(f"2026-10-19 08:00:{i:02d}", spread="0.0") for i in range(20)]
    rows += [spread_row(f"2026-10-19 09:{i // 60:02d}:{i % 60:02d}") for i in range(80)]
    results, total_rows, in_session = process_spread_rows(rows)
    eur = results["EURUSD"]
    assert (total_rows, in_session) == (100, 100)
    assert eur["total_samples"] == 100 and eur["zero_count"] == 20 and eur["n"] == 80
    assert math.isclose(eur["zero_share"], 0.20)
    assert math.isclose(eur["p60"], 0.20) and math.isclose(eur["mean"], 0.20) and math.isclose(eur["gate"], 0.20)


def test_summary_p60_mean_and_gate_cap_with_nonconstant_spreads():
    values = [0.10, 0.20, 0.30, 0.40, 0.50, 0.60, 0.70, 0.80, 0.90, 1.00]
    rows = [spread_row(f"2026-10-19 08:{i:02d}:00", spread=v) for i, v in enumerate(values)]
    eur = process_spread_rows(rows)[0]["EURUSD"]
    assert math.isclose(eur["p60"], 0.64)  # numpy linear interpolation, not 50th (0.55) or 90th (0.91)
    assert math.isclose(eur["mean"], 0.55)
    assert math.isclose(eur["gate"], 0.30)  # min(0.30, p60 = 0.64): the cap binds


def test_summary_gate_equals_p60_when_below_cap():
    values = [0.05, 0.10, 0.15, 0.20, 0.25, 0.28, 0.30, 0.35, 0.40, 0.45]
    rows = [spread_row(f"2026-10-19 08:{i:02d}:00", spread=v) for i, v in enumerate(values)]
    eur = process_spread_rows(rows)[0]["EURUSD"]
    assert math.isclose(eur["p60"], 0.288, abs_tol=1e-9)
    assert math.isclose(eur["gate"], eur["p60"])
    assert eur["gate"] < 0.30


def test_summary_mean_is_not_median_for_spread():
    rows = [spread_row(f"2026-10-19 08:0{i}:00", spread=v) for i, v in enumerate([0.1, 0.1, 0.1, 0.1, 1.1])]
    eur = process_spread_rows(rows)[0]["EURUSD"]
    assert math.isclose(eur["mean"], 0.3)  # median would be 0.1


def test_summary_session_filter_boundaries():
    inside = ["2026-10-19 07:00:00", "2026-10-19 15:59:59"]  # Monday
    outside = ["2026-10-19 06:59:59", "2026-10-19 16:00:00", "2026-10-17 10:00:00", "2026-10-18 10:00:00"]
    rows = [spread_row(t, spread="0.20") for t in inside] + [spread_row(t, spread="5.00", age="9000", ticks="999") for t in outside]
    results, total, in_session = process_spread_rows(rows)
    eur = results["EURUSD"]
    assert total == 6 and in_session == 2
    assert eur["n"] == 2 and math.isclose(eur["mean"], 0.20) and math.isclose(eur["p60"], 0.20)
    assert eur["share_lte_3000"] == 1.0 and eur["median_ticks_per_min"] == 30.0
    assert eur["trading_days"] == 1


def test_summary_tick_age_shares_and_median_ticks_not_mean():
    rows = []
    for k, (age, cnt) in enumerate([(400, 10)] * 10 + [(800, 10)] * 10 + [(2000, 10)] * 10 + [(4000, 100)] * 10):
        rows.append(spread_row(f"2026-10-19 10:{k // 60:02d}:{k % 60:02d}", "USDJPY", "0.15", str(age), str(cnt)))
    jpy = process_spread_rows(rows)[0]["USDJPY"]
    assert jpy["total_samples"] == 40
    assert math.isclose(jpy["share_lte_500"], 10 / 40)
    assert math.isclose(jpy["share_lte_1000"], 20 / 40)
    assert math.isclose(jpy["share_lte_3000"], 30 / 40)
    assert jpy["median_ticks_per_min"] == 10.0  # mean would be 32.5


def test_summary_reads_registered_field_name_ticks_in_prev_60s():
    old = spread_row("2026-10-19 10:00:00", "USDJPY")
    del old["ticks_in_prev_60s"]
    old["ticks_prev_60s"] = "77"
    assert process_spread_rows([old])[0]["USDJPY"]["median_ticks_per_min"] == 0.0
    assert process_spread_rows([spread_row("2026-10-19 10:00:00", "USDJPY", ticks="77")])[0]["USDJPY"]["median_ticks_per_min"] == 77.0


def five_day_rows(days):
    rows = []
    for d in days:
        for s in ("EURUSD", "USDJPY"):
            rows.append(spread_row(f"2026-10-{d:02d} 09:00:00", s, "0.20"))
    return rows


def test_summary_requires_five_distinct_trading_days(capsys):
    four = process_spread_rows(five_day_rows([19, 20, 21, 22]))
    assert any("4 distinct" in r for r in summary.refusal_reasons(four[0]))
    assert summary.print_summary(*four) is False
    out = capsys.readouterr().out
    assert "REFUSED" in out and "COPY-PASTE" not in out
    five = process_spread_rows(five_day_rows([19, 20, 21, 22, 23]))
    assert summary.refusal_reasons(five[0]) == []
    assert summary.print_summary(*five) is True
    assert "COPY-PASTE" in capsys.readouterr().out


def test_summary_same_day_samples_count_once_and_one_symbol_short_refuses():
    rows = five_day_rows([19, 20, 21, 22, 23]) + [spread_row(f"2026-10-23 10:{i:02d}:00") for i in range(30)]
    assert process_spread_rows(rows)[0]["EURUSD"]["trading_days"] == 5
    only_eur = [r for r in five_day_rows([19, 20, 21, 22, 23]) if r["symbol"] == "EURUSD"]
    res = process_spread_rows(only_eur)[0]
    assert any(r.startswith("USDJPY") for r in summary.refusal_reasons(res))


def test_summary_n_zero_is_refused_without_default_gate(capsys):
    rows = [spread_row(f"2026-10-{d:02d} 09:00:00", spread="0.0") for d in (19, 20, 21, 22, 23)]
    res = process_spread_rows(rows)
    assert res[0]["EURUSD"]["n"] == 0 and res[0]["EURUSD"]["gate"] is None and res[0]["EURUSD"]["mean"] is None
    assert any("n == 0" in r for r in summary.refusal_reasons(res[0]))
    assert summary.print_summary(*res) is False
    assert "0.300" not in capsys.readouterr().out.split("REFUSED")[1]


def test_summary_reads_utf16_log(tmp_path):
    p = tmp_path / "spread_log.csv"
    lines = ["time_utc,symbol,spread_pips,zero_spread,tick_age_ms,ticks_in_prev_60s",
             "2026-10-19 09:00:00,EURUSD,0.200,0,120.0,40"]
    p.write_bytes(("\r\n".join(lines) + "\r\n").encode("utf-16"))
    results, total, in_session = summary.process_spread_log(str(p))
    assert total == 1 and results["EURUSD"]["n"] == 1 and results["EURUSD"]["median_ticks_per_min"] == 40.0


# ---------------------------------------------------------------------------
# SpreadLog.mq5 writer <-> summary.py reader contract (PREREG 3.3)
# ---------------------------------------------------------------------------
SPREADLOG_SRC = Path(__file__).with_name("SpreadLog.mq5").read_text(encoding="utf-8")


def test_spreadlog_header_matches_summary_fields():
    import re
    m = re.search(r'FileWrite\(g_fileHandle,\s*("time_utc"[^)]*)\)', SPREADLOG_SRC)
    assert m, "SpreadLog header FileWrite not found"
    header = [h.strip().strip('"') for h in m.group(1).split(",")]
    assert header == ["time_utc", "symbol", "spread_pips", "zero_spread", "tick_age_ms", "ticks_in_prev_60s"]
    rows = [dict(zip(header, ["2026-10-19 07:01:00", "EURUSD", "0.100", "0", "412.3", "38"]))]
    res, total, in_session = process_spread_rows(rows)
    assert (total, in_session) == (1, 1)
    assert res["EURUSD"]["median_ticks_per_min"] == 38.0


def test_spreadlog_writes_ansi_polls_50ms_and_has_no_trade_calls():
    import re
    opens = re.findall(r"FileOpen\(InpLogFilename,[^;]*;", SPREADLOG_SRC)
    assert opens and all("FILE_ANSI" in o for o in opens)
    assert "EventSetMillisecondTimer(InpPollIntervalMs)" in SPREADLOG_SRC
    assert "EventSetTimer(1)" not in SPREADLOG_SRC
    for forbidden in ("OrderSend", "CTrade", "Trade.mqh", "#include", "PositionClose"):
        assert forbidden not in SPREADLOG_SRC


def test_spreadlog_empty_tick_count_is_skipped_not_zero():
    header = ["time_utc", "symbol", "spread_pips", "zero_spread", "tick_age_ms", "ticks_in_prev_60s"]
    rows = [dict(zip(header, ["2026-10-19 07:01:00", "USDJPY", "0.200", "0", "100.0", ""])),
            dict(zip(header, ["2026-10-19 07:02:00", "USDJPY", "0.200", "0", "100.0", "40"]))]
    res, _, _ = process_spread_rows(rows)
    assert res["USDJPY"]["median_ticks_per_min"] == 40.0
