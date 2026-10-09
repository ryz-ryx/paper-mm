"""Download 90 days of Hyperliquid hourly funding history and 1h candles for ALL perps (including delisted ones, to limit
survivorship bias). Public read-only info endpoint; no orders, no credentials. Resumable: finished coins are skipped.

Output: analysis/funding_data/<COIN>_funding.parquet, <COIN>_candles.parquet and manifest.json (fixes the window so the
backtest is reproducible).
"""
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

import pandas as pd

URL = "https://api.hyperliquid.xyz/info"
HERE = Path(__file__).resolve().parent
DATA = HERE / "funding_data"
DAY_MS = 86_400_000
HOUR_MS = 3_600_000
PACE_S = 0.5            # info requests carry weight >= 20 against a 1200/min budget; stay well under it


def post(body: dict, retries: int = 8):
    delay = 5.0
    for attempt in range(retries):
        try:
            req = urllib.request.Request(URL, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=60) as r:
                data = json.loads(r.read().decode())
            time.sleep(PACE_S)
            return data
        except urllib.error.HTTPError as e:
            if e.code == 429:
                print(f"  429 rate limited, sleeping {delay:.0f}s", flush=True)
            else:
                print(f"  HTTP {e.code}, retry in {delay:.0f}s", flush=True)
        except Exception as e:  # network hiccup
            print(f"  error {e!r}, retry in {delay:.0f}s", flush=True)
        time.sleep(delay)
        delay = min(delay * 2, 120.0)
    raise RuntimeError(f"giving up on {body}")


def fetch_funding(coin: str, start: int, end: int) -> pd.DataFrame:
    rows, cursor = [], start
    while cursor < end:
        chunk = post({"type": "fundingHistory", "coin": coin, "startTime": cursor, "endTime": end})
        if not chunk:
            break
        rows += chunk
        last = chunk[-1]["time"]
        if len(chunk) < 500 or last <= cursor:
            break
        cursor = last + 1
    df = pd.DataFrame(rows)
    if df.empty:
        return pd.DataFrame(columns=["time", "fundingRate", "premium"])
    df["fundingRate"] = df["fundingRate"].astype(float)
    df["premium"] = df["premium"].astype(float)
    return df.drop_duplicates("time").sort_values("time")[["time", "fundingRate", "premium"]].reset_index(drop=True)


def fetch_candles(coin: str, start: int, end: int) -> pd.DataFrame:
    rows, cursor = [], start
    while cursor < end:
        chunk = post({"type": "candleSnapshot", "req": {"coin": coin, "interval": "1h", "startTime": cursor, "endTime": end}})
        if not chunk:
            break
        rows += chunk
        last = chunk[-1]["t"]
        if len(chunk) < 4000 or last <= cursor:
            break
        cursor = last + 1
    df = pd.DataFrame(rows)
    if df.empty:
        return pd.DataFrame(columns=["t", "o", "h", "l", "c", "v", "n"])
    for c in ("o", "h", "l", "c", "v"):
        df[c] = df[c].astype(float)
    return df.drop_duplicates("t").sort_values("t")[["t", "o", "h", "l", "c", "v", "n"]].reset_index(drop=True)


def main():
    DATA.mkdir(exist_ok=True)
    mf = DATA / "manifest.json"
    meta = post({"type": "meta"})["universe"]
    if mf.exists():
        manifest = json.loads(mf.read_text())
    else:
        end = int(time.time() * 1000) // HOUR_MS * HOUR_MS
        manifest = {"end_ms": end, "start_ms": end - 90 * DAY_MS, "coins": {m["name"]: {"delisted": bool(m.get("isDelisted", False))} for m in meta}}
        mf.write_text(json.dumps(manifest, indent=1))
    start, end = manifest["start_ms"], manifest["end_ms"]
    coins = list(manifest["coins"])
    print(f"window {pd.to_datetime(start, unit='ms', utc=True)} .. {pd.to_datetime(end, unit='ms', utc=True)}; {len(coins)} perps", flush=True)
    for i, coin in enumerate(coins, 1):
        fpath, cpath = DATA / f"{coin.replace('/', '_')}_funding.parquet", DATA / f"{coin.replace('/', '_')}_candles.parquet"
        if fpath.exists() and cpath.exists():
            continue
        t0 = time.time()
        f = fetch_funding(coin, start, end)
        c = fetch_candles(coin, start, end)
        f.to_parquet(fpath)
        c.to_parquet(cpath)
        print(f"[{i}/{len(coins)}] {coin}: {len(f)} funding rows, {len(c)} candles ({time.time() - t0:.0f}s)", flush=True)
    print("done", flush=True)


if __name__ == "__main__":
    sys.exit(main())
