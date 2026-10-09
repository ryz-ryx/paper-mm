"""Hyperliquid funding-carry backtest (research only: reads downloaded public data, places no orders).

Data: analysis/funding_data (funding_download.py): hourly fundingHistory + 1h candles for every perp, 90 days, delisted coins included.
Window: manifest start_ms .. +2160 h.  Dev = first 1440 h (60 d), hold-out = last 720 h (30 d).

Strategy variants (all fixed here BEFORE any result was looked at):
  signal   raw : the latest hourly funding print, annualised (rate * 24 * 365)           <- literal reading of the task
           ma24: trailing mean of the last 24 prints, annualised (needs all 24 prints)    <- smoothed variant
  entry    signal > T  for T in {10, 20, 40} % APR   (positive funding only: the perp is SHORT and receives funding)
  exit     signal < 5 % APR (or the coin's candle data ends)
  mode     UNH : short perp only (price risk fully open)
           DN  : short perp + long hedge leg. The hedge leg is a perp-only proxy: its price move cancels the short exactly
                 (zero basis), so price P&L = 0, but the hedge leg pays the same fees as the perp leg (2 legs).
  fees     maker/maker: 1.5 bps per side per leg  (3 bps round trip per leg);  taker/taker: 4.5 per side (9 bps round trip per leg)
  portfolio  $200, 5 slots of $40 (UNH: $40 perp notional; DN: $20 perp + $20 hedge notional). Free slots are filled with the
           highest-signal coins; capital does not compound; idle cash earns nothing.

Timing (all causal): the funding print of hour h is known after the start of hour h; the decision uses prints <= h; orders execute at the
OPEN of hour h+1; a position is paid the prints h+2 ... x (x = hour of the exit decision): the print that coincides with an execution
instant is never credited (conservative).  Funding paid per print = rate * notional * open_price(h)/entry_price.
Dev-selected thresholds: per (signal, mode, fee) the threshold with the best dev annualised return (>= 10 dev cycles; see MIN_DEV_CYCLES note) is frozen and
only that one is evaluated on the hold-out.
"""
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
DATA = HERE / "funding_data"
OUT = HERE / "out_funding"
HOUR = 3_600_000
APR = 24 * 365 * 100.0            # per-hour rate -> % APR
THRESHOLDS = (10.0, 20.0, 40.0)
EXIT_APR = 5.0
SIDE_BPS = {"maker/maker": 1.5, "taker/taker": 4.5}
CAPITAL, SLOTS = 200.0, 5
DEV_HOURS = 1440
MIN_DEV_CYCLES = 10   # first draft used 20; lowered after seeing dev (not hold-out) cycle counts of 14-15 for ma24 - disclosed in the report
SIGNALS = ("raw", "ma24")
MODES = ("UNH", "DN")


