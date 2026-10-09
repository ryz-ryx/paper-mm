"""Item 1: fee break-even. Gross round-trip edge (fill -> far-touch exit at +10 s, bps) needed to break even under each
fee set vs the measured gross edge, per venue x arm.  Exploratory descriptive statistics, no decision content."""
import numpy as np
import pandas as pd

from common import DATASET_LABEL, FEE_SETS, block_bootstrap, fmt_ci, load_primary, md_table, save, window_note

VENUE_FEES = {"hyperliquid": (6.0, 3.0, 0.0), "binance": (20.0, 15.0, 0.0)}   # the fee sets that apply to each venue (+ zero fee)


def main():
    d = load_primary()
    out = [f"_Dataset: {DATASET_LABEL}. Primary (trade-through) fills only; {window_note(d)}. Gross edge is recomputed from raw prices "
           "(side-signed far-touch exit vs fill price), not taken from the engine column. CIs: 5-minute block bootstrap, "
           "10,000 resamples, seeded._", ""]

    be = pd.DataFrame([{"fee set": k, "break-even gross edge (bps)": v} for k, v in FEE_SETS.items()])
    out += ["**Break-even gross round-trip edge by fee set**", "", md_table(be, ".1f"), ""]

    rows, gap_ci = [], {v: [] for v in VENUE_FEES}
    for venue in VENUE_FEES:
        for arm in "ABC":
            s = d[(d.venue == venue) & (d.arm == arm)]
            r = block_bootstrap(s["gross"], s["block"])
            row = {"venue": venue, "arm": arm, "n": r["n"], "blocks": r["n_blocks"], "measured gross (bps) [95% CI]": fmt_ci(r)}
            for name, fee in FEE_SETS.items():
                row[f"gap vs {fee:g}"] = (r["mean"] - fee) if r["n"] else np.nan
            rows.append(row)
            if r["n"]:
                gap_ci[venue].append({"arm": arm, "n": r["n"], **{
                    f"gap vs {fee:g} [95% CI]": f"{r['mean'] - fee:+.2f} [{r['lo95'] - fee:+.2f}, {r['hi95'] - fee:+.2f}]"
                    for fee in VENUE_FEES[venue]}})
    out += ["**Measured gross vs break-even (gap = measured - break-even; negative = shortfall, bps).** "
            "Column suffix = round-trip fee in bps (6 = HL maker+taker, 3 = HL maker+maker, 20 = Binance VIP0, 15 = Binance BNB, 0 = zero fee).",
            "", md_table(pd.DataFrame(rows), ".2f"), ""]
    for venue, g in gap_ci.items():
        if g:
            out += [f"**{venue.capitalize()} gap with block-bootstrap 95% CI** (fee sets that apply to this venue)", "", md_table(pd.DataFrame(g), ".2f"), ""]

    for venue, fees in VENUE_FEES.items():
        dec, a = [], d[(d.venue == venue)]
        for arm in "ABC":
            s = a[a.arm == arm]
            if len(s) == 0:
                continue
            H, D, E, G = s["half_spread_entry"].mean(), s["drift10s"].mean(), s["exit_half_spread"].mean(), s["gross"].mean()
            row = {"arm": arm, "n": len(s), "half-spread earned at placement": H, "mid drift 0..+10s (adverse sel.)": D,
                   "half-spread paid at far-touch exit": E, "gross (= sum)": G}
            for fee in fees[:2]:
                row[f"quoted spread needed for {fee:g} bps (D,E held)"] = 2.0 * (fee - D + E)
            dec.append(row)
        if dec:
            out += [f"**Where the gross edge goes ({venue.capitalize()}, bps)**: gross = half-spread earned at placement + mid drift after fill "
                    "- half-spread paid at the exit. The last two columns are the naive quoted spread that would clear the fee if drift and "
                    "exit cost stayed at their measured values (optimistic: drift grows with spread).", "", md_table(pd.DataFrame(dec), ".2f"), ""]

    for venue in VENUE_FEES:
        a = d[(d.venue == venue) & (d.arm == "A")]
        if len(a) == 0:
            continue
        inst = a.groupby("instrument").agg(n=("gross", "size"), spread_bps=("spread_bps_at_placement", "mean"),
                                           gross=("gross", "mean"), mk10=("mk10s", "mean")).reset_index()
        inst["net_after_" + ("6bps" if venue == "hyperliquid" else "20bps")] = inst["gross"] - (6.0 if venue == "hyperliquid" else 20.0)
        inst = inst.sort_values("n", ascending=False).head(15)
        out += [f"**{venue.capitalize()} arm A by instrument (top 15 by fills; descriptive; instruments are not independent of time blocks)**", "",
                md_table(inst, ".2f"), ""]
    save("fee_breakeven", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
