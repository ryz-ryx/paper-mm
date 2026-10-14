# MT5 M1 Breakout Confirmatory Scalper Harness

This directory contains the production-grade implementation of the MT5 M1 Breakout Confirmatory Demo Scalper, strictly adhering to the pre-registration specification defined in [PREREG.md](file:///C:/Users/Abdul%20Qhahhar/Documents/mt5_exec_test_wt/slow_strategies/scalper/PREREG.md) (`v1.02`).

---

## 1. Directory Structure & Files

| File | Type | Purpose |
| :--- | :--- | :--- |
| `ScalperEA.mq5` | MQL5 Expert Advisor | Primary trading engine trading `EURUSD` and `USDJPY` on M1. |
| `SpreadLog.mq5` | MQL5 Expert Advisor | Passive pre-start spread telemetry logger (§3.3). Zero orders. |
| `summary.py` | Python Script | Ingests `spread_log.csv` and computes parameters for `ACCOUNT.md`. |
| `analyze.py` | Python Script | Evaluates confirmatory roundtrips against PREREG §4 & §5 statistical criteria. |
| `test_analyze.py`| Python Test Suite | Unit test suite for `analyze.py` covering HIT, MISS, burn-in, and fidelity. |
| `PREREG.md` | Markdown Specification| Scientific pre-registration document (v1.02). |
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
4. Run `summary.py` to calculate the 60th percentile, mean, and spread gates:
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

Every requirement from PREREG.md v1.02 Sections 2, 5.2, and 6 maps directly to an explicit implementation in `ScalperEA.mq5`:

| PREREG Section | Requirement Description | Implementation Function / Location in `ScalperEA.mq5` |
| :--- | :--- | :--- |
| **§2.1** | Symbols `EURUSD`, `USDJPY` | `g_symbols` array (line 116), MarketWatch selection (lines 852-859) |
| **§2.1** | Lot size strictly `0.01` lot | Constant `MAX_VOLUME = 0.01` (line 20), used in orders (lines 510, 512) |
| **§2.1** | Concurrency: One open position globally | Global state check (lines 957-961), first signal wins break (line 1011) |
| **§2.1** | Market orders only (`DEAL`), no pending orders | `m_trade.Buy()`, `m_trade.Sell()` with `TRADE_ACTION_DEAL` (lines 509-512) |
| **§2.2** | Timeframe M1 bar close | `PERIOD_M1` rates retrieval and bar boundary check (lines 381, 991-995) |
| **§2.2** | Channel lookback: 20 completed bars preceding bar 1 | `CheckBreakoutSignal()` lookback loop `b=1..20` over bars 2 to 21 (lines 380-395) |
| **§2.2** | Breakout trigger rules ($C_{t-1} > \max H$, $C_{t-1} < \min L$) | `CheckBreakoutSignal()` threshold comparisons (lines 400-409) |
| **§2.2** | Throttling: 1 order per 5-min window globally | `curWindowId = TimeGMT() / 300`, check vs `g_lastDispatchedWindowId` (lines 975-976) |
| **§2.3.1** | Spread gate filter at signal and dispatch | `spreadPips <= gate` check in dispatch pre-flight (lines 475, 490-494) |
| **§2.3.2** | Tick staleness filter ($\le 500$ ms) | `GetTickAgeMs()` measurement and check (lines 365-369, 474, 478-482) |
| **§2.3.3** | Session window `07:00:00 - 16:00:00 UTC` Mon-Fri | `IsInSession()` using `TimeGMT()` (lines 268-275, 971-972) |
| **§2.3.4** | News exclusion +/-10 min from committed calendar | `IsNewsBlocked()` scanning `InpNewsFile` in `Common\Files` (lines 280-310, 988) |
| **§2.3.4** | Degraded news fallback (`12:25-12:40`, `13:25-13:40 UTC`) | `IsNewsBlocked()` degraded fallback branch with log (lines 312-325) |
| **§2.4** | Take-Profit (+5.0 pips from fill price) | `PositionModify()` setting `tp = fillPrice + 5.0 * pip` (lines 612-625) |
| **§2.4** | Stop-Loss (-5.0 pips from fill price) | `PositionModify()` setting `sl = fillPrice - 5.0 * pip` (lines 612-625) |
| **§2.4** | Time stop: Close at market after 300 s | `MonitorPosition()` checking `elapsedSec >= TIME_STOP_SEC` (lines 714-732) |
| **§2.4** | Exit reason classification | `MonitorPosition()` reading `DEAL_REASON` and comment (lines 748-768) |
| **§2.5** | Net PnL = gross pips - $2 \times \text{commission\_pips}$ | `netPips = grossPips - 2.0 * g_posCommissionPips` (lines 638-644) |
| **§2.5** | Telemetry logging (`signal_price`, `slippage_pips`, etc.) | `trades.csv` (lines 604-609), `roundtrips.csv` (lines 672-678) |
| **§5.2** | Instance lock (one EA per terminal) | `InstanceKey()`, `GV_INSTANCE_LOCK` acquisition (lines 78-79, 168-182, 781-802) |
| **§5.2** | State persistence & `GlobalVariablesFlush` | `GvSet()`, `GvDel()`, `GvBegin()`, `GvEnd()` (lines 134-163, 584-601, 652-669) |
| **§5.2** | Restart recovery: restore live position & hold clock | `OnInit()` restoring `g_posTicket`, `g_posOpenServerTime` (lines 875-899) |
| **§5.2** | Restart recovery: reconcile offline closed position | `OnInit()` calling `HandlePositionClosed(..., restart=1)` (lines 900-912) |
| **§6.1** | Volume cap: max 20 trades/day/symbol | `tradesToday >= MAX_TRADES_DAY` signal drop (lines 27, 984-985) |
| **§6.2** | Daily loss stop: -30 pips cumulative net per day | `g_dailyNetPips <= DAILY_LOSS_STOP` triggering `STATE_HALTED` (lines 26, 689-695) |
| **§6.2** | Daily reset at 00:00 UTC | `CheckDailyReset()` resetting counters & daily PnL (lines 431-460, 948) |
| **§6.3** | Consecutive error breaker: 5 errors -> halt | `g_consecutiveErrors >= MAX_CONSEC_ERRS` -> `STATE_HALTED` (lines 25, 518-543) |
| **§6.4** | External kill switch file (`kill_switch.txt`) | `CheckKillSwitch()` checking `Common\Files\kill_switch.txt` (lines 330-344, 945) |

---

## 6. Testing & Static Verification

Run the Python unit test suite:

```bash
python -m pytest slow_strategies/scalper/test_analyze.py -v
```

All unit tests execute synthetically without external dependencies or MT5 connectivity.
