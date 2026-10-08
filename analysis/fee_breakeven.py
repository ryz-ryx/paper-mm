"""Item 1: fee break-even. Gross round-trip edge (fill -> far-touch exit at +10 s, bps) needed to break even under each
fee set vs the measured gross edge, per venue x arm.  Exploratory descriptive statistics, no decision content."""
import numpy as np
import pandas as pd

from common import FEE_SETS, add_derived, block_bootstrap, fmt_ci, load_primary, md_table, save, window_note


def main():
    d = load_primary()
    out = [f"_Primary (trade-through) fills only; {window_note(d)}. Gross edge is recomputed from raw prices "
           "(side-signed far-touch exit vs fill price), not taken from the engine column. CIs: 5-minute block bootstrap, "
           "10,000 resamples, seeded._", ""]

    be = pd.DataFrame([{"fee set": k, "break-even gross edge (bps)": v} for k, v in FEE_SETS.items()])
    out += ["**Break-even gross round-trip edge by fee set**", "", md_table(be, ".1f"), ""]

    rows, gap_ci_rows = [], []
    for venue in ("hyperliquid", "binance"):
        for arm in "ABC":
            s = d[(d.venue == venue) & (d.arm == arm)]
            r = block_bootstrap(s["gross"], s["block"])
            row = {"venue": venue, "arm": arm, "n": r["n"], "blocks": r["n_blocks"], "measured gross (bps) [95% CI]": fmt_ci(r)}
            for name, fee in FEE_SETS.items():
                row[f"gap vs {fee:g}"] = (r["mean"] - fee) if r["n"] else np.nan
            rows.append(row)
            if venue == "hyperliquid":
                gap_ci_rows.append({"arm": arm, "n": r["n"], **{
                    f"gap vs {fee:g} [95% CI]": (f"{r['mean'] - fee:+.2f} [{r['lo95'] - fee:+.2f}, {r['hi95'] - fee:+.2f}]"
                                                 if r["n_blocks"] >= 2 else "n/a") for fee in (6.0, 3.0, 0.0)}})
    out += ["**Measured gross vs break-even (gap = measured - break-even; negative = shortfall, bps).** "
            "Column suffix = round-trip fee in bps (6 = HL maker+taker, 3 = HL maker+maker, 20 = Binance VIP0, 15 = Binance BNB, 0 = zero fee). "
            "Binance rows are empty: no Binance fills exist in the clean-epoch data.", "", md_table(pd.DataFrame(rows), ".2f"), ""]
    out += ["**Hyperliquid gap with block-bootstrap 95% CI**", "", md_table(pd.DataFrame(gap_ci_rows), ".2f"), ""]

    # decomposition: gross = half-spread earned at placement + post-fill mid drift - half-spread paid at the exit
    dec = []
    for arm in "ABC":
        s = d[(d.venue == "hyperliquid") & (d.arm == arm)]
        if len(s) == 0:
            continue
        H, D, E, G = s["half_spread_entry"].mean(), s["drift10s"].mean(), s["exit_half_spread"].mean(), s["gross"].mean()
        row = {"HL arm": arm, "n": len(s), "half-spread earned at placement": H, "mid drift 0..+10s (adverse sel.)": D,
               "half-spread paid at far-touch exit": E, "gross (= sum)": G}
        for name, fee in list(FEE_SETS.items())[:2]:
            row[f"quoted spread needed for {fee:g} bps (D,E held)"] = 2.0 * (fee - D + E)
        dec.append(row)
    out += ["**Where the gross edge goes (Hyperliquid, bps)**: gross = half-spread earned at placement + mid drift after fill "
            "- half-spread paid at the exit. The last two columns are the naive quoted spread that would clear 6 / 3 bps if the drift "
            "and exit cost stayed at their measured values (drift is likely to get worse with wider spreads, so this is optimistic).", "",
            md_table(pd.DataFrame(dec), ".2f"), ""]

    a = d[(d.venue == "hyperliquid") & (d.arm == "A")]
    inst = a.groupby("instrument").agg(n=("gross", "size"), spread_bps=("spread_bps_at_placement", "mean"),
                                       gross=("gross", "mean"), mk10=("mk10s", "mean")).reset_index()
    inst["net_6bps"] = inst["gross"] - 6.0
    inst = inst.sort_values("n", ascending=False)
    out += ["**Hyperliquid arm A by instrument (descriptive; instruments are not independent of time blocks)**", "",
            md_table(inst, ".2f"), ""]
    save("fee_breakeven", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
