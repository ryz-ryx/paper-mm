# MT5 ExecTest v2.10 Smoke Test Validation Report

- **Date / Time**: 2026-10-14
- **Harness Commit**: `c90f774c0b92de60f27b7fa047edac6eae0d534e`
- **ExecTest.mq5 Blob SHA1**: `e38465857daf5bdd5fcb026a1c128066eaa6f858`
- **run_smoke_tests.ps1 Blob SHA1**: `a1a13a9d7bddec05ab800f74f5d5641afd1031af`
- **Environment**: MetaTrader 5 x64 build 6253, MetaQuotes-Demo Synthetic Feed (Account 10013076140)

---

## 1. Executive Summary & Verdict Table

The verdict for each test corresponds to the latest valid run containing that test:
- **Run 3** (`smoke_results_20261014_085425.json`, full attended run ~08:54-09:20 CEST / 06:54-07:20 UTC): provides verdicts for **T1**, **T2**, **T3A**, **T3B**, **T4**, and **T5B**.
- **Rerun** (`smoke_results_20261014_101555.json`, targeted rerun ~10:15-10:20 CEST / 08:15-08:20 UTC): provides verdicts for **T5A** and **T6**.

| Test | Description | Verdict | Summary | Source Result File |
| :--- | :--- | :---: | :--- | :--- |
| **T1** | Close Reject Backoff (k=1..6) | **PASS** | 20/20 checks passed in 83s | `smoke_results_20261014_085425.json` |
| **T2** | Orphan External Close Detection | **PASS** | 14/14 checks passed in 9s | `smoke_results_20261014_085425.json` |
| **T3A** | In-Flight Timeout Fill Reconciliation | **PASS** | 13/13 checks passed in 190s | `smoke_results_20261014_085425.json` |
| **T3B** | Timeout Unfilled Cancellation | **NOT TESTABLE** | OrderSend executes; unfilled variant not testable under code freeze | `smoke_results_20261014_085425.json` |
| **T4** | Daily Order Cap & Skip Logic | **PASS** | 12/12 checks passed in 444s | `smoke_results_20261014_085425.json` |
| **T5A** | Equity Stop Gate (Seeded Baseline) | **PASS** | 22/22 checks passed in 67s | `smoke_results_20261014_101555.json` |
| **T5B** | Equity Stop Post-Close Drawdown | **CONDITIONAL (drawdown stop never triggered: 2 of 3 attempts closed without crossing InpMaxDrawdownEUR; timed out after 600s)** | 10/10 checks passed in 600s | `smoke_results_20261014_085425.json` |
| **T6** | Mid-Hold Crash Recovery (taskkill /f) | **PASS** | 18/18 checks passed in 188s | `smoke_results_20261014_101555.json` |

### Superseded results in the run-3 file

The earlier full attended run file (`smoke_results_20261014_085425.json`) also contains:
- **T5A = INVALID**: The baseline seed verification check read the terminal Experts log with an off-by-one line cut in the harness; the seed script execution itself was OK (`[SEED BASELINE] OK equity=1000.70 baseline=1005.70 offset=5.00 date_utc=1791936000`).
- **T6 = 17/18**: The kill-time `gvariables.dat` file snapshot was not observed in the harness due to timing of the process exit poll; all actual crash recovery checks passed cleanly.

Both issues were harness-side monitoring timing/slicing defects and were resolved in harness commit `c90f774c0b92de60f27b7fa047edac6eae0d534e`. The EA code was unchanged (`ExecTest.mq5` blob `e38465857daf5bdd5fcb026a1c128066eaa6f858`). Both tests were subsequently rerun in `smoke_results_20261014_101555.json` and passed cleanly (T5A 22/22, T6 18/18).

---

## 2. Broker Execution & Round-Trip Broker Latency (RTT) Statistics

> [!NOTE]
> **FEED NOTICE**: All execution latency metrics below reflect execution against the **MetaQuotes-Demo synthetic feed**, not live market venue execution. No assertion of live execution quality or trading edge is implied.

Latency is measured at microsecond resolution (`latency_roundtrip_us` / `entry_rtt_us` / `exit_rtt_us`) across all executed market deals.

