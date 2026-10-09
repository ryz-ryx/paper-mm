"""Shared loaders, derived columns and statistics for the phase-1 diagnostics.

READ-ONLY with respect to engine.py, reporter.py, phase1_preregistration.md and the data files.
Only rows from the clean-epoch cutover through the dev end date (EPOCH.json) are ever analysed;
rows on/after the hold-out start are dropped and counted (there are none while the dev period is running).
Everything computed here is EXPLORATORY / POST-HOC and is not a registered test.
"""
import json
from pathlib import Path

import numpy as np
import pandas as pd

import os

REPO = Path(__file__).resolve().parents[1]
BASE = REPO / "paper_mm2"
_E = json.loads((BASE / "EPOCH.json").read_text(encoding="utf-8"))   # current (Phase 1b) epoch

# Which dataset the diagnostics run on (env PHASE1_DATASET):
#   v1      = paper_mm2/data_v1, the Phase 1a archive (6,064 primary fills incl. Binance, 2026-10-08 06:43..17:30 UTC), with the
#             ORIGINAL Phase 1a window from EPOCH.json at commit 37037b2. Amendment 3 excludes it from Phase 1b statistics, so
#             anything computed on it is exploratory and must not feed a Phase 1b decision.
#   current = paper_mm2/data with the current EPOCH.json (Phase 1b).
DATASET = os.environ.get("PHASE1_DATASET", "v1")
DATASETS = {
    "v1": {"dir": BASE / "data_v1", "cutover_utc": "2026-10-08T06:40:17Z", "dev_end": "2026-10-11", "holdout_start": "2026-10-12",
           "label": "Phase 1a / v1 archive (exploratory only; excluded from Phase 1b statistics by Amendment 3)"},
    "current": {"dir": BASE / "data", "cutover_utc": _E["cutover_utc"], "dev_end": _E["dev_end"], "holdout_start": _E["holdout_start"],
                "label": "Phase 1b dev window"},
}
_C = DATASETS[DATASET]
DATA = _C["dir"]
DATASET_LABEL = _C["label"]
OUT = Path(__file__).resolve().parent / ("out" if DATASET == "v1" else f"out_{DATASET}")
OUT.mkdir(exist_ok=True)

_cut = pd.Timestamp(_C["cutover_utc"])
if DATASET == "current" and _E.get("partial_first_day_excluded"):
    _cut = pd.Timestamp(_E["dev_start"], tz="UTC")             # Amendment 3: partial first day is excluded
CUTOVER_MS = int(_cut.timestamp() * 1000)
DEV_END_EXCL_MS = int((pd.Timestamp(_C["dev_end"], tz="UTC") + pd.Timedelta(days=1)).timestamp() * 1000)
HOLDOUT_START_MS = int(pd.Timestamp(_C["holdout_start"], tz="UTC").timestamp() * 1000)

# round-trip fee totals in bps (entry maker leg + exit leg), as listed in the pre-registration / task
FEE_SETS = {
    "HL maker+taker (1.5+4.5)": 6.0,
    "HL maker+maker (1.5+1.5)": 3.0,
    "Binance VIP0 (10+10)": 20.0,
    "Binance BNB (7.5+7.5)": 15.0,
    "zero fee": 0.0,
}
SEED = 20261008
BLOCK_MS = 300_000   # 5-minute blocks, as pre-registered


def load_csv(name: str) -> pd.DataFrame:
    """Load a data CSV restricted to the clean-epoch dev window. Returns the window rows only."""
    df = pd.read_csv(DATA / name)
    if "timestamp_ms" not in df.columns or df.empty:
        return df
    in_holdout = (df["timestamp_ms"] >= HOLDOUT_START_MS).sum()
    keep = (df["timestamp_ms"] >= CUTOVER_MS) & (df["timestamp_ms"] < DEV_END_EXCL_MS)
    df = df[keep].copy()
    df.attrs["dropped_holdout_rows"] = int(in_holdout)
    assert (df["timestamp_ms"] < HOLDOUT_START_MS).all(), "hold-out rows leaked into an analysis frame"
    df["dt"] = pd.to_datetime(df["timestamp_ms"], unit="ms", utc=True)
    df["hour"] = df["dt"].dt.hour
    df["block"] = df["timestamp_ms"] // BLOCK_MS
    return df.reset_index(drop=True)


