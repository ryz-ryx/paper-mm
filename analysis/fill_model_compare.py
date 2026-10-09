"""Item 3 (secondary, exploratory): primary trade-through fills vs queue-depleted fills, per venue.

In the v1 data the engine logged queue-depleted events WITHOUT outcome fields (D4 fixed this from Phase 1b on), so for v1 an edge
comparison cannot be computed; the script reports that quantitatively plus counts, logged-feature differences and how often a
queue-depleted event is followed by a primary trade-through fill. When outcome fields ARE present (Phase 1b data) it also compares
the gross edge of the two fill rules with a block-bootstrap CI.
"""
import numpy as np
import pandas as pd

from common import DATASET_LABEL, add_derived, block_bootstrap, fmt_ci, load_csv, load_primary, md_table, save, window_note

OUTCOME_COLS = ["mid_1s", "mid_10s", "mid_60s", "far_touch_exit_10s", "exit_time_ms", "round_trip_edge_bps"]


def feat(s):
    return {"n": str(len(s)), "mean spread bps": s["spread_bps_at_placement"].mean(), "median spread bps": s["spread_bps_at_placement"].median(),
            "mean own-side imbalance": s["own_imb"].mean(), "median queue ahead (x size)": s["queue_mult"].median(),
            "share flow_1s = 0": (s["flow_1s"] == 0).mean(), "share vol_10s = 0": (s["realised_vol_10s"] == 0).mean(),
            "distinct instruments": str(s["instrument"].nunique())}


def main():
    prim = load_primary()
    qd = add_derived(load_csv("queue_depleted.csv"))
    out = [f"_Dataset: {DATASET_LABEL}. Primary fills: {len(prim)} rows; queue-depleted events: {len(qd)} rows; {window_note(prim)}. "
           "Exploratory / secondary only._", ""]

    have = {c: int(qd[c].notna().sum()) for c in OUTCOME_COLS}
    avail = pd.DataFrame({"field": OUTCOME_COLS, "primary rows with value": [int(prim[c].notna().sum()) for c in OUTCOME_COLS],
                          "queue-depleted rows with value": [have[c] for c in OUTCOME_COLS]})
    has_outcomes = have["round_trip_edge_bps"] > 0
    out += ["**(a) Are outcomes logged for queue-depleted events?** " +
            ("Yes (D4 logging is active): the edge comparison below is computed." if has_outcomes else
             "No: every outcome field is empty in this dataset (pre-D4 engine), so the edge of a queue-depleted fill is not measurable."),
            "", md_table(avail, ".0f"), ""]

    rows = []
    for venue in ("hyperliquid", "binance"):
        for arm in "ABC":
            p = prim[(prim.venue == venue) & (prim.arm == arm)]
            q = qd[(qd.venue == venue) & (qd.arm == arm)]
            rows.append({"venue": venue, "arm": arm, "primary (trade-through)": len(p), "queue-depleted": len(q),
                         "QD per primary": (len(q) / len(p)) if len(p) else np.nan})
    out += ["**(b) Counts**", "", md_table(pd.DataFrame(rows), ".2f"), ""]

    for venue in ("hyperliquid", "binance"):
        pa, qa = prim[(prim.venue == venue) & (prim.arm == "A")], qd[(qd.venue == venue) & (qd.arm == "A")]
        if len(pa) == 0 or len(qa) == 0:
            continue
        cmp_ = pd.DataFrame({"primary (trade-through)": feat(pa), "queue-depleted": feat(qa)}).T.reset_index().rename(columns={"index": f"fill rule ({venue}, arm A)"})
        out += [f"**(c) Logged features at placement, {venue} arm A**", "", md_table(cmp_, ".2f"), ""]

        link = []
        pas = pa.sort_values("timestamp_ms")
        for win_ms in (2_000, 10_000):
            hit = 0
            for _, r in qa.iterrows():
                m = pas[(pas.instrument == r.instrument) & (pas.side == r.side) & (pas.timestamp_ms > r.timestamp_ms) &
                        (pas.timestamp_ms <= r.timestamp_ms + win_ms)]
                hit += int(len(m) > 0)
            link.append({"window after the queue-depleted event": f"{win_ms // 1000} s", "QD events (arm A)": len(qa),
                         "followed by a primary fill, same instrument+side": hit, "share": hit / len(qa)})
        out += [f"**(d) {venue}: share of queue-depleted events later followed by a primary fill** (a trade-through needs a print *below* our bid, "
                "so it samples fills that coincide with price breaking against the quote; queue depletion needs only prints *at* our price)", "",
                md_table(pd.DataFrame(link), ".2f"), ""]

        if has_outcomes and qa["gross"].notna().any():
            e = []
            for name, s in (("primary (trade-through)", pa), ("queue-depleted", qa[qa["gross"].notna()])):
                r = block_bootstrap(s["gross"], s["block"])
                e.append({"fill rule": name, "n": r["n"], "blocks": r["n_blocks"], "mk +10s": s["mk10s"].mean(), "gross +10s [95% CI]": fmt_ci(r)})
            out += [f"**(e) {venue} arm A edge by fill rule**", "", md_table(pd.DataFrame(e), ".2f"), ""]

    out += ["**Conclusion for item 3:** " +
            ("see (e): compare the two gross edges; the primary rule is mechanically adverse (a fill needs a through-print), so it is a "
             "conservative lower bound." if has_outcomes else
             "the data cannot show an edge difference. The primary rule is mechanically adverse (a fill needs a through-print), so primary "
             "edge is a conservative lower bound, not an unbiased estimate of queue-position economics. D4 (Phase 1b engine) logs the missing "
             "outcome fields, so this comparison becomes possible on Phase 1b data."), ""]
    save("fill_model_compare", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
