"""Item 2: adverse-selection decomposition. Mid markouts at +1/+10/+60 s and the pre-registered gross edge (fill -> far-touch
exit at +10 s) split by spread, own-side book imbalance, adverse 1 s taker flow, 10 s realised vol, queue ahead and hour of day,
separately for each venue.

Every cell here is EXPLORATORY / POST-HOC (bucket edges fixed in this file before looking at outcomes, but the choice of cuts is
not pre-registered), counts against nothing and decides nothing. Cells are scanned on the arm-A events only: B and C fills are ~95% nested
in A (same trade prints; see verify_edge.py), so pooling arms would double count.
"""
import numpy as np
import pandas as pd

from common import DATASET_LABEL, OUT, block_bootstrap, fmt_ci, load_primary, md_table, save, window_note

MIN_N = 300   # task threshold for a reportable cell


def bucket(series, edges, labels):
    return pd.cut(series, bins=edges, labels=labels, right=False, include_lowest=True)


def dimensions(a: pd.DataFrame) -> dict:
    return {
        "spread at placement (bps)": bucket(a["spread_bps_at_placement"], [0, 3, 5, 10, np.inf], ["<3", "[3,5)", "[5,10)", ">=10"]),
        "own-side top-5 imbalance": bucket(a["own_imb"], [0, .3, .4, .5, .6, 1.01], ["<0.3", "[0.3,0.4)", "[0.4,0.5)", "[0.5,0.6)", ">=0.6"]),
        "adverse 1 s taker flow": pd.Series(np.where(a["flow_1s"] > 0, "flow > 0", "flow = 0"), index=a.index),
        "realised vol 10 s": pd.Series(np.where(a["realised_vol_10s"] > 0, "vol > 0", "vol = 0"), index=a.index),
        "queue ahead (x own size)": bucket(a["queue_mult"], [0, 1, 10, 100, np.inf], ["<1x", "[1,10)x", "[10,100)x", ">=100x"]),
        "hour of day (UTC)": a["hour"].map(lambda h: f"{h:02d}h"),
        "instrument (extra, not requested)": a["instrument"],
    }


def venue_section(d: pd.DataFrame, venue: str) -> list:
    a = d[d.arm == "A"].reset_index(drop=True)
    out = [f"### {venue.capitalize()}", "",
           f"_Arm A primary fills, n = {len(a)}; {window_note(a)}; {a['instrument'].nunique()} instruments. **All cells are exploratory / "
           "post-hoc.** Markouts are mid-based, side-signed (+ = good for the maker) in bps; 'gross +10s' is the pre-registered "
           "fill -> far-touch-exit edge. CI = 5-minute block bootstrap (10,000 resamples, seeded)._", ""]
    ov = []
    for arm in "ABC":
        s = d[d.arm == arm]
        r = block_bootstrap(s["gross"], s["block"])
        ov.append({"arm": arm, "n": len(s), "half-spread earned": s["half_spread_entry"].mean(), "mid markout +1s": s["mk1s"].mean(),
                   "+10s": s["mk10s"].mean(), "+60s": s["mk60s"].mean(), "drift +10s vs half-spread": s["drift10s"].mean(),
                   "gross +10s far-touch [95% CI]": fmt_ci(r)})
    out += ["**Markout curve by arm** (B and C are nested subsets of A)", "", md_table(pd.DataFrame(ov), ".2f"), ""]

    fv = []
    for lo, hi, req in (("A", "B", 0.5), ("B", "C", 0.3)):
        s0, s1 = d[d.arm == lo], d[d.arm == hi]
        fv.append({"filter step": f"{hi} vs {lo}", "fills": f"{len(s0)} -> {len(s1)}", "fill drop %": (len(s0) - len(s1)) / len(s0) * 100.0,
                   "gross delta (bps)": s1["gross"].mean() - s0["gross"].mean(), "mk +10s delta (bps)": s1["mk10s"].mean() - s0["mk10s"].mean(),
                   "pre-reg requirement (10 s markout delta, drop <= 60%)": f">= +{req} bps",
                   "share of arm fills with adverse flow_1s > 0": (s1["flow_1s"] > 0).mean() * 100.0})
    out += ["**Filter-value check (descriptive, same fills)**", "", md_table(pd.DataFrame(fv), ".2f"), ""]

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
                         "drift +10s": s["drift10s"].mean(), "gross +10s [95% CI]": fmt_ci(r), "_gross": r["mean"], "_idx": s.index})
    cells = pd.DataFrame(rows)
    K = len(cells)
    bonf = 0.05 / K
    qual = cells[(cells["n"] >= MIN_N) & (cells["_gross"] > 0)]
    out += [f"**Cell table: {K} cells over 7 single-dimension cuts** (every row exploratory). Cells with n >= {MIN_N}: "
            f"{int((cells['n'] >= MIN_N).sum())}. Cells with positive mean gross edge: {int((cells['_gross'] > 0).sum())}. "
            f"**Cells with positive gross edge AND n >= {MIN_N}: {len(qual)}.** One-sided Bonferroni level over this venue's {K} cells: {bonf:.4f}.", "",
            md_table(cells.drop(columns=["_gross", "_idx"]), ".2f"), ""]

    if len(qual):
        qrows = []
        for _, c in qual.iterrows():
            s = a.loc[c["_idx"]]
            r = block_bootstrap(s["gross"], s["block"], alpha_1s=bonf)
            qrows.append({"dimension": c["dimension"], "cell": c["cell"], "status": "exploratory (post-hoc)", "n": c["n"], "blocks": r["n_blocks"],
                          "gross mean": r["mean"], "95% CI": f"[{r['lo95']:+.2f}, {r['hi95']:+.2f}]",
                          f"one-sided lower bound at alpha={bonf:.4f}": r["lo_1s"], "net of 6 bps (HL maker+taker)": r["mean"] - 6.0,
                          "net of 3 bps (maker+maker)": r["mean"] - 3.0})
        out += [f"**Qualifying cells (n >= {MIN_N}, positive gross) with block-bootstrap CI**", "", md_table(pd.DataFrame(qrows), ".2f"), ""]
    else:
        out += [f"**No cell qualifies (n >= {MIN_N} with positive mean gross edge).**", ""]
    top = cells.sort_values("_gross", ascending=False).head(5).drop(columns=["_gross", "_idx"])
    out += ["**Five highest-gross cells (any n; descriptive leads, not findings)**", "", md_table(top, ".2f"), ""]
    cells.drop(columns=["_gross", "_idx"]).to_csv(OUT / f"adverse_selection_cells_{venue}.csv", index=False)
    return out


def main():
    d = load_primary()
    out = [f"_Dataset: {DATASET_LABEL}._", ""]
    for venue in ("hyperliquid", "binance"):
        v = d[d.venue == venue]
        out += venue_section(v, venue) if len(v) else [f"### {venue.capitalize()}", "", "_No fills._", ""]
    save("adverse_selection", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
