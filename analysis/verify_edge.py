"""Item 5: independent recomputation of engine.py's edge / fee arithmetic from raw logged fields, plus data-integrity and
convention checks. Nothing here imports engine.py; reporter.generate_report is only called (read-only, no files written) to
cross-check its printed means against the independent ones."""
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

from common import BASE, DATA, FEE_SETS, load_csv, load_primary, md_table, save

sys.dont_write_bytecode = True
TOL_EDGE = 5e-4      # engine writes 4 decimals


def independent_edge(side: str, fill: float, exit_: float) -> float:
    """Reference implementation, written from the pre-registration definition: +1 for buys, -1 for sells."""
    return (1.0 if side == "BUY" else -1.0) * (exit_ - fill) / fill * 1e4


def self_test():
    assert abs(independent_edge("BUY", 100.0, 100.10) - 10.0) < 1e-9      # bought 100, can sell at 100.10 -> +10 bps
    assert abs(independent_edge("SELL", 100.0, 99.90) - 10.0) < 1e-9      # sold 100, can buy back at 99.90 -> +10 bps
    assert abs(independent_edge("BUY", 100.0, 99.90) + 10.0) < 1e-9
    assert abs(independent_edge("SELL", 100.0, 100.10) + 10.0) < 1e-9


def row(check, ok, detail, warn=False):
    """warn=True downgrades a failed check to WARN (small, quantified, not an arithmetic error)."""
    return {"check": check, "result": "PASS" if ok else ("WARN" if warn else "FAIL"), "detail": detail}


def _parse_reporter(text):
    res, venue_arm = {}, None
    for line in text.splitlines():
        m = re.match(r"ARM: (\w+) - (\w) \|", line)
        if m:
            venue_arm = (m.group(1).lower(), m.group(2))
        g = re.match(r"\s+Gross Edge:\s+([+-]?\d+\.\d+) bps", line)
        if g and venue_arm:
            res[venue_arm] = float(g.group(1))
    return res


def reporter_gross_means():
    """v1 data: run the reporter that existed when the data was produced (git 37037b2, with its own EPOCH.json) on a scratch copy of
    the CSVs. current data: the working-tree reporter. Read-only: nothing is written inside the repository."""
    import importlib.util
    import shutil
    import subprocess
    import tempfile
    from common import DATASET
    if DATASET == "current":
        sys.path.insert(0, str(BASE))
        import reporter  # noqa: E402
        return _parse_reporter(reporter.generate_report(str(DATA), is_final=False))
    repo = str(BASE.parent)
    with tempfile.TemporaryDirectory() as tmp:
        for rel in ("reporter.py", "EPOCH.json"):
            blob = subprocess.run(["git", "-C", repo, "show", f"37037b2:paper_mm2/{rel}"], capture_output=True, check=True).stdout
            (Path(tmp) / rel).write_bytes(blob)
        (Path(tmp) / "data").mkdir()
        for f in ("trades.csv", "queue_depleted.csv"):
            shutil.copy(DATA / f, Path(tmp) / "data" / f)
        spec = importlib.util.spec_from_file_location("reporter_v1", Path(tmp) / "reporter.py")
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        return _parse_reporter(mod.generate_report(str(Path(tmp) / "data"), is_final=False))


