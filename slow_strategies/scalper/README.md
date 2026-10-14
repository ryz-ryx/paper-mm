# MT5 M1 Breakout Confirmatory Scalper Harness (per PREREG v1.05)

This directory contains the production-grade implementation of the MT5 M1 Breakout Confirmatory Demo Scalper, strictly adhering to the pre-registration specification defined in [PREREG.md](file:///C:/Users/Abdul%20Qhahhar/Documents/scalper_wt/slow_strategies/scalper/PREREG.md) (`v1.05`).

---

## 1. Directory Structure & Files

| File | Type | Purpose |
| :--- | :--- | :--- |
| `ScalperEA.mq5` | MQL5 Expert Advisor | Primary trading engine trading `EURUSD` and `USDJPY` on M1. |
| `SpreadLog.mq5` | MQL5 Expert Advisor | Passive pre-start spread & tick telemetry logger (§3.3). Zero orders. |
| `summary.py` | Python Script | Ingests `spread_log.csv` and computes parameters for `ACCOUNT.md`. |
| `analyze.py` | Python Script | Evaluates confirmatory roundtrips against PREREG §4 & §5 statistical criteria. |
| `test_analyze.py`| Python Test Suite | Unit test suite for `analyze.py` and `summary.py` covering HIT, MISS, burn-in, fidelity, zero-spread filtering, and tick age shares. |
| `PREREG.md` | Markdown Specification| Scientific pre-registration document (v1.05). |
| `ACCOUNT.md` | Markdown Specification| Account environment, pre-start spread baseline, and timeline manifest. |

---

## 2. Compilation Instructions

Compile the MQL5 source files using the MetaEditor 64-bit compiler (`metaeditor64.exe`):

```powershell
# Compile Primary Scalper EA
& "C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"slow_strategies\scalper\ScalperEA.mq5" /log:"slow_strategies\scalper\compile_scalper.log"

# Compile Pre-Start Spread Logger
& "C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"slow_strategies\scalper\SpreadLog.mq5" /log:"slow_strategies\scalper\compile_spreadlog.log"
```

Verify `compile_scalper.log` and `compile_spreadlog.log` report `0 errors, 0 warnings`.

---

## 3. Operational Workflow

### Phase 1: Pre-Start Spread Measurement (PREREG §3.3)
1. Attach `SpreadLog.ex5` to any chart in the target demo MT5 terminal.
2. Let it run for 5 consecutive trading days (Monday–Friday) during the session window (`07:00:00 - 16:00:00 UTC`).
3. Telemetry is appended to `%APPDATA%\MetaQuotes\Terminal\Common\Files\spread_log.csv`.
4. Run `summary.py` to calculate the 60th percentile, mean, spread gates, zero-spread share, and tick age shares:
   ```bash
   python slow_strategies/scalper/summary.py --csv "%APPDATA%\MetaQuotes\Terminal\Common\Files\spread_log.csv"
   ```
5. Paste the generated metrics into `ACCOUNT.md` Section 3.

### Phase 2: Plumbing Mode Verification (Non-Evidential)
1. Run `ScalperEA.ex5` with `InpEvidential = false`.
2. The EA logs `[PLUMBING MODE - NON-EVIDENTIAL]` at initialization.
3. Every executed trade is flagged with `evidential = 0` in CSV logs.
4. Verify broker order dispatch, SL/TP modification (+/-5.0 pips), 300 s time stop, and CSV logging in `Common\Files`.

### Phase 3: Freezing & Evidential Execution
1. Complete all REQUIRED fields in `ACCOUNT.md` (server, login, starting balance, timeline, spread results, news calendar hash).
2. Commit `ACCOUNT.md` to git and record its commit SHA and file SHA256.
3. Tag the repository: `git tag scalper-prereg-v1`.
4. Launch `ScalperEA.ex5` with:
   - `InpEvidential = true`
   - `InpExpectedServer = "<Target Broker Server>"`
   - `InpExpectedLogin = <Target Demo Login>`
   - `InpAccountMdSha256 = "<SHA256 of committed ACCOUNT.md>"`
   - `InpGateEURUSD = <EURUSD Spread Gate>`
   - `InpGateUSDJPY = <USDJPY Spread Gate>`
   - `InpNewsFile = "news_calendar.csv"`
5. The EA verifies account parameters and logs `[EVIDENTIAL OK]`. All rows get `evidential = 1`.

### Phase 4: Final Confirmatory Analysis
Once data collection reaches 1,000 evidential trades (100 burn-in + 900 confirmatory evaluation):
```bash
python slow_strategies/scalper/analyze.py \
    --csv "%APPDATA%\MetaQuotes\Terminal\Common\Files\roundtrips.csv" \
    --s-pretest-eurusd <EURUSD_S_pre-test> \
    --s-pretest-usdjpy <USDJPY_S_pre-test>
```

---

## 4. Input Parameters Reference (`ScalperEA.mq5`)

| Parameter | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `InpEvidential` | bool | `false` | Set to `true` strictly for confirmatory evaluation runs. |
| `InpExpectedServer` | string | `""` | Enforces exact broker server name match in evidential mode. |
| `InpExpectedLogin` | long | `0` | Enforces exact account login match in evidential mode. |
| `InpAccountMdSha256` | string | `""` | Cryptographic SHA256 checksum of committed `ACCOUNT.md`. |
| `InpGateEURUSD` | double | `0.3` | Dynamic spread gate for EURUSD in pips (from `ACCOUNT.md`). |
| `InpGateUSDJPY` | double | `0.3` | Dynamic spread gate for USDJPY in pips (from `ACCOUNT.md`). |
| `InpNewsFile` | string | `news_calendar.csv` | Path in `Common\Files` containing high-impact economic calendar. |
| `InpMagic` | ulong | `20261014` | Fixed magic number identifier. |
| `InpPollIntervalMs` | int | `50` | Polling loop frequency in milliseconds. |

---

## 5. Requirement-to-Code Mapping Table

Every requirement from PREREG.md v1.05 Sections 2, 3, 5.2, and 6 maps directly to an explicit implementation in `ScalperEA.mq5`, `SpreadLog.mq5`, or `summary.py`:

| PREREG Section | Requirement Description | Implementation Function / Location |
| :--- | :--- | :--- |
| **§2.1** | Symbols `EURUSD`, `USDJPY` | `g_symbols` array, MarketWatch selection in `ScalperEA.mq5` |
| **§2.1** | Lot size strictly `0.01` lot | Constant `MAX_VOLUME = 0.01` in `ScalperEA.mq5` |
| **§2.1** | Concurrency: One open position globally | Global state check, first signal wins in `ScalperEA.mq5` |
| **§2.1** | Market orders only (`DEAL`), no pending orders | `m_trade.Buy()`, `m_trade.Sell()` with `TRADE_ACTION_DEAL` in `ScalperEA.mq5` |
| **§2.2** | Timeframe M1 bar close | `PERIOD_M1` rates retrieval and bar boundary check in `ScalperEA.mq5` |
| **§2.2** | Channel lookback: 20 completed bars preceding bar 1 | `CheckBreakoutSignal()` lookback loop `b=1..20` over bars 2 to 21 in `ScalperEA.mq5` |
| **§2.2** | Breakout trigger rules ($C_{t-1} > \max H$, $C_{t-1} < \min L$) | `CheckBreakoutSignal()` threshold comparisons in `ScalperEA.mq5` |
| **§2.2** | Throttling: 1 order per 5-min window globally | `curWindowId = TimeGMT() / 300`, check vs `g_lastDispatchedWindowId` |
| **§2.3.1** | Spread gate filter at signal and dispatch | `spreadPips <= gate` check in dispatch pre-flight in `ScalperEA.mq5` |
| **§2.3.2** | Tick freshness connectivity rule ($\le 3000$ ms) | Named constant `TICK_MAX_AGE_MS = 3000.0`, checked at signal time and dispatch |
| **§2.3.3** | Session window `07:00:00 - 16:00:00 UTC` Mon-Fri | `IsInSession()` using `TimeGMT()` in `ScalperEA.mq5` and `SpreadLog.mq5` |
| **§2.3.4** | News exclusion +/-10 min from committed calendar | `IsNewsBlocked()` scanning `InpNewsFile` in `Common\Files` in `ScalperEA.mq5` |
| **§2.3.4** | Degraded news fallback (`12:25-12:40`, `13:25-13:40 UTC`) | `IsNewsBlocked()` degraded fallback branch with log in `ScalperEA.mq5` |
| **§2.4** | Take-Profit (+5.0 pips from fill price) | `PositionModify()` setting `tp = fillPrice + 5.0 * pip` in `ScalperEA.mq5` |
| **§2.4** | Stop-Loss (-5.0 pips from fill price) | `PositionModify()` setting `sl = fillPrice - 5.0 * pip` in `ScalperEA.mq5` |
| **§2.4** | Time stop: Close at market after 300 s | `MonitorPosition()` checking `elapsedSec >= TIME_STOP_SEC` in `ScalperEA.mq5` |
| **§2.4** | Exit reason classification | `MonitorPosition()` reading `DEAL_REASON` and comment in `ScalperEA.mq5` |
| **§2.5** | Net PnL = gross pips - $2 \times \text{commission\_pips}$ | `netPips = grossPips - 2.0 * g_posCommissionPips` in `ScalperEA.mq5` |
| **§2.5** | Millisecond execution timestamps | `g_signalTimeMsc`, `g_dispatchTimeMsc`, `g_fillTimeMsc` via tick/deal millisecond clocks |
| **§3.3** | Pre-start spread & tick logging (`SpreadLog.mq5`) | Logs `spread_pips`, `zero_spread`, `tick_age_ms`, `ticks_prev_60s` |
| **§3.3** | Zero-spread exclusion & tick age reporting (`summary.py`) | Excludes spread $\le 0$ from percentile/mean; reports zero share and tick age shares |
| **§3.4** | Commission accounting from deal history | `CommissionToPips()` reads `deal.commission` via `HistoryDealGetDouble` per fill |
| **§5.2** | Instance lock (one EA per terminal) | `InstanceKey()`, `GV_INSTANCE_LOCK` acquisition in `ScalperEA.mq5` |
| **§5.2** | State persistence & `GlobalVariablesFlush` | `GvSet()`, `GvDel()`, `GvBegin()`, `GvEnd()` in `ScalperEA.mq5` |
| **§5.2** | Restart recovery: restore live position & hold clock | `OnInit()` restoring `g_posTicket`, `g_posOpenServerTime` in `ScalperEA.mq5` |
| **§5.2** | Restart recovery: reconcile offline closed position | `OnInit()` calling `HandlePositionClosed(..., restart=1)` in `ScalperEA.mq5` |
| **§6.1** | Volume cap: max 20 trades/day/symbol | `tradesToday >= MAX_TRADES_DAY` signal drop in `ScalperEA.mq5` |
| **§6.2** | Daily loss stop: -30 pips cumulative net per day | `g_dailyNetPips <= DAILY_LOSS_STOP` triggering `STATE_HALTED` in `ScalperEA.mq5` |
| **§6.2** | Daily reset at 00:00 UTC | `CheckDailyReset()` resetting counters & daily PnL in `ScalperEA.mq5` |
| **§6.3** | Consecutive error breaker: 5 errors -> halt | `g_consecutiveErrors >= MAX_CONSEC_ERRS` -> `STATE_HALTED` in `ScalperEA.mq5` |
| **§6.4** | External kill switch file (`kill_switch.txt`) | `CheckKillSwitch()` checking `Common\Files\kill_switch.txt` in `ScalperEA.mq5` |

---

## 6. Testing & Static Verification

Run the Python unit test suite:

```bash
python -m pytest slow_strategies/scalper/test_analyze.py -v
```

All unit tests execute synthetically without external dependencies or MT5 connectivity.