def add_derived(df: pd.DataFrame) -> pd.DataFrame:
    """Independent recomputation of every outcome from raw price fields (nothing taken from the engine's
    round_trip_edge_bps / rt_net_* columns)."""
    d = df.copy()
    d["sign"] = np.where(d["side"] == "BUY", 1.0, -1.0)
    px = d["fill_price"]
    for h in ("1s", "10s", "60s"):
        d[f"mk{h}"] = d["sign"] * (d[f"mid_{h}"] - px) / px * 1e4              # mid markout, + = good for us
    d["gross"] = d["sign"] * (d["far_touch_exit_10s"] - px) / px * 1e4           # fill -> far-touch exit at +10 s
    d["half_spread_entry"] = d["spread_bps_at_placement"] / 2.0                  # what a touch fill earns vs mid
    d["exit_half_spread"] = d["mk10s"] - d["gross"]                              # cost of crossing at the exit
    for h in ("1s", "10s", "60s"):
        d[f"drift{h}"] = d[f"mk{h}"] - d["half_spread_entry"]                    # post-fill mid move vs the half spread
    d["own_imb"] = np.where(d["side"] == "BUY", d["top5_imbalance"], 1.0 - d["top5_imbalance"])
    d["queue_mult"] = d["queue_ahead"] / d["fill_size"]
    d["notional"] = d["fill_price"] * d["fill_size"]
    return d


def load_primary() -> pd.DataFrame:
    t = load_csv("trades.csv")
    return add_derived(t[t["is_primary_pessimistic_fill"] == True].copy())  # noqa: E712


def block_bootstrap(values, blocks, n_resamples: int = 10000, seed: int = SEED, alpha_1s: float = 0.0083):
    """Cluster (5-minute block) bootstrap of the mean, ratio-of-sums per resample (same estimator as reporter.py but
    seeded). Returns mean, two-sided 95% CI, one-sided bounds at alpha_1s, n, number of blocks."""
    v = np.asarray(values, float)
    b = np.asarray(blocks)
    ok = np.isfinite(v)
    v, b = v[ok], b[ok]
    out = {"n": int(len(v)), "n_blocks": int(len(np.unique(b))) if len(v) else 0}
    if len(v) == 0:
        return {**out, "mean": np.nan, "lo95": np.nan, "hi95": np.nan, "lo_1s": np.nan, "hi_1s": np.nan}
    _, inv = np.unique(b, return_inverse=True)
    sums = np.bincount(inv, weights=v)
    cnts = np.bincount(inv).astype(float)
    nb = len(sums)
    rng = np.random.default_rng(seed)
    means = []
    for _ in range(n_resamples // 1000):
        idx = rng.integers(0, nb, size=(1000, nb))
        s, c = sums[idx].sum(axis=1), cnts[idx].sum(axis=1)
        means.append(s / c)
    m = np.concatenate(means)
    return {**out, "mean": float(v.mean()),
            "lo95": float(np.percentile(m, 2.5)), "hi95": float(np.percentile(m, 97.5)),
            "lo_1s": float(np.percentile(m, alpha_1s * 100)), "hi_1s": float(np.percentile(m, (1 - alpha_1s) * 100))}


def fmt_ci(r, digits=2, one_sided=False):
    if r["n"] == 0:
        return "n/a"
    if r["n_blocks"] < 2:
        return f"{r['mean']:+.{digits}f} [n/a: 1 block]"
    lo, hi = (r["lo_1s"], r["hi_1s"]) if one_sided else (r["lo95"], r["hi95"])
    return f"{r['mean']:+.{digits}f} [{lo:+.{digits}f}, {hi:+.{digits}f}]"


def md_table(df: pd.DataFrame, floatfmt: str = ".2f") -> str:
    cols = list(df.columns)

    def cell(x):
        if isinstance(x, (float, np.floating)):
            return "" if np.isnan(x) else format(x, floatfmt)
        return str(x)
    lines = ["| " + " | ".join(map(str, cols)) + " |", "|" + "|".join("---" for _ in cols) + "|"]
    for _, r in df.iterrows():
        lines.append("| " + " | ".join(cell(r[c]) for c in cols) + " |")
    return "\n".join(lines)


def save(name: str, text: str) -> None:
    (OUT / f"{name}.md").write_text(text.rstrip() + "\n", encoding="utf-8")


def window_note(df: pd.DataFrame) -> str:
    lo, hi = df["dt"].min(), df["dt"].max()
    return (f"window {lo:%Y-%m-%d %H:%M} .. {hi:%Y-%m-%d %H:%M} UTC "
            f"({(hi - lo).total_seconds() / 60:.0f} min, {df['block'].nunique()} five-minute blocks)")
