"""Item 3 (secondary, exploratory): primary trade-through fills vs queue-depleted fills.

The engine logs queue-depleted events WITHOUT any outcome fields (mids, far-touch exit and edge are blank by design, Amendment 1),
so an edge comparison cannot be computed from the logged data. This script therefore reports (a) that fact quantitatively,
(b) counts, (c) how the two populations differ in their logged features, and (d) how often a queue-depleted event is followed by a
primary trade-through fill on the same quote side (i.e. how the two fill rules relate), which is the mechanism behind any edge gap.
"""
import numpy as np
import pandas as pd

from common import add_derived, load_csv, load_primary, md_table, save, window_note

OUTCOME_COLS = ["mid_1s", "mid_10s", "mid_60s", "far_touch_exit_10s", "exit_time_ms", "round_trip_edge_bps"]


def main():
    prim = load_primary()
    qd = add_derived(load_csv("queue_depleted.csv"))
    out = [f"_Primary fills: n = {len(prim)} rows; queue-depleted events: n = {len(qd)} rows; {window_note(prim)}. Exploratory / secondary only._", ""]

    # (a) outcome availability
    avail = pd.DataFrame({"field": OUTCOME_COLS,
                          "primary rows with value": [int(prim[c].notna().sum()) if c in prim else 0 for c in OUTCOME_COLS],
                          "queue-depleted rows with value": [int(qd[c].notna().sum()) if c in qd else 0 for c in OUTCOME_COLS]})
    out += ["**(a) Are outcomes logged for queue-depleted events?** No: every outcome field is empty, so the edge of a queue-depleted "
            "fill is not measurable from `queue_depleted.csv` (and the book path is not stored anywhere else).", "", md_table(avail, ".0f"), ""]

    # (b) counts
    rows = []
    for venue in ("hyperliquid", "binance"):
        for arm in "ABC":
            p = prim[(prim.venue == venue) & (prim.arm == arm)]
            q = qd[(qd.venue == venue) & (qd.arm == arm)]
            rows.append({"venue": venue, "arm": arm, "primary (trade-through)": len(p), "queue-depleted": len(q),
                         "QD per primary": (len(q) / len(p)) if len(p) else np.nan})
    out += ["**(b) Counts**", "", md_table(pd.DataFrame(rows), ".2f"), ""]

    # (c) feature comparison, arm A (superset)
    pa, qa = prim[prim.arm == "A"], qd[qd.arm == "A"]

    def feat(s):
        return {"n": len(s), "mean spread bps": s["spread_bps_at_placement"].mean(), "median spread bps": s["spread_bps_at_placement"].median(),
                "mean own-side imbalance": s["own_imb"].mean(), "median queue ahead (x size)": s["queue_mult"].median(),
                "share flow_1s = 0": (s["flow_1s"] == 0).mean(), "share vol_10s = 0": (s["realised_vol_10s"] == 0).mean(),
                "distinct instruments": s["instrument"].nunique()}
    cmp_ = pd.DataFrame({"primary (trade-through)": feat(pa), "queue-depleted": feat(qa)}).T.reset_index().rename(columns={"index": "fill rule (arm A)"})
    for c in ("n", "distinct instruments"):
        cmp_[c] = cmp_[c].astype(int).astype(str)
    out += ["**(c) Logged features at placement, arm A**", "", md_table(cmp_, ".2f"), ""]

    # (d) relationship: QD event -> later trade-through on the same arm/instrument/side?
    link = []
    for win_ms in (2_000, 10_000):
        hit = 0
        for _, r in qa.iterrows():
            m = pa[(pa.instrument == r.instrument) & (pa.side == r.side) & (pa.timestamp_ms > r.timestamp_ms) &
                   (pa.timestamp_ms <= r.timestamp_ms + win_ms)]
            hit += int(len(m) > 0)
        link.append({"window after the queue-depleted event": f"{win_ms // 1000} s", "QD events (arm A)": len(qa),
                     "followed by a primary fill, same instrument+side": hit, "share": hit / len(qa) if len(qa) else np.nan})
    out += ["**(d) How the two rules relate.** A trade-through fill requires a print *below* our bid (a move through the level), "
            "so by construction the primary rule samples fills that coincide with price breaking against the quote; a queue-depleted event "
            "needs only prints *at* our price. Share of queue-depleted events that later become a primary fill:", "", md_table(pd.DataFrame(link), ".2f"), ""]

    out += ["**Conclusion for item 3:** the data cannot show an edge difference. The primary rule is mechanically adverse (fills are "
            "conditioned on a through-print), so primary edge is a conservative lower bound, not an unbiased estimate of queue-position "
            "economics. Measuring the secondary variant needs the engine to log mids / far-touch exit for queue-depleted events "
            "(an engine change, therefore a new pre-registration amendment, outside this task).", ""]
    save("fill_model_compare", "\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