### 2.1 Today's Active Smoke Runs (2026-10-14)

| Dataset | Metric | N | Min (ms) | Median (ms) | P95 (ms) | Max (ms) |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| `trades.csv` | BUY Market Fill RTT | 6 | 24.47 | 29.47 | 79.06 | 88.39 |
| `trades.csv` | SELL Market Fill RTT | 5 | 23.95 | 48.61 | 236.07 | 280.70 |
| `roundtrips.csv` | Entry Broker RTT | 7 | 24.93 | 51.07 | 86.72 | 88.39 |
| `roundtrips.csv` | Exit Broker RTT | 7 | 23.95 | 48.61 | 214.22 | 280.70 |

### 2.2 Aggregate Dataset across All Recorded Runs

| Dataset | Metric | N | Min (ms) | Median (ms) | P95 (ms) | Max (ms) |
| :--- | :--- | :---: | :---: | :---: | :---: | :---: |
| `trades.csv` | BUY Market Fill RTT | 15 | 23.93 | 39.66 | 122.38 | 142.78 |
| `trades.csv` | SELL Market Fill RTT | 13 | 23.57 | 48.06 | 287.61 | 297.98 |
| `roundtrips.csv` | Entry Broker RTT | 16 | 23.93 | 67.49 | 136.66 | 142.78 |
| `roundtrips.csv` | Exit Broker RTT | 16 | 23.57 | 48.34 | 285.02 | 297.98 |

---

## 3. Comprehensive Per-Test Evidence Verification

### T1: Test 1 (Close Reject 6)
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **PASS**
- **Summary**: 20/20 checks passed in 83s
- **Stale Tick Backoff Events**: None (0 backoffs)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `1` | `1` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `6` | `6` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| Entry dispatches (EA [ORDER SENT] BUY) | `1` | `1` | PASS |
| Entry dispatches (journal market buy) | `1` | `1` | PASS |
| close_failure rows tagged fault_injection | `6` | `6` | PASS |
| [EXIT RETRY] lines (attempts 1-4) | `4` | `4` | PASS |
| [CRITICAL] EA Print lines (attempts >= 5) | `2` | `2` | PASS |
| Alert: [CRITICAL] echoes (every 5th failure) | `1` | `1` | PASS |
| Exactly one exit dispatch (EA [ORDER SENT] SELL) | `1` | `1` | PASS |
| Exactly one exit dispatch (journal market sell) | `1` | `1` | PASS |
| [HOLD EXPIRED] logged | `1` | `1` | PASS |
| Zero [ORPHAN DETECTED] | `0` | `0` | PASS |
| Exactly one roundtrip row with restart=False | `1, False` | `1, False` | PASS |
| First reject -> successful close (s), nominal 12750 ms | `12.638-13.458` | `12.807` | PASS |
| Reject-to-reject gaps match b(1..N-1) | `0 violations` | `0 violations` | PASS |

### T2: Test 2 (External Close)
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **PASS**
- **Summary**: 14/14 checks passed in 9s
- **Stale Tick Backoff Events**: None (0 backoffs)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `1` | `1` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| Entry dispatches (EA [ORDER SENT] BUY) | `1` | `1` | PASS |
| Entry dispatches (journal market buy) | `1` | `1` | PASS |
| [EXTERNAL CLOSE DETECTED] logged | `>=0 index` | `14` | PASS |
| Strict transition to STATE_IDLE after the external close | `index > 14` | `17` | PASS |
| orphan_external_close rows in skips.csv | `1` | `1` | PASS |
| EA sent no close of its own ([ORDER SENT] SELL) | `0` | `0` | PASS |
| External close visible in journal (market sell) | `>=1` | `1` | PASS |

