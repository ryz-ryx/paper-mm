# MT5 ExecTest v2.10 Smoke Test Validation Report - IC Markets EU Demo

- **Date / Time**: 2026-10-14
- **Companion report**: `smoke_report_20261014.md` (MetaQuotes-Demo, harness `c90f774c0b92de60f27b7fa047edac6eae0d534e`). That report is unchanged; this one covers the IC Markets EU demo account only.
- **Account**: IC Markets (EU) Ltd, server `ICMarketsEU-Demo`, login 53098320, USD, demo, Raw Spread, hedging, leverage 1:30
- **Platform**: MetaTrader 5 x64 (build as stated in the companion report; not re-recorded here)
- **ExecTest.mq5 Blob SHA1**: `e38465857daf5bdd5fcb026a1c128066eaa6f858` (identical to the MetaQuotes-Demo report; EA code unchanged)
- **Harness (rerun)**: commit `879abae36dc6cf814f255759ce7db1055074afa4`, `run_smoke_tests.ps1` blob `1f2552d1edde7838897e5fbaca0c3e43fbaa5e45`
- **Overall IC verdict**: **PASS**

---

## 1. Requirement and Consolidated Verdict

Requirement: T1, T2, T3A, T4, T5A and T6 PASS, and T5B PASS or CONDITIONAL, on this account. T3B is NOT TESTABLE (code freeze) and does not count toward the verdict, exactly as in the MetaQuotes-Demo report.

| Test | Description | Verdict | Checks | Duration | Source Result File |
| :--- | :--- | :---: | :---: | :---: | :--- |
| **T1** | Close Reject Backoff (k=1..6) | **PASS** | 20/20 | 327s | `smoke_results_20261014_134647.json` (rerun) |
| **T2** | Orphan External Close Detection | **PASS** | 14/14 | 251s | `smoke_results_20261014_134647.json` (rerun) |
| **T3A** | In-Flight Timeout Fill Reconciliation | **PASS** | 13/13 | 550s | `smoke_results_20261014_114935.json` (first run) |
| **T3B** | Timeout Unfilled Cancellation | **NOT TESTABLE** | n/a | n/a | not counted |
| **T4** | Daily Order Cap & Skip Logic | **PASS** | 12/12 | 207s | `smoke_results_20261014_134647.json` (rerun) |
| **T5A** | Equity Stop Gate (Seeded Baseline) | **PASS** | 22/22 | 28s | `smoke_results_20261014_114935.json` (first run) |
| **T5B** | Equity Stop Post-Close Drawdown | **PASS** | 13/13 | 81s | `smoke_results_20261014_114935.json` (first run) |
| **T6** | Mid-Hold Crash Recovery (taskkill /f) | **PASS** | 18/18 | 669s | `smoke_results_20261014_134647.json` (rerun) |

Requirement status: met. Six required tests PASS; T5B is PASS (the stronger outcome than CONDITIONAL). Overall IC verdict: **PASS**.

### Superseded results in the first-run file

The first full attended IC run (`smoke_results_20261014_114935.json`) also contains four entries that are superseded by the rerun and are not used for the verdict:

| Test | Result in first run | Reason | Superseded by |
| :--- | :--- | :--- | :--- |
| T1 | MISS: "FAIL (old wording)", 7/20 checks in 480s | No entry was dispatched within the 480 s budget; every entry-dependent check observed 0 | rerun T1 PASS 20/20 |
| T4 | MISS: "FAIL (old wording)", 7/12 checks in 483s | No entry was dispatched within the budget; entry, exit, daily-limit and roundtrip checks observed 0 | rerun T4 PASS 12/12 |
| T2 | INVALID: "Helper exited with code 2" | External-close helper gave up after its 330 s position wait; entry gate starved | rerun T2 PASS 14/14 |
| T6 | INVALID: "Helper exited with code 2" | Restart helper gave up after its 330 s position wait; entry gate starved | rerun T6 PASS 18/18 |

Cause (from the harness commit message of `879abae`, harness-only change, `ExecTest.mq5` unchanged): on `ICMarketsEU-Demo` ticks arrive at about 0.77 per second per symbol and about 41% have zero spread, so only about 20% of entry attempts pass the `zero_spread` / `stale_tick` gates (120 s retry between attempts). The harness budgets (480 s for T1/T4, 330 s helper waits) were too short for that feed. Commit `879abae` raised the helper waits to 1300 s and the test timeouts to 1500 s, made a no-entry run INVALID (entry gate starved, skips by reason) instead of a miss, and added EntryStats to the console and results JSON. The EA was not modified; the entry gates are intended behavior.

