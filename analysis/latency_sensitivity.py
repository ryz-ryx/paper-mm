"""Item 4: latency sensitivity. Edge as a function of the time between quote placement and the fill ("quote age"), plus the
fill -> measured-exit lag. Exploratory.

Matching: each primary fill is matched to the latest PLACE row (same arm, instrument, side) at or before the fill timestamp. The
engine's 450 ms gate means a fill needs placement + 450 ms <= trade time, so a correct match has age >= 450 ms; any smaller age
is a clock-skew / logging-order artefact (placement timestamps are the local clock, trade timestamps are exchange time).

What this can and cannot say: longer latency can be emulated by keeping only fills whose age >= L (they would still have been live).
SHORTER latency cannot be evaluated - the extra fills it would create are not in the data.
"""
import numpy as np
import pandas as pd

from common import block_bootstrap, fmt_ci, load_csv, load_primary, md_table, save, window_note

GATE_MS = 450


def match_places(fills: pd.DataFrame, places: pd.DataFrame) -> pd.DataFrame:
    f = fills.sort_values("timestamp_ms").copy()
    p = places[places["action"] == "PLACE"][["timestamp_ms", "arm", "instrument", "side", "price", "quote_id"]].rename(
        columns={"timestamp_ms": "place_ts", "price": "place_price", "quote_id": "place_quote_id"}).sort_values("place_ts")
    m = pd.merge_asof(f, p, left_on="timestamp_ms", right_on="place_ts", by=["arm", "instrument", "side"], direction="backward")
    m["age_ms"] = m["timestamp_ms"] - m["place_ts"]
    m["price_match"] = (m["place_price"] - m["quote_price"]).abs() < 1e-9
    return m


def main():
    prim = load_primary()
    quotes = load_csv("quotes.csv")
    a = prim[(prim.venue == "hyperliquid") & (prim.arm == "A")]
    m = match_places(a, quotes)
    out = [f"_Arm A primary fills, Hyperliquid, n = {len(m)}; {window_note(a)}. Exploratory._", ""]

    matched = m["place_ts"].notna()
    ok = matched & m["price_match"]
    viol = ok & (m["age_ms"] < GATE_MS)
    chk = pd.DataFrame([
        {"check": "fills with a prior PLACE row (same arm/instrument/side)", "count": int(matched.sum()), "of": len(m)},
        {"check": "...whose price equals the fill's quote price", "count": int(ok.sum()), "of": len(m)},
        {"check": f"matched fills with age < {GATE_MS} ms (latency-gate violation / clock skew)", "count": int(viol.sum()), "of": int(ok.sum())},
        {"check": "matched fills with age > 1500 ms (quote older than the 1 s requote rule)", "count": int((ok & (m['age_ms'] > 1500)).sum()), "of": int(ok.sum())},
    ])
    out += ["**Matching and gate check**", "", md_table(chk, ".0f"), ""]
    m = m[ok].copy()
    if len(m) == 0:
        save("latency_sensitivity", "\n".join(out + ["No matched fills."]))
        return

    d = m["age_ms"].describe(percentiles=[.05, .25, .5, .75, .95]).round(0)
    out += ["**Quote age at fill (ms)**", "", md_table(d.rename_axis("stat").reset_index().rename(columns={"age_ms": "ms"}), ".0f"), ""]

    edges = [0, 500, 600, 700, 800, 900, 1000, np.inf]
    labels = ["<500", "[500,600)", "[600,700)", "[700,800)", "[800,900)", "[900,1000)", ">=1000"]
    m["age_bucket"] = pd.cut(m["age_ms"], bins=edges, labels=labels, right=False)
    rows = []
    for lab in labels:
        s = m[m["age_bucket"] == lab]
        if len(s) == 0:
            continue
        r = block_bootstrap(s["gross"], s["block"])
        rows.append({"quote age (ms)": lab, "n": len(s), "blocks": r["n_blocks"], "mk +1s": s["mk1s"].mean(), "mk +10s": s["mk10s"].mean(),
                     "drift +10s": s["drift10s"].mean(), "gross +10s [95% CI]": fmt_ci(r)})
    out += ["**Edge by quote age (exploratory, post-hoc buckets)**", "", md_table(pd.DataFrame(rows), ".2f"), ""]

    surv = []
    for L in (450, 500, 600, 700, 800, 900, 1000):
        s = m[m["age_ms"] >= L]
        if len(s) < 5:
            continue
        r = block_bootstrap(s["gross"], s["block"])
        surv.append({"emulated latency L (ms)": L, "fills still live (age >= L)": len(s), "share of all": len(s) / len(m),
                     "gross +10s [95% CI]": fmt_ci(r), "mk +10s": s["mk10s"].mean()})
    out += ["**Longer-latency emulation: keep fills with age >= L** (shorter latencies cannot be evaluated from this data)", "",
            md_table(pd.DataFrame(surv), ".2f"), ""]

    rho = m[["age_ms", "gross"]].corr(method="spearman").iloc[0, 1]
    rho_mk = m[["age_ms", "mk10s"]].corr(method="spearman").iloc[0, 1]
    rng = np.random.default_rng(1)   # permutation p-value for the rank correlation (exploratory, block-agnostic)
    perm = [pd.Series(m["age_ms"].to_numpy()).corr(pd.Series(rng.permutation(m["gross"].to_numpy())), method="spearman") for _ in range(5000)]
    p = float((np.abs(perm) >= abs(rho)).mean())
    out += [f"Spearman correlation, quote age vs gross +10s edge: **{rho:+.3f}** (permutation p = {p:.3f}, n = {len(m)}; fills within a 5-minute "
            f"block are autocorrelated so the true p is larger); vs mid markout +10s: {rho_mk:+.3f}.", ""]

    lag = m["exit_time_ms"] - m["timestamp_ms"]
    out += [f"**Fill -> measured-exit lag** (exit_time - fill timestamp): min {lag.min():.0f}, median {lag.median():.0f}, max {lag.max():.0f} ms "
            f"(the 10 s horizon is polled every 0.5 s, so the exit is read 0-500 ms late). Spearman(exit lag, gross) = "
            f"{pd.Series(lag.to_numpy()).corr(pd.Series(m['gross'].to_numpy()), method='spearman'):+.3f}.", ""]
    save("latency_sensitivity", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