### T3A: Test 3A (Timeout Filled)
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **PASS**
- **Summary**: 13/13 checks passed in 190s
- **Stale Tick Backoff Events**: None (0 backoffs)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `1` | `1` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `1` | `1` | PASS |
| Entry dispatches (EA [ORDER SENT] BUY) | `1` | `1` | PASS |
| Entry dispatches (journal market buy) | `1` | `1` | PASS |
| Reconciliation confirmed the fill | `1` | `1` | PASS |
| Exactly one BUY row (reconcile_entry_fill) | `1, 1` | `1, 1` | PASS |
| Exactly one exit dispatch (EA [ORDER SENT] SELL) | `1` | `1` | PASS |
| Exactly one roundtrip row | `1` | `1` | PASS |

### T3B: Test 3B (Timeout Unfilled)
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **NOT TESTABLE**
- **Summary**: OrderSend executes; unfilled variant not testable under code freeze
- **Stale Tick Backoff Events**: N/A

*No individual check criteria evaluated (variant not testable under code freeze).*

### T4: Test 4 (Daily Cap 1)
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **PASS**
- **Summary**: 12/12 checks passed in 444s
- **Stale Tick Backoff Events**: 1 backoff(s) encountered (120s retry each)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `1` | `1` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| Entry dispatches (EA [ORDER SENT] BUY) | `1` | `1` | PASS |
| Entry dispatches (journal market buy) | `1` | `1` | PASS |
| Daily limit gate logged | `>=1` | `2` | PASS |
| Exactly one exit dispatch (EA [ORDER SENT] SELL) | `1` | `1` | PASS |
| Exactly one roundtrip row | `1` | `1` | PASS |

### T5A: Test 5A (Equity Stop (seeded baseline, entry gate))
- **Source Result File**: `smoke_results_20261014_101555.json`
- **Verdict**: **PASS**
- **Summary**: 22/22 checks passed in 67s
- **Stale Tick Backoff Events**: None (0 backoffs)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `0` | `0` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| Entry dispatches (EA [ORDER SENT] BUY) | `0` | `0` | PASS |
| Entry dispatches (journal market buy) | `0` | `0` | PASS |
| Seed marker file written | `present` | `present` | PASS |
| Seed marker status | `OK` | `OK` | PASS |
| Seed baseline parses | `number` | `1005.78` | PASS |
| Seed readback equity == baseline | `1005.78` | `1005.78` | PASS |
| Seed date_utc == today's UTC midnight | `1791936000` | `1791936000` | PASS |
| Seed readback date == today's UTC midnight | `1791936000` | `1791936000` | PASS |
| No ExecTest init during the script-only seed launch | `False` | `False` | PASS |
| Seed launch placed no orders (journal) | `0` | `0` | PASS |
| Seed launch stopped gracefully (GVs written by the terminal) | `graceful` | `graceful` | PASS |
| EA loaded the seeded baseline | `1005.78 EUR` | `1005.78 EUR` | PASS |
| STATE_HALTED with reason 'Equity drop' | `>=1` | `1` | PASS |
| No entry dispatch after the halt | `0` | `0` | PASS |
| No BUY rows in trades.csv | `0` | `0` | PASS |

### T5B: Test 5B (Equity Stop (drawdown after a close, market-dependent))
- **Source Result File**: `smoke_results_20261014_085425.json`
- **Verdict**: **CONDITIONAL (drawdown stop never triggered: 2 of 3 attempts closed without crossing InpMaxDrawdownEUR; timed out after 600s)**
- **Summary**: 10/10 checks passed in 600s
- **Stale Tick Backoff Events**: 2 backoff(s) encountered (120s retry each)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `1` | `1` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| Entry dispatches agree (EA tag vs journal) | `2` | `2` | PASS |
| Entries <= 3 attempts | `<= 3` | `2` | PASS |
| Every entry was closed ([EXIT CONFIRMED] == entries) | `2` | `2` | PASS |

### T6: Test 6 (Mid-Hold Restart)
- **Source Result File**: `smoke_results_20261014_101555.json`
- **Verdict**: **PASS**
- **Summary**: 18/18 checks passed in 188s
- **Stale Tick Backoff Events**: None (0 backoffs)