T3A, T5A and T5B were not affected by this and are taken from the first run (all three PASS there with unchanged EA code). T3B is NOT TESTABLE in both runs.

---

## 2. Run Provenance

| Run | Harness | Mode / scope | Window | Exit |
| :--- | :--- | :--- | :--- | :--- |
| First run | Predates commit `879abae` (committed 12:48:59 CEST; this run's results file was last written 12:33:28 CEST); by commit order this is parent `c90f774c0b92de60f27b7fa047edac6eae0d534e`. The harness commit is not recorded inside the results JSON. | Attended, all tests | started 11:49:35 CEST (file name `114935`), results written 12:33:28 CEST | not recorded here |
| Rerun | `879abae36dc6cf814f255759ce7db1055074afa4`, `run_smoke_tests.ps1 -Mode Attended -OnlyTests T1,T2,T4,T6` | Attended, 4 of 8 tests | 2026-10-14 11:46:47 to 12:11:36 UTC (13:46:47 to 14:11:37 CEST) | 0 |

Note on the rerun: it was launched through a wrapper that only stubbed `powercfg` (the machine's power settings were left unchanged). Python, MT5, the helpers and the harness ran unmodified and for real. The full console log is committed as `smoke_console_20261014_134647.txt`.

---

## 3. Evidence Files

| File | SHA256 | Git blob (as committed bytes) | Git blob (LF-normalised) | Bytes |
| :--- | :--- | :--- | :--- | ---: |
| `smoke_results_20261014_114935.json` (IC first run) | `f80106cc89b9221f57735d4a3ddf96042c798df4e2ca13b04e50c06c49771af1` | `044d3e67f2af0d31af504aa7d957906a36644748` | `909a3ff69c6d59ca31ea8c28aa711e6fea427b48` | 263023 |
| `smoke_results_20261014_134647.json` (IC rerun) | `f8e0000a85c1fda0684b7888df112e14e5fa0bff5836f7811c95370dd97aa8c2` | `d7a49999097553283c6ae9f1de0ff7913ab1e770` | `25e7dea7065c1cdaaf5c2c86709dbee8c9f0211f` | 200000 |
| `smoke_console_20261014_134647.txt` (rerun console) | `51733c76dc2a9b91c36ea12e8351862af902ca25897efac94538ae451ff2ea43` | `39e0f8e6dfcda37ed9b24c4a8286286caaa79a55` | n/a | 13398 |

The two JSON files are UTF-8 with BOM and CRLF line endings, written by PowerShell. They are committed byte-for-byte (the clone has `core.autocrlf=false`), so the committed blob is the "as committed bytes" column. The "LF-normalised" column is the blob a Windows checkout with `core.autocrlf=true` computes for the same file in the working tree; it is the value quoted in earlier hand-offs for the rerun file (`25e7dea...`). The SHA256 values are over the raw bytes and are unambiguous.

---

## 4. Harness, EA and Compile Results

| Item | Git blob | Note |
| :--- | :--- | :--- |
| `run_smoke_tests.ps1` (rerun, `879abae`) | `1f2552d1edde7838897e5fbaca0c3e43fbaa5e45` | adds starved-entry-gate budgeting, INVALID classification, EntryStats |
| `ExecTest.mq5` | `e38465857daf5bdd5fcb026a1c128066eaa6f858` | unchanged from the MetaQuotes-Demo report |
| `XTestSeedBaseline.mq5` | `2b6c2cf0b6d91a39cc775f49fdf7155d597a0e5e` | seed script for T5A |
| `ClearGV.mq5` | `a8fb36d886595facd0a0e8c791840c03703ee018` | global-variable cleaner used before T6 |
| `external_close.py` (`879abae`) | `5476c733534d751eefc122b27a6fef13294ca1e5` | helper wait 330 s to 1300 s |
| `test_restart.py` (`879abae`) | `85d6b4898a2aaea45edf3fa883c31cb4087d07a2` | poll timeout 330 s to 1300 s |

Compile results, 2026-10-14 (as reported by the operator; the compile output itself is not part of the committed evidence): `ExecTest.mq5`, `XTestSeedBaseline.mq5` and `ClearGV.mq5` each compiled with 0 errors and 0 warnings. The harness pre-flight also verifies that each `.ex5` is not older than its source.

---

## 5. EntryStats (rerun, harness 879abae)

The IC feed passes the entry gates only occasionally, so the number of attempts per entry is part of the evidence. "Attempts" = entry-gate skip rows plus entries.

| Test | Attempts | Entries | Attempts to first entry | Skips: zero_spread | Skips: stale_tick | Skips: other | Attempt source |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | :--- |
| T1 | 3 | 1 | 3 | 1 | 1 | 0 | skips.csv vs first BUY row |
| T2 | 3 | 1 | 3 | 2 | 0 | 0 | skips.csv vs first BUY row |
| T4 | 2 | 1 | 2 | 1 | 0 | 0 | skips.csv vs first BUY row |
| T6 | 6 | 1 | 6 | 1 | 4 | 0 | log `[CYCLE TRIGGER]` lines before the first `[ORDER SENT]` BUY |

Stale-tick backoff notes (120 s each): T1 1, T2 0, T4 0, T6 4. EntryStats are not recorded for T3A, T5A and T5B because the first-run harness predates the feature; from their check lists, T5B had 1 entry (bound "<= 3 attempts"), T3A exactly 1 entry, and T5A 0 entries (by design, the equity gate halts before any entry).

---

## 6. Per-Test Evidence Summary

All checks and observed values are in the results JSON files; the key evidence is summarized here.

### T1: Close Reject Backoff (rerun) - PASS 20/20
- Injected close rejects 6 of 6; 1 entry dispatched (EA tag and journal agree); exactly one exit dispatch; `[HOLD EXPIRED]` logged once; zero `[ORPHAN DETECTED]`; one roundtrip row with restart=False.
- `[EXIT RETRY]` lines (attempts 1-4) 4; `[CRITICAL]` EA lines (attempts >= 5) 2; alert echoes 1; 6 close-reject rows tagged `fault_injection`.
- First reject to successful close 13.099 s against the nominal 12750 ms (window 12.638-13.458 s); reject-to-reject gaps 0 violations.

### T2: Orphan External Close Detection (rerun) - PASS 14/14
- 1 entry; `[EXTERNAL CLOSE DETECTED]` logged, followed by a strict transition to STATE_IDLE (log index 22 after detection at index 19); 1 `orphan_external_close` row in skips.csv; the EA sent no close of its own; the external close is visible in the journal.

### T3A: In-Flight Timeout Fill Reconciliation (first run) - PASS 13/13
- 1 injected timeout; 1 entry dispatch; reconciliation confirmed the fill; exactly one BUY row (`reconcile_entry_fill`); exactly one exit dispatch and one roundtrip row. Duration 550 s with 2 stale-tick backoffs.

### T3B: Timeout Unfilled Cancellation - NOT TESTABLE
- `OrderSend` executes; the unfilled variant cannot be reached under the code freeze (same limitation as the MetaQuotes-Demo report). Not counted.

### T4: Daily Order Cap & Skip Logic (rerun) - PASS 12/12
- 1 entry, daily-limit gate logged 2 times, one exit dispatch, one roundtrip row.

### T5A: Equity Stop Gate, Seeded Baseline (first run) - PASS 22/22
- Seed marker written with status OK; baseline 10004.78 read back equal to the seeded equity; seed date equals today's UTC midnight (1791936000); the seed launch started no ExecTest and placed no orders and stopped gracefully; the EA loaded the seeded baseline; STATE_HALTED with reason "Equity drop" once; no entry dispatch and no BUY rows after the halt. Duration 28 s.

### T5B: Equity Stop Post-Close Drawdown (first run) - PASS 13/13
- 1 entry (within the "<= 3 attempts" bound), closed (`[EXIT CONFIRMED]` equals entries); a SELL precedes the HALT line (observed 17 against the bound "< 20"); halt raised by the post-close check once; no entry dispatch after the halt. Duration 81 s with 0 backoffs. On this account the drawdown stop was reached on the first attempt, so the test is PASS rather than CONDITIONAL.

### T6: Mid-Hold Crash Recovery, taskkill /f (rerun) - PASS 18/18
- `[RESTART RECOVERY]` emitted once, recovery saw the prior state STATE_IN_POSITION; zero `[ORPHAN DETECTED]`; no `[STATE RESET]` line; one entry (ticket 2007868245 identical across recovery, EA BUY and helper) and the journal shows one entry; no entry dispatch after recovery; exactly one exit dispatch after recovery; relaunch was not blocked by a stale instance lock and acquired the lock fresh.
- `gvariables.dat` kill-time capture: 4057 B, mtime 14:10:29.138, sampled 120 ms after process exit with the terminal down; before 1592 B, end 1592 B. 4 stale-tick backoffs, duration 669 s.

---

## 7. Differences from the MetaQuotes-Demo Report

| Aspect | MetaQuotes-Demo report | IC Markets EU (this report) |
| :--- | :--- | :--- |
| Feed | MetaQuotes-Demo synthetic feed | `ICMarketsEU-Demo` (IC Markets EU demo server), about 0.77 ticks/s per symbol |
| Zero-spread ticks | about 53% of EURUSD ticks | about 41% of ticks |
| Filling | not characterized in that report | IOC-only filling |
| Account | 10013076140, equity about 1000 (seeded baseline 1005.78) | 53098320, USD, Raw Spread, hedging, 1:30; equity about 10000 (seeded baseline 10004.78) |
| Currency label | EUR in parameter names (`InpMaxDrawdownEUR`) | same names; the amounts are in account currency (USD). The "EUR" in log lines (e.g. "10004.78 EUR") is a label, not a conversion |
| Harness | `c90f774`, `run_smoke_tests.ps1` blob `a1a13a9d7bddec05ab800f74f5d5641afd1031af` | rerun `879abae`, blob `1f2552d1edde7838897e5fbaca0c3e43fbaa5e45`; first run on `c90f774` |
| Entry gate | entries sparse (about 53% zero-spread EURUSD ticks); all tests completed within that run's budgets | gate starved the first-run T1/T4 (MISS, "FAIL (old wording)") and T2/T6 (INVALID); budgets raised, rerun PASS |
| T5B | CONDITIONAL (2 of 3 attempts closed without crossing the drawdown; timed out after 600 s) | PASS (halt raised after the first close, 81 s) |
| T3B | NOT TESTABLE | NOT TESTABLE |
| T1 first reject to close | 12.807 s | 13.099 s (both within the 12.638-13.458 s window) |
| Verdict source files | run 3 (`085425`) plus targeted rerun (`101555`) | first run (`114935`) plus targeted rerun (`134647`) |
| Overall | all testable paths PASS, T5B CONDITIONAL | **PASS** |
| Latency statistics | RTT tables (section 2 of that report) | not computed in this report; round-trip latency is not part of the IC verdict |

---

## 8. Limitations

1. Verdicts are consolidated from two result files produced by two harness versions (`c90f774` and `879abae`). The EA binary source (`ExecTest.mq5` blob `e38465857daf5bdd5fcb026a1c128066eaa6f858`) is identical across both; the harness change affects waiting budgets, INVALID classification and statistics only.
2. The harness commit of the first run is inferred from commit order (it ended before `879abae` was committed) and is not stored in its results JSON.
3. The compile results are as reported by the operator and are not backed by a committed compiler log.
4. T3B remains NOT TESTABLE under the code freeze and is excluded from the verdict.
5. T5B is market-dependent; PASS here means the drawdown stop was reached within the harness budget on this run. A different market path could produce CONDITIONAL, which still meets the requirement.
6. The IC demo feed is sparse (about 0.77 ticks/s per symbol, about 41% zero-spread ticks, 120 s gate backoff, IOC-only filling); entries need several attempts (2 to 6 in the rerun). Latency and fill characteristics are those of a demo server and do not establish live execution quality or trading edge.
7. The rerun used a wrapper that stubbed `powercfg`; power settings were not changed. No other part of the harness was altered.
8. The smoke suite remains a probe validation only; it makes no claim about quantitative trading edge.

---

## 9. Conclusion

On IC Markets EU demo (`ICMarketsEU-Demo`, login 53098320), ExecTest EA v2.10 meets the requirement: T1, T2, T3A, T4, T5A, T5B and T6 PASS, with T3B NOT TESTABLE and not counted. The earlier first-run T1/T4 MISS ("FAIL (old wording)") and T2/T6 INVALID results were caused by the harness budgets being too short for the sparse IC feed, were superseded by the rerun on harness `879abae`, and required no EA change. Overall IC verdict: **PASS**.
