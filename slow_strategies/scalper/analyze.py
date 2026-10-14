#!/usr/bin/env python3
"""
analyze.py: Scalper Execution & Statistical Evaluation Harness
Implements PREREG v1.05 Sections 4 and 5 (registered document lives on branch scalper-prereg).

Protocol (D22 of the fix specification):
1. Only rows of the given --run-id are used (D17). Rows with evidential != 1 are excluded
   (fail-closed: a missing/blank evidential field counts as 0).
2. INVALID (operational) if
   - ANY row of the run (evidential or not) has exit_reason EXTERNAL: a close not initiated
     by the EA's own exit logic (manual close, stop-out, other DEAL_REASON) invalidates the run, or
   - --incidents PATH is given and the incident file (scalper_incidents.csv) holds any row of
     the run (a blank run_id is counted: fail-closed), or
   - an evidential row of the run
     has an exit_reason outside {TAKE_PROFIT, STOP_LOSS, TIME_STOP} (operational closes
     KILL_SWITCH / DAILY_STOP / EXTERNAL / restart reconciliation are never evidential), or
   - carries an account_md_sha256 different from --account-md-sha256 (D18), or
   - carries a symbol_gate different from --gate-eurusd / --gate-usdjpy (D18), or
   - the run_id has no rows at all, or the burn-in has no winner or no loser (p0 undefined).
3. MISS if any UTC day of the run has summed net pips <= -30.0 (PREREG 5.1.2(4), 6.2).
4. Fewer than 100 + 900 evidential trades: NOT_YET_EVALUABLE before --hard-stop-utc (no
   statistics printed), MISS after it (PREREG 5.1.2(3)).
5. First 100 evidential trades calibrate p0 = |L|/(W+|L|); trades 101..1000 are evaluated:
   binomial win-rate test, clustered one-sided t-test (cluster = window_id), spread fidelity
   (1.20 x S_pre-test per symbol, a symbol with no fills is "not met"), and timeline
   (900th evaluation trade filled on or before the hard stop).
6. Verdicts: HIT / MISS / INVALID / NOT_YET_EVALUABLE.
7. The hard stop is an explicit input (--hard-stop-utc): Start + 8 weeks as fixed at freeze in
   ACCOUNT.md section 2. It is never derived from the run's rows and an operational restart
   (restart column, a second start) never resets it.
"""

import sys
import os
import argparse
import csv
import io
import math
import time
from collections import defaultdict
from datetime import datetime, timezone, timedelta
from typing import Dict, Any, List, Optional
import scipy.stats

VERSION = "1.05"
# Registered constants (PREREG 4.1, 2.6, 4.2). Deliberately NOT command-line options.
ALPHA = 0.025
BURN_IN_N = 100
TARGET_N = 900
DAILY_LOSS_STOP = -30.0
SPREAD_FIDELITY_FACTOR = 1.20
REGISTERED_EXITS = ("TAKE_PROFIT", "STOP_LOSS", "TIME_STOP")
GATE_TOLERANCE = 5.0e-4  # CSV prints symbol_gate with 3 decimals


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


def parse_csv_rows(text: str) -> List[Dict[str, Any]]:
    """Parses CSV text (header row first) into stripped dict rows."""
    reader = csv.DictReader(io.StringIO(text))
    rows = []
    for row in reader:
        rows.append({k.strip(): (v or "").strip() for k, v in row.items() if k is not None})
    return rows


def load_roundtrips(csv_path: str) -> List[Dict[str, Any]]:
    """Loads and parses a roundtrips CSV."""
    if not os.path.exists(csv_path):
        raise FileNotFoundError(f"Roundtrips CSV not found: {csv_path}")
    return parse_csv_rows(read_text_any(csv_path))


def load_incidents(incidents_path: str) -> List[Dict[str, Any]]:
    """Loads the incident CSV. A path that was given but does not exist is an error (fail-closed)."""
    if not os.path.exists(incidents_path):
        raise FileNotFoundError(f"Incidents CSV not found: {incidents_path} (omit --incidents if none was ever written)")
    return parse_csv_rows(read_text_any(incidents_path))


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