def main():
    self_test()
    t = load_csv("trades.csv")
    p = load_primary()
    pend = pd.read_csv(DATA / "pending.csv")
    rows = []

    # 1. edge from raw fields
    ref = np.array([independent_edge(s, f, x) for s, f, x in zip(t["side"], t["fill_price"], t["far_touch_exit_10s"])])
    d = np.abs(ref - t["round_trip_edge_bps"].to_numpy())
    rows.append(row("round_trip_edge_bps == side-signed (far_touch_exit - fill)/fill*1e4", d.max() < TOL_EDGE,
                    f"n={len(t)}, max |diff| = {d.max():.2e} bps (tolerance {TOL_EDGE:g}, engine rounds to 4 dp)"))
    # 2. fees
    for col, fee in (("rt_net_hl", 6.0), ("rt_net_binance_vip0", 20.0), ("rt_net_binance_bnb", 15.0), ("rt_net_zero_fee", 0.0)):
        dd = np.abs((ref - fee) - t[col].to_numpy())
        rows.append(row(f"{col} == edge - {fee:g}", dd.max() < 2 * TOL_EDGE, f"max |diff| = {dd.max():.2e} bps"))
    rows.append(row("fee totals match the task / pre-registration (HL 1.5+4.5, VIP0 10+10, BNB 7.5+7.5)",
                    FEE_SETS["HL maker+taker (1.5+4.5)"] == 6.0 and FEE_SETS["Binance VIP0 (10+10)"] == 20.0 and FEE_SETS["Binance BNB (7.5+7.5)"] == 15.0,
                    "6 / 20 / 15 bps round trip; the 3 bps maker+maker set has no engine column (computed here as edge - 3)"))

    # 3. exit convention: far touch is on the opposite side of the mid
    wrong = ((t["side"] == "BUY") & (t["far_touch_exit_10s"] > t["mid_10s"] + 1e-12)) | ((t["side"] == "SELL") & (t["far_touch_exit_10s"] < t["mid_10s"] - 1e-12))
    rows.append(row("far-touch exit lies on the unfavourable side of mid_10s (buys exit at bid <= mid, sells at ask >= mid)", not wrong.any(),
                    f"{int(wrong.sum())} violations of {len(t)}"))
    sign = np.where(t["side"] == "BUY", 1.0, -1.0)
    hs = sign * (t["mid_10s"] - t["far_touch_exit_10s"]) / t["fill_price"] * 1e4
    rows.append(row("implied exit half-spread >= 0 and same scale as placement spread / 2", bool((hs >= -1e-9).all()),
                    f"exit half-spread mean {hs.mean():.2f} bps vs placement half-spread mean {(t['spread_bps_at_placement'] / 2).mean():.2f} bps"))
    zero_edge = int((t["far_touch_exit_10s"] == t["fill_price"]).sum())
    rows.append(row("no silent fallback exit (engine falls back to fill_price if far_touch is missing/0, which would book edge = 0)",
                    bool(t["far_touch_exit_10s"].notna().all() and (t["far_touch_exit_10s"] > 0).all()),
                    f"missing/zero far_touch rows: {int((~(t['far_touch_exit_10s'] > 0)).sum())}. {zero_edge} rows have exit == fill price exactly: "
                    "legitimate (the resting level was unchanged 10 s later); all of them satisfy the exit-side check above"))

    # 4. fill record
    rows.append(row("fill_price == quote_price on every primary fill", bool((t["fill_price"] == t["quote_price"]).all()),
                    "fills are booked at the quoted price, not at the (possibly better) trade print"))
    notional = t["fill_price"] * t["fill_size"]
    rows.append(row("quote size is $10 notional (Amendment 2)", bool(((notional - 10.0).abs() / 10.0 < 0.01).all()),
                    f"notional min {notional.min():.4f}, max {notional.max():.4f}"))
    rows.append(row("fill_id unique; flags consistent (primary=True, queue_depleted=False, reason trade_through)",
                    bool(t["fill_id"].is_unique and t["is_primary_pessimistic_fill"].all() and (~t["is_queue_depleted_fill"]).all() and (t["fill_reason"] == "trade_through").all()),
                    f"{t['fill_id'].nunique()} unique ids"))
    lag = t["exit_time_ms"] - t["timestamp_ms"]
    bad = (lag < 10000) | (lag > 10600)
    late = t[bad]
    rows.append(row("exit read no earlier than 10 s after the fill and within one 0.5 s poll (+ margin)", not bad.any(),
                    f"lag min {lag.min()} / median {lag.median():.0f} / max {lag.max()} ms; {int(bad.sum())} of {len(t)} rows ({bad.mean():.2%}) outside [10.0, 10.6] s"
                    + (f", read {lag[bad].min() / 1000:.0f}-{lag[bad].max() / 1000:.0f} s late at {', '.join(sorted(set(late['dt'].dt.strftime('%H:%M:%S'))))} UTC "
                       f"(gross there {t.loc[bad, 'round_trip_edge_bps'].mean():+.1f} vs {t.loc[~bad, 'round_trip_edge_bps'].mean():+.1f} bps elsewhere; "
                       f"effect on the pooled mean {(t['round_trip_edge_bps'].mean() - t.loc[~bad, 'round_trip_edge_bps'].mean()):+.3f} bps)" if bad.any() else ""),
                    warn=bool(bad.mean() < 0.01)))
    err_bps = 0.5e-8 / t["fill_price"] * 1e4
    imp = t[err_bps > 0.5]
    rows.append(row("8-decimal price logging is not material (mid-based markouts)", bool(err_bps.max() < 0.5),
                    f"max half-unit rounding error {err_bps.max():.2f} bps; {len(imp)} fills ({len(imp) / len(t):.2%}) above 0.5 bps: "
                    f"{', '.join(sorted(set(imp['venue'] + ':' + imp['instrument']))) or 'none'}. Fill/exit prices are on-tick and exact, so the gross edge is "
                    "unaffected; mid_1s/10s/60s (half-tick values) are quantised for those fills", warn=bool(len(imp) / len(t) < 0.01)))

    # 5. pending.csv consistency
    done = pend[pend["status"] == "COMPLETED"].drop_duplicates("fill_id", keep="last").set_index("fill_id")
    ex = pend[pend["status"] == "EXIT_10S"].drop_duplicates("fill_id", keep="last").set_index("fill_id")
    tt = t.set_index("fill_id")
    same = all(np.allclose(tt.loc[i, ["fill_price", "far_touch_exit_10s", "mid_10s"]].astype(float).to_numpy(),
                           ex.loc[i, ["fill_price", "far_touch_exit_10s", "mid_10s"]].astype(float).to_numpy(), rtol=0, atol=1e-8) for i in tt.index if i in ex.index)
    rows.append(row("pending.csv EXIT_10S / COMPLETED records agree with trades.csv", bool(same and set(tt.index) == set(done.index)),
                    f"{len(tt)} trades vs {len(done)} COMPLETED, {len(ex)} EXIT_10S"))

    # 6. nesting of arms
    key = ["instrument", "timestamp_ms", "side"]
    ks = {x: set(map(tuple, t[t.arm == x][key].to_numpy())) for x in "ABC"}
    frac = {f"{a}-in-{b}": len(ks[a] & ks[b]) / len(ks[a]) for a, b in (("B", "A"), ("C", "A"), ("C", "B"))}
    rows.append(row("arm B and C fills are subsets of arm A fills (same trade print)", min(frac.values()) == 1.0,
                    "; ".join(f"{k} {v:.1%}" for k, v in frac.items()) + f". {len(t)} rows = {len(set().union(*ks.values()))} distinct physical fill events "
                    f"({len((ks['B'] | ks['C']) - ks['A'])} appear only in B or C): arms requote independently, so they are ~95% nested, not strictly; "
                    "pooled arm statistics still double count", warn=bool(min(frac.values()) >= 0.9)))

    # 7. reporter cross-check
    try:
        rep = reporter_gross_means()
        ok, det = True, []
        for (venue, arm), val in sorted(rep.items()):
            mine = p[(p.venue == venue) & (p.arm == arm)]["gross"].mean()
            ok &= abs(mine - val) < 0.006
            det.append(f"{venue[:3].upper()}-{arm}: reporter {val:+.2f} vs independent {mine:+.2f}")
        rows.append(row("reporter.py printed gross means == independent recomputation", bool(ok and len(rep) > 0), "; ".join(det)))
    except Exception as e:  # pragma: no cover
        rows.append(row("reporter.py cross-check", False, f"could not run: {e}"))

    checks = pd.DataFrame(rows)
    out = ["_Independent recomputation from raw logged fields (side, fill_price, far_touch_exit_10s, mids); nothing is imported from engine.py._", "",
           md_table(checks), ""]

    stale = (t["mid_1s"] == t["mid_10s"]).mean()
    mid1_eq_fill = (t["mid_1s"] == t["fill_price"]).mean()
    obs = pd.DataFrame([
        {"observation": "share of fills where mid_1s == mid_10s (book unchanged for 9 s)", "value": f"{stale:.1%}"},
        {"observation": "share of fills where mid_1s == fill price (zero half-spread)", "value": f"{mid1_eq_fill:.1%}"},
        {"observation": "realised_vol_10s == 0 at placement", "value": f"{(t['realised_vol_10s'] == 0).mean():.1%}"},
        {"observation": "flow_1s == 0 at placement", "value": f"{(t['flow_1s'] == 0).mean():.1%}"},
    ])
    out += ["**Data-quality observations**", "", md_table(obs), ""]
    save("verify_edge", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