| Check | Expected | Observed | Status |
| :--- | :--- | :--- | :---: |
| No duplicate EA instance refused | `0` | `0` | PASS |
| No OnTimer stall > 1 s | `0` | `0` | PASS |
| No log/CSV read errors | `0` | `0` | PASS |
| Final open positions | `0` | `0` | PASS |
| [STATE RESET] Cleared lines == preset InpResetState | `0` | `0` | PASS |
| Injected close rejects == preset InpInjectCloseReject | `0` | `0` | PASS |
| Injected timeouts == preset InpInjectTimeout | `0` | `0` | PASS |
| No [STATE RESET] line (restart.set InpResetState=false) | `0` | `0` | PASS |
| [RESTART RECOVERY] emitted | `>=1` | `1` | PASS |
| Zero [ORPHAN DETECTED] | `0` | `0` | PASS |
| Recovery saw prior state STATE_IN_POSITION | `>=1` | `1` | PASS |
| Exactly one entry (distinct ticket: recovery / EA BUY / helper) | `1` | `1 (recovery=[152762082161] ea_buy=[] helper=[152762082161])` | PASS |
| Journal shows at most one entry | `<= 1` | `0` | PASS |
| No entry dispatch after recovery | `0` | `0` | PASS |
| Exactly one exit dispatch after recovery | `1` | `1` | PASS |
| Relaunch not blocked by stale instance lock | `0` | `0` | PASS |
| Relaunch acquired the lock fresh (previous: none) | `1` | `1` | PASS |
| gvariables.dat non-empty while the terminal was down (GlobalVariablesFlush) | `>0 B (kill-time capture)` | `kill-time 4057 B mtime 10:19:31.571 @ 10:19:51.768 (exit 10:19:51.734, lag 59 ms, terminal down: True); poll 4057 B mtime 10:19:31.571 @ 10:19:51.808; before 1592 B mtime 10:17:26.336; end 1592 B mtime 10:20:31.658` | PASS |

---

## 4. Limitations

The test harness, execution environment, and EA implementation operate subject to the following documented constraints:

1. **timestamp_utc label off by up to 1 s**: UTC timestamps assigned to CSV events use a combination of server second and local microsecond timer, which can display an offset of up to 1 second relative to true UTC wall time.
2. **BUY row lost if process is killed mid-hold (roundtrip row carries entry fields)**: In a hard process termination (`taskkill /f`), buffered trade events waiting for disk flush in memory are dropped; however, persisted global variables ensure the subsequent roundtrip row fully reconstructs all entry prices, timestamps, and metrics upon position exit.
3. **external-close skip row has close_price=0.00000 and close_time=1970.01.01**: When an external close occurs, the history deal lookup filters specifically on the EA's magic number (20261009); because the external helper script dispatches deals under manual intervention magic 99999999, the internal lookup does not select the deal, logging zero/epoch fallback fields in the skip record.
4. **entries sparse (stale_tick >500 ms and zero-spread gates, 120 s backoff; ~53% zero-spread EURUSD ticks on the demo feed)**: Entry filters strictly discard stale quotes and non-positive spreads, enforcing an automatic 120-second backoff penalty upon every violation; on the MetaQuotes-Demo feed, zero-spread quotes occur on approximately 53% of EURUSD ticks, leading to extended holding periods in `STATE_IDLE`.
5. **demo feed synthetic**: All quotes, spread variations, order fills, and backoff timings were recorded against a simulated demo server environment; latency characteristics and fill distributions do not represent live ECN/STP execution venues.
6. **T3B not testable under code freeze**: Simulating an indeterminate entry timeout that results in an unfulfilled broker order requires fault injection prior to order dispatch; under the frozen codebase rules, `InpInjectTimeout` routes immediately to reconciliation where active broker fills occur.
7. **T5B market-dependent**: Verifying an equity drawdown stop following a clean position exit requires the market to generate unfavorable price action exceeding `InpMaxDrawdownEUR`; under favorable price moves where trades close with net positive PnL, drawdown is not crossed.

---

## 5. Conclusion

ExecTest EA v2.10 and harness commit `c90f774` stand validated on all testable deterministic and recovery paths, achieving clean passes across all state machine transitions, exponential backoff retries, orphan closures, and mid-hold crash recoveries. This suite constitutes a probe smoke validation only, and establishes no claim regarding live execution quality or quantitative trading edge.