def parse_hard_stop_utc(text: str) -> int:
    """Hard stop to epoch ms (UTC). A bare date is inclusive: it means the end of that UTC day."""
    text = text.strip()
    if len(text) == 10:
        day = datetime.strptime(text, "%Y-%m-%d").replace(tzinfo=timezone.utc)
        return int((day + timedelta(days=1)).timestamp() * 1000) - 1
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M:%SZ"):
        try:
            return int(datetime.strptime(text, fmt).replace(tzinfo=timezone.utc).timestamp() * 1000)
        except ValueError:
            pass
    raise ValueError(f"Unrecognised --hard-stop-utc value: {text}")


def exit_day_utc(row: Dict[str, Any]) -> int:
    """UTC day index of the exit (entry deal time + hold_ms)."""
    exit_ms = parse_int(row.get("fill_time_msc", 0)) + parse_int(row.get("hold_ms", 0))
    return exit_ms // 86400000


def daily_stop_breaches(run_rows: List[Dict[str, Any]]) -> List[str]:
    """UTC days of the run whose summed net pips (all run rows, incl. operational) <= -30.0."""
    by_day: Dict[int, float] = defaultdict(float)
    for r in run_rows:
        by_day[exit_day_utc(r)] += parse_float(r.get("net_pips", 0.0))
    return [datetime.fromtimestamp(d * 86400, tz=timezone.utc).strftime("%Y-%m-%d")
            for d, total in sorted(by_day.items()) if total <= DAILY_LOSS_STOP]


def integrity_problems(ev_rows: List[Dict[str, Any]], account_sha: str,
                       gate_eur: float, gate_jpy: float) -> List[str]:
    """Operational INVALID reasons found on evidential rows."""
    problems = []
    bad_exit = sorted({r.get("exit_reason", "") for r in ev_rows if r.get("exit_reason", "") not in REGISTERED_EXITS})
    if bad_exit:
        problems.append(f"evidential rows with non-registered exit_reason: {bad_exit}")
    if any(r.get("account_md_sha256", "").lower() != account_sha.lower() for r in ev_rows):
        problems.append("evidential rows whose account_md_sha256 differs from --account-md-sha256")
    gates = {"EURUSD": gate_eur, "USDJPY": gate_jpy}
    for r in ev_rows:
        want = gates.get(r.get("symbol", ""))
        if want is None or abs(parse_float(r.get("symbol_gate", -1.0), -1.0) - want) > GATE_TOLERANCE:
            problems.append("evidential rows whose symbol_gate differs from --gate-eurusd/--gate-usdjpy")
            break
    return problems


def external_close_problems(run_rows: List[Dict[str, Any]]) -> List[str]:
    """Any EXTERNAL close in the run (evidential or not) makes the run operationally INVALID."""
    n = sum(1 for r in run_rows if r.get("exit_reason", "").strip().upper() == "EXTERNAL")
    if n:
        return [f"{n} EXTERNAL close row(s) in the run (close not initiated by the EA exit logic): operational INVALID"]
    return []


def incident_problems(run_id: str, incident_rows: Optional[List[Dict[str, Any]]]) -> List[str]:
    """Any incident row of the run (blank run_id counts, fail-closed) makes the run operationally INVALID."""
    if not incident_rows:
        return []
    mine = [r for r in incident_rows if r.get("run_id", "") in (run_id, "")]
    if not mine:
        return []
    events = sorted({r.get("event", "") or "?" for r in mine})
    return [f"incident file holds {len(mine)} row(s) for the run (events {events}): operational INVALID"]


def calibrate_burn_in(burn: List[Dict[str, Any]]) -> Dict[str, Any]:
    """p0 = |L|/(W+|L|); W = mean net of net>0, L = mean net of net<=0 (PREREG 2.6)."""
    nets = [parse_float(r.get("net_pips", 0.0)) for r in burn]
    winners = [x for x in nets if x > 0.0]
    losers = [x for x in nets if x <= 0.0]
    if not winners or not losers:
        return {"error": f"burn-in has {len(winners)} winners and {len(losers)} losers: p0 undefined (no unregistered fallback)"}
    w_bar = sum(winners) / len(winners)
    abs_l_bar = abs(sum(losers) / len(losers))
    mean = sum(nets) / len(nets)
    var = sum((x - mean) ** 2 for x in nets) / (len(nets) - 1)
    comm = [2.0 * parse_float(r.get("commission_pips", 0.0)) for r in burn]
    return {"n": len(burn), "w_bar": w_bar, "abs_l_bar": abs_l_bar,
            "p0": abs_l_bar / (w_bar + abs_l_bar),
            "c_bar_info": sum(comm) / len(comm), "s_burn": math.sqrt(var)}


