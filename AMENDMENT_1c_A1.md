# AMENDMENT_1c_A1.md
**Phase 1c Protocol Amendment A1 — Monday 2026-10-12**

---

### 1. Data Gaps: 2026-10-10 and Partial 2026-10-11
- **2026-10-10 (Saturday)**: Zero trades recorded due to bot inactivity / infrastructure gap during the weekend changeover.
- **2026-10-11 (Sunday)**: Partial gap prior to run resumption at 20:03 UTC. Full execution data recovered from artifact `11721888226` covering the continuation window through 2026-10-12 01:46 UTC.
- **Current Row Counts in `paper_mm2/data` (2026-10-09 through 2026-10-12)**:
  - `trades.csv`:
    - 2026-10-09: 2,755
    - 2026-10-10: 0
    - 2026-10-11: 4,147
    - 2026-10-12: 728
    - **Total: 7,630 rows**
  - `pending.csv`:
    - 2026-10-09: 13,605
    - 2026-10-10: 0
    - 2026-10-11: 21,265
    - 2026-10-12: 3,458
    - **Total: 38,328 rows**
  - `queue_depleted.csv`:
    - 2026-10-09: 1,780
    - 2026-10-10: 0
    - 2026-10-11: 2,940
    - 2026-10-12: 421
    - **Total: 5,141 rows**
  - `quotes.csv`:
    - 2026-10-09: 603,744
    - 2026-10-10: 0
    - 2026-10-11: 655,599
    - 2026-10-12: 125,984
    - **Total: 1,385,327 rows**

---

### 2. Hyperliquid Arm Under-Exercised Due to M4 Stale Cycling
- **Observation**:
  - Telemetry from `heartbeat.json` (2026-10-12T01:43:24Z) recorded:
    - Active quotes: Binance = 16, Hyperliquid = 0.
    - Total trades through: Binance = 1,874, Hyperliquid = 1,345.
    - Queue depleted fills: Binance = 1,822, Hyperliquid = 424.
  - Hyperliquid arm frequently drops active quotes to 0 due to condition M4 (`now_ms - last_book_update_ms > 2000` ms) triggering stale cycle cancellations (~3,796 stalls per run).
  - The Binance arm remains active with continuous book feeds, whereas Hyperliquid suffers systemic quote starvation.

---

### 3. Non-Engine Workflow & Bug Fixes
- **Item 1**: Added missing `import csv` in `paper_mm2/bot.py` for downtime logging.
  - **Commit**: `521ac51` (`fix(paper_mm2): add missing import csv for downtime logging`)
- **Item 2**: In `.github/workflows/paper_mm2.yml`, replaced brittle `git pull --rebase` with:
  `git fetch origin main && git rebase --autostash -X theirs origin/main && git push -q origin main`
  in both the 20-minute recurring loop and final state persistence step.
  - **Commit**: `088b5ee` (`fix(workflow): replace git pull --rebase with git fetch, rebase --autostash, and push`)

---

### 4. Item 3 Diagnosis Outcome: Upstream WS Throttling vs Event Loop Lag
A 10-minute (600.4s) WebSocket diagnostic capture of `wss://api.hyperliquid.xyz/ws` across the 8 universe coins (`BTC`, `ETH`, `SOL`, `kPEPE`, `PURR`, `WIF`, `DOGE`, `AVAX`) yielded:
- **Asyncio Event Loop Lag (ms)**:
  - Median: 12.14 ms
  - Mean: 11.74 ms
  - p90: 13.24 ms
  - p99: 14.70 ms
  - Max: 29.99 ms
  - **Conclusion**: The Python asyncio event loop is unblocked and operates well within sub-30ms performance thresholds. Disk I/O, sync calls, and subprocesses are not blocking the loop.
- **Hyperliquid `l2Book` Inter-Arrival Time (seconds)**:
  - Total `l2Book` messages: 904 across 600.4 seconds.
  - Median inter-arrival: 0.0000 s (batch arrivals across coins)
  - Mean inter-arrival: 0.6627 s
  - p90: 5.2714 s
  - p95: 5.3961 s
  - p99: 5.5212 s
  - Max: 5.7800 s
  - **Distribution**:
    - `[0.0s - 0.1s)`: 787 (87.2%)
    - `[5.0s - 5.5s)`: 97 (10.7%)
    - `[5.5s - 6.0s)`: 13 (1.4%)
- **Root Cause**: Upstream Hyperliquid L2 book channel server-side batches/pushes updates on quiet instruments on a ~5.3 second cycle. Because condition M4 enforces a strict 2.0s freshness threshold (`now_ms - last_book_update_ms > 2000`), every ~5.3s update gap triggers M4 stale book state, cancelling and preventing HL quotes.
- **Engine Logic Policy**:
  - In accordance with Phase 1c rules, **NO engine modifications are made at this time**.
  - If an engine adjustment to the HL stale threshold is sanctioned, a new code-version epoch will be established, and the Hyperliquid hold-out period start will align with that epoch start.
  - The Binance hold-out window remains unchanged: **2026-10-13 through 2026-10-18**.
