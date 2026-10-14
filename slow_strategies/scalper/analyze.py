#!/usr/bin/env python3
"""
analyze.py: Scalper Execution & Statistical Evaluation Harness
Implements PREREG.md v1.02 Section 4 and Section 5 statistical verification.

Protocol:
1. Filters out non-evidential rows (evidential == 0).
2. Uses the first 100 evidential trades (N_burn = 100) strictly for burn-in calibration:
   - W_bar = mean(net_pips > 0)
   - |L_bar| = |mean(net_pips <= 0)|
   - p0 = |L_bar| / (W_bar + |L_bar|)
   - c_bar_info = mean(2 * commission_pips)
   - s_burn = std(net_pips)
3. Evaluates the subsequent N = 900 trades (trades 101 to 1000):
   - Co-Primary 1: Exact one-sided binomial test on trade win rate (H1: p > p0) at alpha = 0.025.
   - Co-Primary 2: One-sided Student's t-test on per-window_id mean net pips (cluster = window_id) at alpha = 0.025.
   - Spread Fidelity: Realized average spread <= 1.20 * S_pre-test for EURUSD and USDJPY.
   - N Reached: At least 900 post-burn-in trades.
4. Outputs final verdict: HIT / MISS / INVALID-not-evaluable.
"""

import sys
import os
import argparse
import csv
import math
from collections import defaultdict
from typing import Dict, Any, List, Optional
import scipy.stats