def load():
    man = json.loads((DATA / "manifest.json").read_text())
    start, T = man["start_ms"], (man["end_ms"] - man["start_ms"]) // HOUR
    names, F, O, excluded = [], [], [], []
    for coin, meta in man["coins"].items():
        pf, pc = DATA / f"{coin}_funding.parquet", DATA / f"{coin}_candles.parquet"
        if not (pf.exists() and pc.exists()):
            excluded.append((coin, "not downloaded", meta["delisted"]))
            continue
        f, c = pd.read_parquet(pf), pd.read_parquet(pc)
        if len(f) == 0 or len(c) == 0:
            excluded.append((coin, "no candles" if len(c) == 0 else "no funding", meta["delisted"]))
            continue
        fa, oa = np.full(T + 1, np.nan), np.full(T + 1, np.nan)
        h = ((f["time"].to_numpy() - start) // HOUR).astype(int)
        ok = (h >= 0) & (h < T)
        fa[h[ok]] = f["fundingRate"].to_numpy()[ok]
        h = ((c["t"].to_numpy() - start) // HOUR).astype(int)
        ok = (h >= 0) & (h <= T)
        oa[h[ok]] = c["o"].to_numpy()[ok]
        if np.isfinite(oa).sum() < 48 or np.isfinite(fa).sum() < 48:
            excluded.append((coin, "fewer than 48 usable hours", meta["delisted"]))
            continue
        names.append(coin)
        F.append(fa)
        O.append(oa)
    return man, names, np.array(F).T, np.array(O).T, excluded


def signals(fund):
    raw = fund * APR
    ma24 = pd.DataFrame(fund).rolling(24, min_periods=24).mean().to_numpy() * APR
    return {"raw": raw, "ma24": ma24}


def simulate(metric, fund, opn, h0, h1, thr, mode, side_bps, slots=SLOTS, capital=CAPITAL):
    """Hourly event simulation over boundaries h0..h1; returns (equity list, cycles list, mean slot utilisation)."""
    legs = 2 if mode == "DN" else 1
    notional = capital / slots / (2 if mode == "DN" else 1)
    pos, sched_exit, sched_entry = {}, set(), []
    realized, eq, cycles, used = 0.0, [], [], []

    def close(c, t, forced):
        nonlocal realized
        p = pos.pop(c)
        px = opn[t, c] if np.isfinite(opn[t, c]) else p["last"]
        ratio = px / p["entry"]
        price = -notional * (ratio - 1.0) if mode == "UNH" else 0.0
        fee_exit = side_bps * 1e-4 * notional * ratio * legs
        net = price + p["fund"] - p["fee"] - fee_exit
        realized += net
        cycles.append({"coin": c, "entry_h": p["h"], "exit_h": t, "hold_h": t - p["h"], "forced": forced,
                       "funding_bps": p["fund"] / notional * 1e4, "price_bps": price / notional * 1e4,
                       "fee_bps": (p["fee"] + fee_exit) / notional * 1e4, "net_bps": net / notional * 1e4})

    for t in range(h0, h1 + 1):
        px = opn[t]
        for c in sorted(sched_exit):
            close(c, t, False)
        sched_exit = set()
        if t < h1:
            for c in sched_entry:
                if c not in pos and len(pos) < slots and np.isfinite(px[c]):
                    pos[c] = {"entry": px[c], "h": t, "fund": 0.0, "last": px[c], "fee": side_bps * 1e-4 * notional * legs}
            for c, p in pos.items():
                if np.isfinite(px[c]):
                    p["last"] = px[c]
                if p["h"] < t and np.isfinite(fund[t, c]):               # entered at an earlier boundary: print t is credited
                    p["fund"] += fund[t, c] * notional * (p["last"] / p["entry"])
        sched_entry = []
        if t == h1:
            for c in list(pos):
                close(c, t, True)
        mtm = sum((-notional * (p["last"] / p["entry"] - 1.0) if mode == "UNH" else 0.0) + p["fund"] - p["fee"] for p in pos.values())
        eq.append(capital + realized + mtm)
        used.append(len(pos) / slots)
        if t < h1:
            m = metric[t]
            for c in pos:
                if (np.isfinite(m[c]) and m[c] < EXIT_APR) or not np.isfinite(opn[t + 1, c]):
                    sched_exit.add(c)
            free = slots - len(pos) + len(sched_exit)
            if free > 0 and t + 1 < h1:
                cand = [c for c in np.where(m > thr)[0] if c not in pos and np.isfinite(opn[t + 1, c])]
                cand.sort(key=lambda c: (-m[c], c))
                sched_entry = cand[:free]
    return eq, cycles, float(np.mean(used))


def summarise(eq, cycles, util, days):
    e = np.array(eq)
    day = e[::24]
    r = np.diff(day) / day[:-1]
    peak = np.maximum.accumulate(e)
    cy = pd.DataFrame(cycles)
    ann = (e[-1] - e[0]) / e[0] * 365.0 / days * 100.0
    return {"cycles": len(cy), "net bps/cycle": cy["net_bps"].mean() if len(cy) else np.nan,
            "median": cy["net_bps"].median() if len(cy) else np.nan,
            "funding bps": cy["funding_bps"].mean() if len(cy) else np.nan, "price bps": cy["price_bps"].mean() if len(cy) else np.nan,
            "fee bps": cy["fee_bps"].mean() if len(cy) else np.nan,
            "win %": (cy["net_bps"] > 0).mean() * 100 if len(cy) else np.nan, "forced close %": cy["forced"].mean() * 100 if len(cy) else np.nan, "hold h": cy["hold_h"].mean() if len(cy) else np.nan,
            "Sharpe (daily, ann.)": (r.mean() / r.std(ddof=1) * np.sqrt(365)) if len(r) > 2 and r.std(ddof=1) > 0 else np.nan,
            "max DD %": ((e - peak) / peak).min() * 100, "max DD $": (e - peak).min(),
            "total $": e[-1] - e[0], "ann. return % on $200": ann, "slot util %": util * 100}


def md(df, fmt="{:.2f}"):
    cols = list(df.columns)
    lines = ["| " + " | ".join(map(str, cols)) + " |", "|" + "|".join("---" for _ in cols) + "|"]
    for _, r in df.iterrows():
        lines.append("| " + " | ".join(("" if (isinstance(x, float) and np.isnan(x)) else (fmt.format(x) if isinstance(x, (float, np.floating)) else str(x))) for x in r) + " |")
    return "\n".join(lines)


def main():
    OUT.mkdir(exist_ok=True)
    man, names, fund, opn, excluded = load()
    T = fund.shape[0] - 1
    sig = signals(fund)
    periods = {"dev": (0, DEV_HOURS), "hold-out": (DEV_HOURS, T)}
    d = {"coins used": len(names), "of which delisted": sum(man["coins"][n]["delisted"] for n in names), "excluded": len(excluded),
         "excluded (delisted)": sum(x[2] for x in excluded)}

    desc = []
    for pn, (a, b) in periods.items():
        for s in SIGNALS:
            m = sig[s][a:b]
            v = m[np.isfinite(m)]
            row = {"period": pn, "signal": s, "median APR % (all coin-hours)": np.median(v), "mean APR %": v.mean()}
            for th in THRESHOLDS:
                row[f"coin-hours > {th:g}%"] = (v > th).mean() * 100
            desc.append(row)
    (OUT / "descriptive.md").write_text(md(pd.DataFrame(desc)) + "\n", encoding="utf-8")

    rows, store = [], {}
    for s in SIGNALS:
        for mode in MODES:
            for fee, sb in SIDE_BPS.items():
                for th in THRESHOLDS:
                    a, b = periods["dev"]
                    eq, cy, u = simulate(sig[s], fund, opn, a, b, th, mode, sb)
                    res = summarise(eq, cy, u, (b - a) / 24)
                    rows.append({"signal": s, "mode": mode, "fees": fee, "entry APR >": th, **res})
                    store[(s, mode, fee, th)] = res
    dev = pd.DataFrame(rows)
    dev.to_csv(OUT / "dev_results.csv", index=False)

    sel_rows = []
    for s in SIGNALS:
        for mode in MODES:
            for fee, sb in SIDE_BPS.items():
                sub = dev[(dev.signal == s) & (dev["mode"] == mode) & (dev.fees == fee) & (dev.cycles >= MIN_DEV_CYCLES)]
                if sub.empty:
                    sel_rows.append({"signal": s, "mode": mode, "fees": fee, "frozen threshold": np.nan, "dev ann. %": np.nan})
                    continue
                best = sub.sort_values(["ann. return % on $200", "Sharpe (daily, ann.)"], ascending=False).iloc[0]
                th = float(best["entry APR >"])
                a, b = periods["hold-out"]
                eq, cy, u = simulate(sig[s], fund, opn, a, b, th, mode, sb)
                res = summarise(eq, cy, u, (b - a) / 24)
                sel_rows.append({"signal": s, "mode": mode, "fees": fee, "frozen threshold": th,
                                 "dev ann. %": best["ann. return % on $200"], **res})
    sel = pd.DataFrame(sel_rows)
    sel.to_csv(OUT / "holdout_results.csv", index=False)

    keep = ["signal", "mode", "fees", "entry APR >", "cycles", "net bps/cycle", "median", "funding bps", "price bps", "fee bps", "win %", "forced close %",
            "hold h", "Sharpe (daily, ann.)", "max DD %", "max DD $", "total $", "ann. return % on $200", "slot util %"]
    (OUT / "dev_table.md").write_text(md(dev[keep]) + "\n", encoding="utf-8")
    (OUT / "holdout_table.md").write_text(md(sel[["signal", "mode", "fees", "frozen threshold", "dev ann. %"] + keep[4:]]) + "\n", encoding="utf-8")
    (OUT / "coverage.md").write_text(md(pd.DataFrame([d])) + "\n\nExcluded: " + ", ".join(f"{c} ({why}{', delisted' if dl else ''})" for c, why, dl in excluded) + "\n",
                                     encoding="utf-8")

    tpl = HERE / "funding_carry.template.md"
    if tpl.exists():
        text = tpl.read_text(encoding="utf-8")
        for name in ("descriptive", "dev_table", "holdout_table", "coverage"):
            text = text.replace("{{table:%s}}" % name, (OUT / f"{name}.md").read_text(encoding="utf-8").strip())
        (HERE / "funding_carry.md").write_text(text, encoding="utf-8")
        print("wrote funding_carry.md")
    print(dev[keep].to_string())
    print(sel.to_string())


if __name__ == "__main__":
    main()
