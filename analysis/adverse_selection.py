"""Item 2: adverse-selection decomposition. Mid markouts at +1/+10/+60 s and the pre-registered gross edge (fill -> far-touch
exit at +10 s) split by spread, own-side book imbalance, adverse 1 s taker flow, 10 s realised vol, queue ahead and hour of day.

Every cell here is EXPLORATORY / POST-HOC (bucket edges fixed in this file before looking at outcomes, but the choice of cuts is
not pre-registered), counts against nothing and decides nothing. Cells are scanned on the arm-A events only: arm B fills are a
strict subset of A and C of B (same physical trade prints; verified in verify_edge.py), so pooling arms would double count.
"""
import numpy as np
import pandas as pd

from common import OUT, block_bootstrap, fmt_ci, load_primary, md_table, save, window_note

MIN_N = 300   # task threshold for a reportable cell


def bucket(series, edges, labels):
    return pd.cut(series, bins=edges, labels=labels, right=False, include_lowest=True)


def dimensions(a: pd.DataFrame) -> dict:
    return {
        "spread at placement (bps)": bucket(a["spread_bps_at_placement"], [0, 3, 5, 10, np.inf], ["[2,3)", "[3,5)", "[5,10)", ">=10"]),
        "own-side top-5 imbalance": bucket(a["own_imb"], [0, .3, .4, .5, .6, 1.01], ["<0.3", "[0.3,0.4)", "[0.4,0.5)", "[0.5,0.6)", ">=0.6"]),
        "adverse 1 s taker flow": pd.Series(np.where(a["flow_1s"] > 0, "flow > 0", "flow = 0"), index=a.index),
        "realised vol 10 s": pd.Series(np.where(a["realised_vol_10s"] > 0, "vol > 0", "vol = 0"), index=a.index),
        "queue ahead (x own size)": bucket(a["queue_mult"], [0, 1, 10, 100, np.inf], ["<1x", "[1,10)x", "[10,100)x", ">=100x"]),
        "hour of day (UTC)": a["hour"].map(lambda h: f"{h:02d}h"),
        "instrument (extra, not requested)": a["instrument"],
    }


def main():
    d = load_primary()
    d = d[d.venue == "hyperliquid"]
    a = d[d.arm == "A"].reset_index(drop=True)
    out = [f"_Arm A primary fills, Hyperliquid (the only venue with fills); {window_note(a)}; n = {len(a)} fills. "
           "**All cells are exploratory / post-hoc.** Markouts are mid-based, side-signed (+ = good for the maker) in bps; "
           "'gross +10s' is the pre-registered fill -> far-touch-exit edge. 95% CI = 5-minute block bootstrap (10,000 resamples, seeded); "
           "with few blocks it is optimistic._", ""]

    ov = []
    for arm in "ABC":
        s = d[d.arm == arm]
        r = block_bootstrap(s["gross"], s["block"])
        ov.append({"arm": arm, "n": len(s), "half-spread earned": s["half_spread_entry"].mean(), "mid markout +1s": s["mk1s"].mean(),
                   "+10s": s["mk10s"].mean(), "+60s": s["mk60s"].mean(), "drift +10s vs half-spread": s["drift10s"].mean(),
                   "gross +10s far-touch [95% CI]": fmt_ci(r)})
    out += ["**Overall markout curve by arm** (B and C are nested subsets of A)", "", md_table(pd.DataFrame(ov), ".2f"), ""]

    fv = []
    for lo, hi, req in (("A", "B", 0.5), ("B", "C", 0.3)):
        s0, s1 = d[d.arm == lo], d[d.arm == hi]
        fv.append({"filter step": f"{hi} vs {lo}", "fills": f"{len(s0)} -> {len(s1)}", "fill drop %": (len(s0) - len(s1)) / len(s0) * 100.0,
                   "gross delta (bps)": s1["gross"].mean() - s0["gross"].mean(), "mk +10s delta (bps)": s1["mk10s"].mean() - s0["mk10s"].mean(),
                   "pre-reg requirement (10 s markout delta, drop <= 60%)": f">= +{req} bps",
                   "share of arm fills with adverse flow_1s > 0": (s1["flow_1s"] > 0).mean() * 100.0})
    out += ["**Filter-value check (exploratory; uses the same fills, descriptive only)**. B removes 74% of fills for a small gain; "
            "C is almost identical to B because the flow condition is rarely non-zero.", "", md_table(pd.DataFrame(fv), ".2f"), ""]

    rows = []
    for dim, labels in dimensions(a).items():
        order = list(labels.cat.categories) if hasattr(labels, "cat") else sorted(labels.dropna().unique())
        for lab in order:
            s = a[(labels == lab).to_numpy()]
            if len(s) == 0:
                continue
            r = block_bootstrap(s["gross"], s["block"])
            rows.append({"dimension": dim, "cell": str(lab), "status": "exploratory (post-hoc)", "n": len(s), "blocks": r["n_blocks"],
                         "mk +1s": s["mk1s"].mean(), "mk +10s": s["mk10s"].mean(), "mk +60s": s["mk60s"].mean(),
                         "drift +10s": s["drift10s"].mean(), "gross +10s [95% CI]": fmt_ci(r), "_gross": r["mean"],
                         "gross>0": "yes" if r["mean"] > 0 else "no",
                         f"n>={MIN_N} & gross>0": "YES" if (len(s) >= MIN_N and r["mean"] > 0) else "no"})
    cells = pd.DataFrame(rows)
    K = len(cells)
    out += [f"**Cell table** ({K} cells scanned across 7 single-dimension cuts; every row is exploratory). "
            f"Cells with positive gross edge AND n >= {MIN_N}: **{int(((cells['n'] >= MIN_N) & (cells['_gross'] > 0)).sum())}**. "
            f"Cells with n >= {MIN_N} at all: {int((cells['n'] >= MIN_N).sum())} (the whole arm has only {len(a)} fills). "
            f"Cells with positive mean gross at any n: {int((cells['_gross'] > 0).sum())} of {K}; none can be distinguished from "
            f"noise: with {K} cells a Bonferroni one-sided level would be {0.05 / K:.4f}.", "",
            md_table(cells.drop(columns=["_gross"]), ".2f"), ""]

    pos = cells[cells["_gross"] > 0].sort_values("n", ascending=False).drop(columns=["_gross"])
    out += ["**Cells with positive mean gross edge (any n; descriptive leads only, all far below the n threshold)**", "",
            md_table(pos, ".2f") if len(pos) else "_none_", ""]
    save("adverse_selection", "\n".join(out))
    cells.drop(columns=["_gross"]).to_csv(OUT / "adverse_selection_cells.csv", index=False)
    print("\n".join(out))


if __name__ == "__main__":
    main()