def load_roundtrips(csv_path: str) -> List[Dict[str, Any]]:
    """Loads and parses roundtrips CSV."""
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Roundtrips CSV not found: {csv_path}")

    rows = []
    with open(csv_path, mode="r", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            cleaned = {k.strip(): v.strip() for k, v in row.items() if k is not None}
            rows.append(cleaned)
    return rows


def parse_float(val: Any, default: float = 0.0) -> float:
    try:
        return float(val)
    except (ValueError, TypeError):
        return default


def parse_int(val: Any, default: int = 0) -> int:
    try:
        return int(val)
    except (ValueError, TypeError):
        return default


def evaluate_scalper(
    rows: List[Dict[str, Any]],
    s_pretest_eurusd: float,
    s_pretest_usdjpy: float,
    alpha: float = 0.025,
    burn_in_n: int = 100,
    target_n: int = 900
) -> Dict[str, Any]:
    """
    Executes PREREG v1.02 evaluation logic over parsed roundtrip rows.
    """
    # 1. Filter out plumbing / non-evidential rows
    evidential_rows = [r for r in rows if parse_int(r.get("evidential", "1")) == 1]
    plumbing_count = len(rows) - len(evidential_rows)

    total_evidential = len(evidential_rows)
    min_required = burn_in_n + target_n

    if total_evidential < min_required:
        return {
            "verdict": "INVALID-not-evaluable",
            "reason": f"Insufficient evidential trades: observed {total_evidential}, require {min_required} ({burn_in_n} burn-in + {target_n} eval)",
            "total_rows": len(rows),
            "plumbing_rows": plumbing_count,
            "evidential_rows": total_evidential,
            "required_rows": min_required
        }

    # 2. Burn-In Calibration (Trades 1 to burn_in_n)
    burn_in_trades = evidential_rows[:burn_in_n]
    eval_trades = evidential_rows[burn_in_n:burn_in_n + target_n]

    burn_net_pips = [parse_float(r.get("net_pips", 0.0)) for r in burn_in_trades]
    burn_comm_pips = [parse_float(r.get("commission_pips", 0.0)) for r in burn_in_trades]

    winners = [x for x in burn_net_pips if x > 0.0]
    losers = [x for x in burn_net_pips if x <= 0.0]

    w_bar = (sum(winners) / len(winners)) if winners else 5.0
    l_bar = (sum(losers) / len(losers)) if losers else -5.0
    abs_l_bar = abs(l_bar)

    if (w_bar + abs_l_bar) > 0:
        p0 = abs_l_bar / (w_bar + abs_l_bar)
    else:
        p0 = 0.50

    c_bar_info = (sum(2.0 * c for c in burn_comm_pips) / len(burn_comm_pips)) if burn_comm_pips else 0.0

    # Sample standard deviation of burn-in
    burn_mean = sum(burn_net_pips) / len(burn_net_pips)
    burn_variance = sum((x - burn_mean) ** 2 for x in burn_net_pips) / (len(burn_net_pips) - 1) if len(burn_net_pips) > 1 else 25.0
    s_burn = math.sqrt(burn_variance)

    # 3. Post-Burn-In Confirmatory Evaluation (N = target_n)
    eval_net_pips = [parse_float(r.get("net_pips", 0.0)) for r in eval_trades]
    n_eval = len(eval_trades)

    # Co-Primary 1: Exact Binomial Test on Win Rate
    wins_count = sum(1 for x in eval_net_pips if x > 0.0)
    win_rate = wins_count / n_eval if n_eval > 0 else 0.0

    binom_res = scipy.stats.binomtest(k=wins_count, n=n_eval, p=p0, alternative="greater")
    p_val_binom = float(binom_res.pvalue)
    binom_pass = (p_val_binom < alpha)

    # Co-Primary 2: Clustered One-Sided t-test on per-window_id mean net pips
    window_pips = defaultdict(list)
    for r in eval_trades:
        w_id = parse_int(r.get("window_id", 0))
        net_pip = parse_float(r.get("net_pips", 0.0))
        window_pips[w_id].append(net_pip)

    window_means = [sum(pips) / len(pips) for pips in window_pips.values()]
    m_clusters = len(window_means)

    mean_cluster_net = sum(window_means) / m_clusters if m_clusters > 0 else 0.0
    if m_clusters > 1:
        cluster_var = sum((x - mean_cluster_net) ** 2 for x in window_means) / (m_clusters - 1)
        cluster_std = math.sqrt(cluster_var)
        cluster_se = cluster_std / math.sqrt(m_clusters)
        t_stat = (mean_cluster_net / cluster_se) if cluster_se > 0 else 0.0
        p_val_t = float(scipy.stats.t.sf(t_stat, df=m_clusters - 1)) if t_stat > 0 else 1.0
    else:
        cluster_std = 0.0
        cluster_se = 0.0
        t_stat = 0.0
        p_val_t = 1.0

    t_pass = (mean_cluster_net > 0.0 and p_val_t < alpha)

    # Spread Fidelity Check per symbol
    eur_spreads = [parse_float(r.get("spread_at_fill", 0.0)) for r in eval_trades if r.get("symbol") == "EURUSD"]
    jpy_spreads = [parse_float(r.get("spread_at_fill", 0.0)) for r in eval_trades if r.get("symbol") == "USDJPY"]

    eur_mean_spread = (sum(eur_spreads) / len(eur_spreads)) if eur_spreads else 0.0
    jpy_mean_spread = (sum(jpy_spreads) / len(jpy_spreads)) if jpy_spreads else 0.0

    eur_spread_threshold = 1.20 * s_pretest_eurusd
    jpy_spread_threshold = 1.20 * s_pretest_usdjpy

    eur_spread_pass = (eur_mean_spread <= eur_spread_threshold) if eur_spreads else True
    jpy_spread_pass = (jpy_mean_spread <= jpy_spread_threshold) if jpy_spreads else True
    spread_fidelity_pass = eur_spread_pass and jpy_spread_pass

    # Sample Size Check
    n_reached_pass = (n_eval >= target_n)

    # Final Decision
    is_hit = binom_pass and t_pass and spread_fidelity_pass and n_reached_pass
    verdict = "HIT" if is_hit else "MISS"

    return {
        "verdict": verdict,
        "total_rows": len(rows),
        "plumbing_rows": plumbing_count,
        "evidential_rows": total_evidential,
        "burn_in": {
            "n": burn_in_n,
            "w_bar": w_bar,
            "abs_l_bar": abs_l_bar,
            "p0": p0,
            "c_bar_info": c_bar_info,
            "s_burn": s_burn
        },
        "evaluation": {
            "n": n_eval,
            "alpha": alpha,
            "wins_count": wins_count,
            "win_rate": win_rate,
            "p_val_binom": p_val_binom,
            "binom_pass": binom_pass,
            "m_clusters": m_clusters,
            "mean_cluster_net_pips": mean_cluster_net,
            "cluster_std": cluster_std,
            "cluster_se": cluster_se,
            "t_stat": t_stat,
            "p_val_t": p_val_t,
            "t_pass": t_pass,
            "eur_n": len(eur_spreads),
            "eur_mean_spread": eur_mean_spread,
            "eur_spread_threshold": eur_spread_threshold,
            "eur_spread_pass": eur_spread_pass,
            "jpy_n": len(jpy_spreads),
            "jpy_mean_spread": jpy_mean_spread,
            "jpy_spread_threshold": jpy_spread_threshold,
            "jpy_spread_pass": jpy_spread_pass,
            "spread_fidelity_pass": spread_fidelity_pass,
            "n_reached_pass": n_reached_pass
        }
    }


def print_report(res: Dict[str, Any]) -> None:
    print("=" * 72)
    print(" MT5 M1 BREAKOUT SCALPER CONFIRMATORY EVALUATION REPORT (PREREG v1.02)")
    print("=" * 72)
    print(f"Overall Verdict       : {res['verdict']}")
    print(f"Total Rows Ingested   : {res['total_rows']}")
    print(f"Plumbing (Evidential=0): {res['plumbing_rows']}")
    print(f"Evidential Rows       : {res['evidential_rows']}")

    if res["verdict"] == "INVALID-not-evaluable":
        print(f"Reason: {res['reason']}")
        print("=" * 72)
        return

    burn = res["burn_in"]
    print("\n--- Burn-In Calibration (Trades 1 to 100) ---")
    print(f"Burn-In Trades (N_burn)    : {burn['n']}")
    print(f"Mean Winner Net (W_bar)    : {burn['w_bar']:.4f} pips")
    print(f"Mean Loser Net (|L_bar|)   : {burn['abs_l_bar']:.4f} pips")
    print(f"Frozen Break-Even Rate (p0): {burn['p0']:.4f} ({burn['p0']*100:.2f}%)")
    print(f"Mean Roundtrip Comm (c_bar): {burn['c_bar_info']:.4f} pips (informational)")
    print(f"Burn-In Std Dev (s_burn)   : {burn['s_burn']:.4f} pips (vs 5.0 pip baseline)")

    ev = res["evaluation"]
    print("\n--- Confirmatory Evaluation (Trades 101 to 1000) ---")
    print(f"Evaluation Trades (N_eval) : {ev['n']}")
    print(f"Adjusted Alpha Threshold   : {ev['alpha']}")

    print("\n[Co-Primary 1: Exact Binomial Win Rate Test]")
    print(f"Wins Count (K)             : {ev['wins_count']} / {ev['n']}")
    print(f"Observed Win Rate (p_hat)  : {ev['win_rate']:.4f} ({ev['win_rate']*100:.2f}%)")
    print(f"Null Threshold (p0)        : {burn['p0']:.4f}")
    print(f"Exact Binomial p-value     : {ev['p_val_binom']:.6f}")
    print(f"Result                     : {'PASS (p < 0.025)' if ev['binom_pass'] else 'FAIL (p >= 0.025)'}")

    print("\n[Co-Primary 2: Cluster-Adjusted Net PnL t-Test]")
    print(f"Clusters (5-min windows M) : {ev['m_clusters']}")
    print(f"Mean Net PnL (x_bar_cluster): {ev['mean_cluster_net_pips']:.4f} pips")
    print(f"Cluster Std Dev            : {ev['cluster_std']:.4f} pips")
    print(f"Cluster Standard Error (SE): {ev['cluster_se']:.4f} pips")
    print(f"Student's t-statistic      : {ev['t_stat']:.4f}")
    print(f"One-Sided p-value          : {ev['p_val_t']:.6f}")
    print(f"Result                     : {'PASS (x_bar > 0 and p < 0.025)' if ev['t_pass'] else 'FAIL (x_bar <= 0 or p >= 0.025)'}")

    print("\n[Spread Fidelity Check]")
    print(f"EURUSD Trades: {ev['eur_n']}, Mean Realized Spread: {ev['eur_mean_spread']:.4f} pips <= Max {ev['eur_spread_threshold']:.4f} pips -> {'PASS' if ev['eur_spread_pass'] else 'FAIL'}")
    print(f"USDJPY Trades: {ev['jpy_n']}, Mean Realized Spread: {ev['jpy_mean_spread']:.4f} pips <= Max {ev['jpy_spread_threshold']:.4f} pips -> {'PASS' if ev['jpy_spread_pass'] else 'FAIL'}")
    print(f"Overall Spread Fidelity    : {'PASS' if ev['spread_fidelity_pass'] else 'FAIL'}")

    print("\n[Sample Size Compliance]")
    print(f"Completed Evaluation Trades: {ev['n']} >= 900 -> {'PASS' if ev['n_reached_pass'] else 'FAIL'}")
    print("=" * 72)
    print(f"FINAL DETERMINATION: >>> {res['verdict']} <<<")
    print("=" * 72)


def main():
    parser = argparse.ArgumentParser(description="Scalper Statistical Evaluator (PREREG v1.02)")
    parser.add_argument("--csv", type=str, required=True, help="Path to roundtrips.csv")
    parser.add_argument("--s-pretest-eurusd", type=float, default=0.25, help="Pre-test baseline spread EURUSD (pips)")
    parser.add_argument("--s-pretest-usdjpy", type=float, default=0.35, help="Pre-test baseline spread USDJPY (pips)")
    parser.add_argument("--alpha", type=float, default=0.025, help="Significance level per co-primary test")
    parser.add_argument("--burn-in-n", type=int, default=100, help="Burn-in sample size")
    parser.add_argument("--target-n", type=int, default=900, help="Evaluation sample size")

    args = parser.parse_args()

    try:
        rows = load_roundtrips(args.csv)
        results = evaluate_scalper(
            rows=rows,
            s_pretest_eurusd=args.s_pretest_eurusd,
            s_pretest_usdjpy=args.s_pretest_usdjpy,
            alpha=args.alpha,
            burn_in_n=args.burn_in_n,
            target_n=args.target_n
        )
        print_report(results)
        if results["verdict"] == "HIT":
            sys.exit(0)
        elif results["verdict"] == "MISS":
            sys.exit(1)
        else:
            sys.exit(2)
    except Exception as e:
        print(f"Error during evaluation: {e}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