def clustered_t_test(eval_rows: List[Dict[str, Any]]) -> Dict[str, Any]:
    """One-sided t-test on per-window_id mean net pips (H1: mean > 0)."""
    window_pips = defaultdict(list)
    for r in eval_rows:
        window_pips[parse_int(r.get("window_id", 0))].append(parse_float(r.get("net_pips", 0.0)))
    means = [sum(v) / len(v) for v in window_pips.values()]
    m = len(means)
    mean = sum(means) / m
    if m < 2:
        return {"m_clusters": m, "mean": mean, "std": 0.0, "se": 0.0, "t": 0.0, "p": 1.0}
    std = math.sqrt(sum((x - mean) ** 2 for x in means) / (m - 1))
    se = std / math.sqrt(m)
    t_stat = (mean / se) if se > 0 else 0.0
    p_val = float(scipy.stats.t.sf(t_stat, df=m - 1)) if se > 0 else 1.0
    return {"m_clusters": m, "mean": mean, "std": std, "se": se, "t": t_stat, "p": p_val}


def spread_fidelity(eval_rows: List[Dict[str, Any]], s_eur: float, s_jpy: float) -> Dict[str, Any]:
    """Mean realised spread_at_fill <= 1.20 x S_pre-test per symbol; no fills = not met."""
    out: Dict[str, Any] = {}
    for key, sym, s_pre in (("eur", "EURUSD", s_eur), ("jpy", "USDJPY", s_jpy)):
        vals = [parse_float(r.get("spread_at_fill", 0.0)) for r in eval_rows if r.get("symbol") == sym]
        mean = (sum(vals) / len(vals)) if vals else 0.0
        thr = SPREAD_FIDELITY_FACTOR * s_pre
        out[f"{key}_n"] = len(vals)
        out[f"{key}_mean_spread"] = mean
        out[f"{key}_spread_threshold"] = thr
        out[f"{key}_spread_pass"] = bool(vals) and mean <= thr
    out["spread_fidelity_pass"] = out["eur_spread_pass"] and out["jpy_spread_pass"]
    return out


def base_result(verdict: str, rows, run_rows, ev_rows, reason: str = "") -> Dict[str, Any]:
    return {"verdict": verdict, "reason": reason, "total_rows": len(rows),
            "run_rows": len(run_rows), "plumbing_rows": len(run_rows) - len(ev_rows),
            "evidential_rows": len(ev_rows), "required_rows": BURN_IN_N + TARGET_N}


def evaluate_scalper(
    rows: List[Dict[str, Any]],
    run_id: str,
    account_md_sha256: str,
    gate_eurusd: float,
    gate_usdjpy: float,
    s_pretest_eurusd: float,
    s_pretest_usdjpy: float,
    hard_stop_utc_ms: int,
    now_utc_ms: Optional[int] = None,
    incident_rows: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Executes the PREREG v1.05 evaluation over parsed roundtrip rows."""
    now_ms = int(time.time() * 1000) if now_utc_ms is None else now_utc_ms
    run_rows = [r for r in rows if r.get("run_id", "") == run_id]
    ev_rows = [r for r in run_rows if parse_int(r.get("evidential", "0")) == 1]  # fail-closed
    res = base_result("", rows, run_rows, ev_rows)

    if not run_rows:
        return {**res, "verdict": "INVALID", "reason": f"no rows carry run_id '{run_id}'"}
    problems = (external_close_problems(run_rows) + incident_problems(run_id, incident_rows)
                + integrity_problems(ev_rows, account_md_sha256, gate_eurusd, gate_usdjpy))
    if problems:
        return {**res, "verdict": "INVALID", "reason": "; ".join(problems)}
    breaches = daily_stop_breaches(run_rows)
    if breaches:
        return {**res, "verdict": "MISS", "reason": f"daily net loss stop (<= {DAILY_LOSS_STOP}) breached on UTC day(s) {breaches}"}
    if len(ev_rows) < BURN_IN_N + TARGET_N:
        late = now_ms > hard_stop_utc_ms
        return {**res, "verdict": "MISS" if late else "NOT_YET_EVALUABLE",
                "reason": (f"observed {len(ev_rows)} evidential trades, require {BURN_IN_N + TARGET_N}; "
                           + ("hard stop passed" if late else "hard stop not yet reached"))}

    burn = calibrate_burn_in(ev_rows[:BURN_IN_N])
    if "error" in burn:
        return {**res, "verdict": "INVALID", "reason": burn["error"]}
    eval_rows = ev_rows[BURN_IN_N:BURN_IN_N + TARGET_N]
    return finish_evaluation(res, burn, eval_rows, s_pretest_eurusd, s_pretest_usdjpy, hard_stop_utc_ms)


def finish_evaluation(res, burn, eval_rows, s_eur, s_jpy, hard_stop_ms) -> Dict[str, Any]:
    """Co-primary tests, spread fidelity and timeline on the 900 evaluation trades."""
    nets = [parse_float(r.get("net_pips", 0.0)) for r in eval_rows]
    n_eval = len(eval_rows)
    wins = sum(1 for x in nets if x > 0.0)
    p_binom = float(scipy.stats.binomtest(k=wins, n=n_eval, p=burn["p0"], alternative="greater").pvalue)
    binom_pass = p_binom < ALPHA

    tt = clustered_t_test(eval_rows)
    t_pass = tt["mean"] > 0.0 and tt["p"] < ALPHA
    fid = spread_fidelity(eval_rows, s_eur, s_jpy)
    last_fill_ms = parse_int(eval_rows[-1].get("fill_time_msc", 0))
    n_reached_pass = (n_eval >= TARGET_N) and last_fill_ms <= hard_stop_ms

    hit = binom_pass and t_pass and fid["spread_fidelity_pass"] and n_reached_pass
    evaluation = {"n": n_eval, "alpha": ALPHA, "wins_count": wins, "win_rate": wins / n_eval,
                  "p_val_binom": p_binom, "binom_pass": binom_pass,
                  "m_clusters": tt["m_clusters"], "mean_cluster_net_pips": tt["mean"],
                  "cluster_std": tt["std"], "cluster_se": tt["se"], "t_stat": tt["t"],
                  "p_val_t": tt["p"], "t_pass": t_pass, "last_fill_time_msc": last_fill_ms,
                  "hard_stop_utc_ms": hard_stop_ms, "n_reached_pass": n_reached_pass, **fid}
    return {**res, "verdict": "HIT" if hit else "MISS", "burn_in": burn, "evaluation": evaluation}


def print_report(res: Dict[str, Any]) -> None:
    print("=" * 72)
    print(f" MT5 M1 BREAKOUT SCALPER CONFIRMATORY EVALUATION REPORT (PREREG v{VERSION})")
    print("=" * 72)
    print(f"Overall Verdict       : {res['verdict']}")
    print(f"Total Rows Ingested   : {res['total_rows']}  (this run: {res['run_rows']})")
    print(f"Non-evidential (run)  : {res['plumbing_rows']}")
    print(f"Evidential Rows       : {res['evidential_rows']}")
    if "evaluation" not in res:
        print(f"Reason: {res['reason']}")
        print("=" * 72)
        return
    burn = res["burn_in"]
    print("\n--- Burn-In Calibration (Trades 1 to 100) ---")
    print(f"Mean Winner Net (W_bar)    : {burn['w_bar']:.4f} pips")
    print(f"Mean Loser Net (|L_bar|)   : {burn['abs_l_bar']:.4f} pips")
    print(f"Frozen Break-Even Rate (p0): {burn['p0']:.4f} ({burn['p0']*100:.2f}%)")
    print(f"Mean Roundtrip Comm (c_bar): {burn['c_bar_info']:.4f} pips (informational)")
    print(f"Burn-In Std Dev (s_burn)   : {burn['s_burn']:.4f} pips (vs 5.0 pip baseline)")
    ev = res["evaluation"]
    print("\n--- Confirmatory Evaluation (Trades 101 to 1000) ---")
    print(f"Evaluation Trades (N_eval) : {ev['n']}   Alpha: {ev['alpha']}")
    print(f"[Win rate]  K={ev['wins_count']}/{ev['n']} ({ev['win_rate']*100:.2f}%) vs p0={burn['p0']:.4f}  p={ev['p_val_binom']:.6f}  -> {'met' if ev['binom_pass'] else 'not met'}")
    print(f"[Cluster t] M={ev['m_clusters']} mean={ev['mean_cluster_net_pips']:.4f} SE={ev['cluster_se']:.4f} t={ev['t_stat']:.4f} p={ev['p_val_t']:.6f}  -> {'met' if ev['t_pass'] else 'not met'}")
    for key, name in (("eur", "EURUSD"), ("jpy", "USDJPY")):
        print(f"[Spread]    {name}: n={ev[key+'_n']} mean={ev[key+'_mean_spread']:.4f} <= {ev[key+'_spread_threshold']:.4f} -> {'met' if ev[key+'_spread_pass'] else 'not met'}")
    print(f"[Timeline]  900th evaluation fill {ev['last_fill_time_msc']} <= hard stop {ev['hard_stop_utc_ms']} -> {'met' if ev['n_reached_pass'] else 'not met'}")
    print("=" * 72)
    print(f"FINAL DETERMINATION: >>> {res['verdict']} <<<")
    print("=" * 72)


EXIT_CODES = {"HIT": 0, "MISS": 1, "INVALID": 2, "NOT_YET_EVALUABLE": 4}


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=f"Scalper Statistical Evaluator (PREREG v{VERSION}); alpha, burn-in and target N are registered constants")
    p.add_argument("--csv", required=True, help="Path to scalper_roundtrips.csv")
    p.add_argument("--run-id", required=True, help="InpRunId of the evidential run to evaluate")
    p.add_argument("--account-md-sha256", required=True, help="Expected ACCOUNT.md SHA256 (64 hex)")
    p.add_argument("--gate-eurusd", type=float, required=True, help="Frozen EURUSD spread gate (pips)")
    p.add_argument("--gate-usdjpy", type=float, required=True, help="Frozen USDJPY spread gate (pips)")
    p.add_argument("--s-pretest-eurusd", type=float, required=True, help="Frozen S_pre-test EURUSD (pips)")
    p.add_argument("--s-pretest-usdjpy", type=float, required=True, help="Frozen S_pre-test USDJPY (pips)")
    p.add_argument("--hard-stop-utc", required=True,
                   help="Hard stop = Start + 8 weeks as fixed at freeze in ACCOUNT.md (never reset by a restart): "
                        "YYYY-MM-DD (inclusive, end of UTC day) or 'YYYY-MM-DD HH:MM:SS'")
    p.add_argument("--incidents", default=None,
                   help="Optional path to scalper_incidents.csv; any row of the run makes the verdict INVALID")
    return p


def main(argv: Optional[List[str]] = None) -> None:
    args = build_parser().parse_args(argv)
    try:
        results = evaluate_scalper(
            rows=load_roundtrips(args.csv), run_id=args.run_id,
            account_md_sha256=args.account_md_sha256,
            gate_eurusd=args.gate_eurusd, gate_usdjpy=args.gate_usdjpy,
            s_pretest_eurusd=args.s_pretest_eurusd, s_pretest_usdjpy=args.s_pretest_usdjpy,
            hard_stop_utc_ms=parse_hard_stop_utc(args.hard_stop_utc),
            incident_rows=load_incidents(args.incidents) if args.incidents else None)
        print_report(results)
        sys.exit(EXIT_CODES[results["verdict"]])
    except SystemExit:
        raise
    except Exception as e:
        print(f"Error during evaluation: {e}", file=sys.stderr)
        sys.exit(3)


if __name__ == "__main__":
    main()
