# PREREG v1.05 to v1.06: rationale per change

Baseline: `PREREG_e7c54b0.md` (registered v1.05, 381 lines). Draft: `PREREG_v1.06_draft.md`. Line numbers below refer to the v1.05 file. Decision ids D* are the coordinator decisions in `fix_spec_P1.md`; claim ids are from `claims_B1_B3.md` and `claims_B4.md` (all CONFIRMED).

## Standard of a pre-data clarification used here

A change is included only if (a) the registered v1.05 text is self-contradictory, unsatisfiable, or leaves a mechanical definition open that the code audit had to resolve, and (b) the new text introduces no new parameter value, threshold, filter or statistic, and changes none. Nothing in this draft was derived from any trade, fill, spread or P&L observation: the EA has not run evidentially, SpreadLog has not produced the registered measurement and `ACCOUNT.md` is still a template.

## Parameters verified identical (diff touches none of these lines)

| Parameter | v1.05 location | v1.05 value | v1.06 |
| :--- | :--- | :--- | :--- |
| TP / SL | §2.4 | $+5.0$ / $-5.0$ pips from `fill_price` | identical |
| Time stop | §2.4 | $300$ s | identical |
| Spread gate rule | §2.3.1, §3.3 | $\min(0.3\text{ pip}, \text{P60 of observed session spread})$ | identical |
| Tick freshness | §2.3.2 | reject if last tick older than $3000$ ms | identical |
| Session | §2.3.3 | 07:00:00 to 16:00:00 UTC, Mon-Fri | identical |
| Lookback length | §2.2 | $20$ bars | identical (20; only the index range is stated unambiguously) |
| Volume / concurrency | §2.1 | 0.01 lot; one open position globally | identical |
| $\alpha$ | §4.1 | $0.05 / 2 = 0.025$ | identical |
| $N$ / burn-in | §2.6, §4.2 | $900$ / $100$ | identical |
| $p_0$ formula | §2.6 | $\lvert\bar{L}\rvert / (\bar{W} + \lvert\bar{L}\rvert)$ | identical |
| Net PnL formula | §2.5 | $\text{gross\_pips} - 2 \times \text{commission\_pips}$ | identical (only the unit of `commission_pips` is stated) |
| Risk limits | §6 | 20 trades/day/symbol; $30.0$ pips daily; 5 consecutive errors; kill switch | identical (daily-stop measure defined, threshold same) |
| Spread fidelity | §5.1.1(3) | $1.20 \times S_{\text{pre-test}}$ | identical |
| Power figures | §4.2, §4.3 | 85.08 % and 87.84 % (illustrative) | identical |

## Changes

### CL. Change-log entry v1.06 (new, top of change log)

- **Section**: Change Log
- **Audit claim id(s)**: all
- **v1.05 text**: (no v1.06 entry; the change log starts with `### v1.05 (2026-10-14)` at line 13)
- **v1.06 text** (inserted above `### v1.05`):

~~~~text
### v1.06 (2026-10-14)
Clarifications only. Each item resolves a point that the pre-freeze code audit of the EA proved ambiguous or self-contradictory, and was drafted before any evidential data exists. No parameter value changes: TP/SL $\pm 5.0$ pips, $300\text{ s}$ time stop, spread gate rule, $3000\text{ ms}$ tick freshness rule, session `07:00–16:00 UTC`, $\alpha = 0.025$, $N = 900$, $N_{\text{burn}} = 100$, the $p_0$ formula and all Section 6 risk limits are identical to v1.05. Audit claim ids (B1–B4 code audit) are given per item.
1. **Signal Window Notation (§2.2)** — claim B1-1b. v1.05 defined the lookback as $[t-20, t-1]$ but compared $C_{t-1}$ with $\max_{i=1..20} H_{t-i}$, which includes $H_{t-1}$; a close cannot exceed the high of its own bar, so the BUY rule could never fire (nor the SELL rule). v1.06 states that the signal bar $t-1$ is compared with the 20 completed bars $t-2 \ldots t-21$. Lookback length ($20$) is unchanged and agrees with §1.1.
2. **Window Consumption at Dispatch (§2.2)** — claim B1-4b. v1.05 did not say which event consumes a `window_id`; the audited code consumed it only on fill, so a rejected dispatch allowed a second `OrderSend` in the same window. v1.06: a `window_id` is consumed when an order is dispatched, not only when filled; at most one `OrderSend` per `window_id` globally.
3. **Operational Exit Reasons (§6.2, §6.4, §7.1)** — claims B2-26, B2-27, B3-4b. v1.05 listed only `TAKE_PROFIT`, `STOP_LOSS`, `TIME_STOP`, while Section 6 requires liquidations that none of these describe. v1.06: `KILL_SWITCH`, `DAILY_STOP` and `EXTERNAL` are logged but non-evidential; the evidential exit reasons remain the three registered ones.
4. **Daily Stop Counts Floating P&L (§6.2)** — claim B3-2b. v1.05 required liquidation of an active open position on breach, but with one global position the realised daily sum changes only when no position is open, so that clause could never act unless floating P&L counts. v1.06 defines the daily net as realised plus floating net pips; the $30.0$-pip threshold is unchanged.
5. **Commission Definition (§2.5, §3.4, §7.1)** — claims B2-13, B2-14, R35, R36. v1.05 called `commission_pips` a charge "per turn" while §2.5 subtracts $2 \times \text{commission\_pips}$ and §3.4 reads commission per side, and "the symbol pip value" did not say per lot or per traded volume. v1.06: `commission_pips` is the mean per-side commission of the entry and exit deals, converted with the pip value at the traded volume ($0.01$ lot); $\text{net\_pips} = \text{gross\_pips} - 2 \times \text{commission\_pips}$ is unchanged.
6. **Run Identity (§5.2, §7.1)** — claim R18. v1.05 required a reset to $N = 0$ after an operational INVALID but defined no way to tell runs apart in append-only CSVs. v1.06: `run_id` column; the restarted run uses a new `run_id`; only the current run is counted. The reset and one-restart rules are unchanged.
7. **ACCOUNT.md Integrity Mechanism (§3.1, §7.1)** — claims R1, R4. v1.05 required a recorded SHA256 but no mechanism tying the running EA to the committed file. v1.06: the EA hashes the `ACCOUNT.md` copy in `Common\Files` (LF-normalised SHA256), refuses evidential mode unless it equals the input hash, and writes the hash to every CSV row; the registered server and login are compiled in.
8. **Timestamp Semantics (§7.1)** — claims B1-13a, B2-20, B2-21, B2-23, R39. v1.05 said only "epoch millisecond"; the audited code logged tick or server times. v1.06: all `*_msc` fields are UTC epoch milliseconds with the stated definitions.
9. **SpreadLog Field Name and Weekday Coverage (§3.3)** — claims B2-34, R32. The registered field name `ticks_in_prev_60s` is confirmed unchanged (the audited code used `ticks_prev_60s`). v1.06 states that the $5$-day requirement means at least $5$ distinct weekday dates with session data per symbol.
10. **Hash Definition (§10)** — claim R40 (verification method). `git hash-object <file>` hashes a working-tree file, not committed content. v1.06 defines hashes on the committed LF content at a named commit.
11. **Version Strings**: bumped to `1.06` (title, Document Version, Section 10 block). Earlier change-log entries are historical and unchanged.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Required by the brief: a v1.06 entry listing every change, its reason and the audit claim id. It is a documentation insertion; it does not alter any registered rule. It also states explicitly that every registered parameter is identical to v1.05.

### C1. Signal formula: signal bar t-1 versus the 20 completed bars t-2..t-21

- **Section**: §2.2
- **Audit claim id(s)**: B1-1b (decision D1)
- **v1.05 text** (lines 81-86):

~~~~text
- **Lookback Window**: Prior 20 completed M1 bars ($[t-20, t-1]$). Current incomplete bar $t$ is strictly excluded from channel calculation.
- **Trigger Conditions**:
  - **BUY Signal**: The most recent bar close ($C_{t-1}$) is strictly greater than the maximum high of the preceding 20 bars:
    $$C_{t-1} > \max_{i=1..20} H_{t-i}$$
  - **SELL Signal**: The most recent bar close ($C_{t-1}$) is strictly less than the minimum low of the preceding 20 bars:
    $$C_{t-1} < \min_{i=1..20} L_{t-i}$$
~~~~

- **v1.06 text**:

~~~~text
- **Lookback Window**: Bar $t$ is the current incomplete M1 bar and bar $t-1$ is the signal bar (the most recent completed bar). The channel consists of the 20 completed M1 bars that precede the signal bar ($[t-21, t-2]$). The signal bar $t-1$ itself and the incomplete bar $t$ are strictly excluded from the channel calculation.
- **Trigger Conditions**:
  - **BUY Signal**: The signal bar close ($C_{t-1}$) is strictly greater than the maximum high of the 20 channel bars:
    $$C_{t-1} > \max_{i=2..21} H_{t-i}$$
  - **SELL Signal**: The signal bar close ($C_{t-1}$) is strictly less than the minimum low of the 20 channel bars:
    $$C_{t-1} < \min_{i=2..21} L_{t-i}$$
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 is self-contradictory: the window $[t-20, t-1]$ contains the signal bar itself, and the trigger $C_{t-1} > \max_{i=1..20} H_{t-i}$ includes the term $H_{t-1}$. Since $C_{t-1} \le H_{t-1}$ always, the BUY condition is unsatisfiable (and SELL symmetrically, $C_{t-1} \ge L_{t-1}$). The only reading under which the registered signal can fire at all is signal bar $t-1$ versus the 20 completed bars before it, $t-2 \ldots t-21$. The lookback length stays 20 (§2.2 'No Parameter Sweeps', §1.1 'preceding 20 closed M1 bars'), strictness ($>$ / $<$) is unchanged, the incomplete bar stays excluded. No data have been seen; the new text is the reading that the audited code already implements (audit B1-1a PASS, B1-1b classified as a PREREG text defect). Fixing an unsatisfiable formula is not an optimisation of any parameter.

### C2. Window consumption at dispatch, not only at fill

- **Section**: §2.2
- **Audit claim id(s)**: B1-4b (decision D5)
- **v1.05 text** (line 87):

~~~~text
- **Window Throttling**: At most one order signal is accepted per 5-minute time window globally (`window_id = floor(epoch_seconds / 300)`). If multiple breakout bars occur within the same 5-minute rolling window, only the first signal is dispatched; all subsequent signals in that window are dropped.
~~~~

- **v1.06 text**:

~~~~text
- **Window Throttling**: At most one order signal is accepted per 5-minute time window globally (`window_id = floor(epoch_seconds / 300)`). If multiple breakout bars occur within the same 5-minute rolling window, only the first signal is dispatched; all subsequent signals in that window are dropped. A `window_id` is consumed when an order is dispatched to the broker (at the `OrderSend` call), not only when it is filled: a dispatched order that is rejected or errors still consumes its window. At most one `OrderSend` is therefore issued per `window_id` globally.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 says at most one order signal per window and 'only the first signal is dispatched', but never states which event consumes the window. The audited code consumed it only on fill; a rejected `OrderSend` left the window open and the loop could send a second order for the other symbol in the same window, i.e. two dispatches in one window, which contradicts both 'at most one' and the §4.2 cluster-size argument (each window contains at most one trade, $M = N$). The clarification closes that gap in the direction the registered text already states (at most one order per window). The 5-minute window length, the global scope and the one-trade-per-window power arithmetic are unchanged. It is not a tuning choice: it affects no threshold and no statistic.

### C3a. Kill-switch closure is logged as KILL_SWITCH, non-evidential (§6.4)

- **Section**: §6.4
- **Audit claim id(s)**: B2-27, B3-4b (decisions D12, D13)
- **v1.05 text** (line 311):

~~~~text
4. **External Kill Switch**: The test harness polls for the existence of `kill_switch.txt` in the terminal common directory every cycle. If the file is detected, all trading halts immediately and open positions are closed.
~~~~

- **v1.06 text**:

~~~~text
4. **External Kill Switch**: The test harness polls for the existence of `kill_switch.txt` in the terminal common directory every cycle. If the file is detected, all trading halts immediately and open positions are closed. The closing is logged with `exit_reason = KILL_SWITCH` and is non-evidential (Section 7.1).
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 requires open positions to be closed on kill switch but does not say how that round trip is classified; the audited code closed the position without logging it (B2-27, B3-4b) and, in other branches, mislabelled non-registered closures as TIME_STOP/STOP_LOSS (B2-26). The sentence labels the closure with its true operational reason and marks it non-evidential so it cannot be counted as a registered TP/SL/time-stop outcome. The kill-switch mechanism itself is unchanged.

### C3b. Operational exit reasons are logged but non-evidential (§7.1)

- **Section**: §7.1
- **Audit claim id(s)**: B2-26, B2-27, B3-4b (decisions D12, D13, D14)
- **v1.05 text** (line 336):

~~~~text
| `exit_reason` | String | Exit classification: `TAKE_PROFIT`, `STOP_LOSS`, or `TIME_STOP` |
~~~~

- **v1.06 text**:

~~~~text
| `exit_reason` | String | Registered evidential exit classification: `TAKE_PROFIT`, `STOP_LOSS`, or `TIME_STOP`. Operational closes are logged as `KILL_SWITCH` (Section 6.4), `DAILY_STOP` (Section 6.2) or `EXTERNAL` (any other closure, e.g. broker stop-out or manual close); these three are non-evidential: they are logged but never counted toward burn-in or $N = 900$ |
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 enumerates only three exit classes, yet §6 mandates closures (daily stop, kill switch) that fit none of them and a real account can also be closed externally (stop-out, manual). The audited code forced such closures into TIME_STOP or STOP_LOSS (B2-26), contaminating the registered outcome classes. The new text keeps the evidential set exactly as registered (TAKE_PROFIT, STOP_LOSS, TIME_STOP) and adds labels for non-registered closures so they are visible and excluded rather than silently re-classified. No trade that closes by TP, SL or 5-minute time stop is affected. Consequence for the coordinator: a DAILY_STOP closure is already followed by a MISS under §5.1.2(4), so excluding it from N cannot bias the test; KILL_SWITCH ends the run; an EXTERNAL closure is excluded from N (not expected at 0.01 lot with a 10000 USD balance) - whether an EXTERNAL occurrence should also count as an operational INVALID in §5.2 is not addressed here.

### C4. Daily stop: realised plus floating net; liquidation logged as DAILY_STOP (§6.2)

- **Section**: §6.2
- **Audit claim id(s)**: B3-2b (decisions D12, D14)
- **v1.05 text** (line 309):

~~~~text
2. **Daily Net Loss Stop**: If cumulative net loss within a single calendar day reaches or exceeds **$30.0$ pips**, the EA liquidates any active open position immediately and transitions to `STATE_HALTED` until 00:00 UTC of the next trading day. The starting demo balance is documented in `ACCOUNT.md` for baseline account tracking.
~~~~

- **v1.06 text**:

~~~~text
2. **Daily Net Loss Stop**: If cumulative net loss within a single calendar day reaches or exceeds **$30.0$ pips**, the EA liquidates any active open position immediately and transitions to `STATE_HALTED` until 00:00 UTC of the next trading day. Cumulative net result for this purpose is the day's realised net pips (the sum of `net_pips` of the round trips closed that day) plus the floating net pips of the open position, if any, i.e. the `net_pips` formula of Section 2.5 evaluated at the current exit-side quote (Bid for a long, Ask for a short) with the exit-side commission taken equal to the entry deal's per-side commission; the stop triggers when this sum is $\le -30.0$ pips, so an open position is itself liquidated when it causes the breach. The liquidating close is logged with `exit_reason = DAILY_STOP` and is non-evidential (Section 7.1). The starting demo balance is documented in `ACCOUNT.md` for baseline account tracking.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 is self-contradictory on what 'cumulative net loss' means: it requires the EA to 'liquidate any active open position immediately', yet with at most one global position (§2.1) a realised-only sum changes only when a round trip closes, i.e. when no position is open, so the liquidation clause could never act. The clause is meaningful only if floating P&L of the open position counts, which is the reading the registered wording 'liquidates any active open position' presupposes. The threshold ($30.0$ pips), the calendar-day (UTC) scope, the halt-until-00:00-UTC rule and the MISS consequence in §5.1.2(4) are unchanged. NOTE for the coordinator: this is the one clarification with behavioural reach (a floating breach can end the run earlier than a realised-only reading); the choice of exit-side commission for the not-yet-closed position (equal to the entry deal's per-side commission) is the drafter's reading of D14 and may be struck or reworded.

### C5a. Commission: both deals read; converted at traded volume (§3.4)

- **Section**: §3.4
- **Audit claim id(s)**: B2-13, B2-14, R35, R36 (decision D6)
- **v1.05 text** (line 184):

~~~~text
Commission per side is read directly from deal history (`deal.commission`) per fill and converted to pips with the symbol pip value; it is never assumed or statically hard-coded.
~~~~

- **v1.06 text**:

~~~~text
Commission per side is read directly from deal history (`deal.commission`) per fill and converted to pips with the symbol pip value; it is never assumed or statically hard-coded. The commission of both the entry deal and the exit deal is read, and each is converted with the pip value at the traded volume (the account-currency value of one pip for $0.01$ lot, not for $1$ lot): $\text{commission\_pips}_{\text{side}} = |\text{deal.commission}| / \text{pip\_value}(\text{volume})$, where $\text{pip\_value}(\text{volume}) = \text{tick\_value} \times (\text{pip\_size} / \text{tick\_size}) \times \text{volume}$. `commission_pips` (Section 7.1) is the mean of the two per-side values.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 says commission is converted 'with the symbol pip value' without stating per lot or per traded volume; the audited code used the per-1-lot pip value for a 0.01-lot trade, making commission_pips about 100x too small (B2-13/R35), and read only the entry deal (B2-14/R36). The clarification states the only dimensionally consistent reading of the registered rule 'read per fill, convert to pips' for 0.01 lot (the registered fixed volume, §2.1), and that each side's own deal is read ('per side', 'per fill'). The registered net formula, the 'never assumed' rule and the volume 0.01 lot do not change. No outcome has been observed; this is a unit-conversion definition.

### C5b. Commission: commission_pips = mean per-side commission (§2.5)

- **Section**: §2.5
- **Audit claim id(s)**: B2-13, B2-14, R35, R36 (decision D6)
- **v1.05 text** (line 123):

~~~~text
  - `commission_pips`: Broker commission charged per turn, expressed in pips based on contract size.
~~~~

- **v1.06 text**:

~~~~text
  - `commission_pips`: Mean per-side broker commission, i.e. the mean of the commissions charged on the entry deal and on the exit deal (each read per Section 3.4), expressed in pips using the pip value at the traded volume ($0.01$ lot). Hence $2 \times \text{commission\_pips}$ equals the sum of the entry-deal and exit-deal commissions in pips, which is the amount subtracted in the `net_pips` formula above.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 is internally inconsistent: §2.5 calls `commission_pips` a charge 'per turn' (round turn) but the net formula subtracts $2 \times \text{commission\_pips}$ (two sides), and §3.4 reads commission 'per side'. Under a round-turn reading the formula would double-count. The clarification fixes the unit as per side, which is the only reading consistent with the registered $2 \times$ factor and with §3.4. The registered net formula $\text{net\_pips} = \text{gross\_pips} - 2 \times \text{commission\_pips}$ is not altered; $\bar{c}_{\text{info}} = \text{mean}(2 \times \text{commission\_pips})$ in §2.6 keeps its meaning.

### C5c. Commission: field description (§7.1)

- **Section**: §7.1
- **Audit claim id(s)**: B2-13, B2-14, R35, R36 (decision D6)
- **v1.05 text** (line 335):

~~~~text
| `commission_pips` | Double | Broker commission deducted, expressed in pips |
~~~~

- **v1.06 text**:

~~~~text
| `commission_pips` | Double | Mean per-side commission of the entry and exit deals, expressed in pips at the traded volume (Sections 2.5, 3.4) |
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Keeps the logging dictionary consistent with the clarified §2.5/§3.4 definition. No change to the field name or type.

### C6a. Run identity: new run_id after an operational INVALID (§5.2)

- **Section**: §5.2
- **Audit claim id(s)**: R18 (decision D17)
- **v1.05 text** (line 299):

~~~~text
- Upon an initial INVALID, the entire run is reset to zero ($N = 0$), root-cause remediation is documented, and the 100-trade burn-in phase ($N_{\text{burn}} = 100$) must be re-executed from scratch.
~~~~

- **v1.06 text**:

~~~~text
- Upon an initial INVALID, the entire run is reset to zero ($N = 0$), root-cause remediation is documented, and the 100-trade burn-in phase ($N_{\text{burn}} = 100$) must be re-executed from scratch. Each run is identified by a `run_id` (Section 7.1); the restarted run uses a new `run_id`. Only rows carrying the `run_id` of the current run count toward burn-in and toward $N = 900$; rows of the invalidated run are retained as an audit trail and are never counted.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 already registers 'the entire run is reset to zero ($N = 0$) ... burn-in re-executed from scratch' but the CSV files are append-only (§7), so after a restart the rows of the invalidated run and of the new run share a file and cannot be separated; the audited analysis used the first 100 and next 900 evidential rows of the whole file (R18). The clarification maps the registered reset onto a concrete mechanism: a `run_id` per run. The number of permitted restarts (exactly one), the reset to $N = 0$, the full re-run of the 100-trade burn-in, and the second-INVALID closure are unchanged.

### C6b_C7b. Two columns added to the field table: run_id and account_md_sha256 (§7.1)

- **Section**: §7.1
- **Audit claim id(s)**: R18 (D17); R4 (D18)
- **v1.05 text** (line 339):

~~~~text
| `window_id` | Int64 | Integer 5-minute bucket ID (`floor(time / 300)`) |
~~~~

- **v1.06 text**:

~~~~text
| `window_id` | Int64 | Integer 5-minute bucket ID (`floor(time / 300)`) |
| `run_id` | String | Identifier of the run (Section 5.2); every row of one run carries the same value |
| `account_md_sha256` | String | LF-normalised SHA256 of the `ACCOUNT.md` copy verified by the EA (Section 3.1) |
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Required by the two clarifications above: a run must be identifiable in the append-only files (§5.2) and the verified ACCOUNT.md hash must be written to every row (§3.1). They are identifiers only; no registered column is renamed or redefined by this change.

### C7. ACCOUNT.md integrity mechanism (EA hashes the Common\Files copy; server/login compiled in)

- **Section**: §3.1
- **Audit claim id(s)**: R1, R4 (decision D18)
- **v1.05 text** (line 154):

~~~~text
> **Pre-Execution Requirement**: `ACCOUNT.md` must be completed and committed to the repository, with its Git commit hash and SHA256 checksum recorded, before the first burn-in trade is executed. Testing cannot commence until `ACCOUNT.md` is fully populated and committed.
~~~~

- **v1.06 text**:

~~~~text
> **Pre-Execution Requirement**: `ACCOUNT.md` must be completed and committed to the repository, with its Git commit hash and SHA256 checksum recorded, before the first burn-in trade is executed. Testing cannot commence until `ACCOUNT.md` is fully populated and committed.

- **ACCOUNT.md Integrity Mechanism**: The operator places a copy of the committed `ACCOUNT.md` in the terminal `Common\Files` directory. In evidential mode the EA computes the SHA256 of that copy over its LF-normalised content (Section 10) and refuses to start evidential trading unless it equals the `ACCOUNT.md` SHA256 supplied to the EA as input. The hash is written to the `account_md_sha256` field of every CSV row (Section 7.1). The registered server (`ICMarketsEU-Demo`) and account login (`53098320`) recorded in `ACCOUNT.md` are compiled into the EA as constants, and the EA refuses evidential mode on any other account.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 requires the SHA256 of ACCOUNT.md to be recorded but names no mechanism that binds the running EA to the committed file; the audit found the EA compared server/login to free inputs and only checked that the hash input had 64 characters. The new text defines the check the registration already implies ('ACCOUNT.md ... fully populated and committed' before the first trade). The values compiled in (`ICMarketsEU-Demo`, `53098320`) are the ones already recorded in ACCOUNT.md section 1 and in the v1.05 change log; no value is chosen after seeing data. It adds a refusal condition for evidential mode only; it changes no strategy rule, filter, threshold or statistic.

### C8. Timestamp semantics: *_msc are UTC epoch milliseconds (§7.1)

- **Section**: §7.1
- **Audit claim id(s)**: B1-13a, B2-20, B2-21, B2-23, R39 (decision D20, timestamps only)
- **v1.05 text** (lines 327-329):

~~~~text
| `signal_time_msc` | Int64 | Epoch millisecond timestamp of breakout bar close |
| `dispatch_time_msc` | Int64 | Epoch millisecond timestamp of `OrderSend` invocation |
| `fill_time_msc` | Int64 | Epoch millisecond timestamp of broker execution deal |
~~~~

- **v1.06 text**:

~~~~text
| `signal_time_msc` | Int64 | UTC epoch milliseconds of the close of the signal bar $t-1$ (equal to the open time of bar $t$, converted from server time to UTC) |
| `dispatch_time_msc` | Int64 | UTC epoch milliseconds taken immediately before the `OrderSend` invocation |
| `fill_time_msc` | Int64 | UTC epoch milliseconds of the broker entry deal (`DEAL_TIME_MSC`, converted from server time to UTC) |
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 says 'epoch millisecond timestamp' of the bar close / `OrderSend` invocation / broker deal but not in which time base; the audited code wrote tick `time_msc` or broker-server time for signal and dispatch (B1-13a, B2-20, B2-21, R39), and server time for the others (B2-23), so the three fields were mutually inconsistent and not epoch UTC. The new text fixes the time base (UTC) and the instant each field denotes, using only events the registered text already names (signal bar close, `OrderSend` call, broker deal). These fields are telemetry; they enter no filter, threshold or statistic (the registered `window_id` is a separate field and its definition `floor(time / 300)` is unchanged).

### C9. SpreadLog: at least 5 distinct weekday dates per symbol (field name ticks_in_prev_60s confirmed unchanged)

- **Section**: §3.3
- **Audit claim id(s)**: B2-34, R32 (decision D23)
- **v1.05 text** (line 162):

~~~~text
1. **Sampling Duration**: Spread and tick telemetry must be logged across $5$ consecutive trading days (Monday–Friday) during the session window (`07:00:00` to `16:00:00 UTC`).
~~~~

- **v1.06 text**:

~~~~text
1. **Sampling Duration**: Spread and tick telemetry must be logged across $5$ consecutive trading days (Monday–Friday) during the session window (`07:00:00` to `16:00:00 UTC`). For each symbol, the log must contain session-window samples on at least $5$ distinct UTC calendar dates falling on Monday–Friday; if fewer than $5$ such dates are present for a symbol, the measurement is incomplete and no spread gate or $S_{\text{pre-test}}$ may be derived or frozen from it.
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 already requires '5 consecutive trading days (Monday-Friday)' but does not say how completeness is determined per symbol; the audited summary tool did not check it (R32) and could freeze a gate from fewer days. The addition makes the registered '5 days' operational: at least 5 distinct weekday dates with in-session samples per symbol. The registered field name `ticks_in_prev_60s` (§3.3 item 3, unchanged text at v1.05 line 168) is confirmed; the audited SpreadLog wrote `ticks_prev_60s` (B2-34), which is a code defect, not a spec change, so no spec text changes for the field name. Gate formula, 60th percentile, 0.3 pip cap, S_pre-test definition and the 07:00-16:00 UTC window are untouched. The requirement is stated before any pre-start data exist.

### C10. Hashes are defined on committed LF content (§10)

- **Section**: §10
- **Audit claim id(s)**: R40 (verification method; relates to R4)
- **v1.05 text** (line 375):

~~~~text
To guarantee cryptographic immutability, all hashes are defined on committed content using git blob SHA1 (`git hash-object <file>`) and blob-content SHA256 (`git show <commit>:<path> | sha256sum`) under LF normalization (`core.autocrlf false`).
~~~~

- **v1.06 text**:

~~~~text
To guarantee cryptographic immutability, all hashes are defined on the committed LF content of a file at a named commit, never on a working-tree file: the SHA256 is `git show <commit>:<path> | sha256sum`, and the git blob SHA1 is `git rev-parse <commit>:<path>` (the blob id of that same committed content), under LF normalization (`core.autocrlf false`).
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: v1.05 says hashes are 'defined on committed content' but names `git hash-object <file>` for the blob SHA1, which hashes a file in the working tree (line endings and local edits included), not committed content; the audit had to resolve blobs with `git rev-parse <commit>:<path>` and compare `git show | sha256sum` (R40). The new text removes the ambiguity: every hash is a function of `<commit>:<path>` and LF normalisation. The blob id of committed content is obtained by `git rev-parse <commit>:<path>` (equal to `git hash-object` of the same LF bytes). No registered value or file is affected.

### V1. Version string: title

- **Section**: Title
- **Audit claim id(s)**: —
- **v1.05 text** (line 1):

~~~~text
# Pre-Registration: MT5 M1 Breakout Demo Scalper (v1.05)
~~~~

- **v1.06 text**:

~~~~text
# Pre-Registration: MT5 M1 Breakout Demo Scalper (v1.06)
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Mandatory version bump; no semantic content.

### V2. Version string: Document Version

- **Section**: Header
- **Audit claim id(s)**: —
- **v1.05 text** (line 3):

~~~~text
- **Document Version**: `1.05`
~~~~

- **v1.06 text**:

~~~~text
- **Document Version**: `1.06`
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Mandatory version bump; no semantic content.

### V3. Version string: Section 10 block

- **Section**: §10
- **Audit claim id(s)**: —
- **v1.05 text** (lines 378-379):

~~~~text
File: slow_strategies/scalper/PREREG.md
Version: 1.05
~~~~

- **v1.06 text**:

~~~~text
File: slow_strategies/scalper/PREREG.md
Version: 1.06
~~~~

- **Why this is a pre-data clarification, not a re-tuning**: Mandatory version bump; no semantic content. The Status line (NOT FROZEN until tag scalper-prereg-v1 is created after ACCOUNT.md is complete) is unchanged.

## Points for the coordinator (not drafted; outside the requested change list)

1. `ACCOUNT.md` (e7c54b0) carries `Version: 1.05` and `Associated Pre-Registration: PREREG.md (v1.05)`. If v1.06 is adopted, the template reference has to be bumped to v1.06 in the same commit before it is filled in.
2. `ACCOUNT.md` section 5 contains the field `File SHA256` inside `ACCOUNT.md` itself, which cannot hold its own hash; that section also says the hash is recorded in `PREREG.md`, whereas PREREG section 3.1 says only 'recorded'. C7 deliberately says the hash is 'supplied to the EA as input' without naming where it is recorded. A consistent recording place (for example the freeze commit message or the EA input log) should be chosen before the freeze.
3. After an operational INVALID, v1.05 and v1.06 are silent on whether the Hard Stop Date (start + 8 weeks, ACCOUNT.md section 2) restarts with the new `run_id`. Not drafted because the brief did not list it; the choice must be made before data exist.
4. C2 states when a window is consumed (at dispatch). The registered sentence 'only the first signal is dispatched' is left as is; it can be read either as 'first signal generated' or 'first signal that reaches dispatch'. With D2/D3/D5 the coded behaviour is the second reading (a signal dropped by a section 2.3 filter does not consume the window). If the coordinator wants that stated, one sentence can be added; it was left out to keep the edit minimal.
5. C9 reads '5 distinct weekdays' as 5 distinct UTC calendar dates on Monday to Friday (D23 wording is ambiguous between this and 'one of each day of week'). For a Monday-Friday run both readings coincide; they differ only if the 5 trading days are not one calendar week.
6. D20 also redefines `spread_at_signal` and `spread_at_fill` (B1-13b, B2-18, B2-19); only the `*_msc` part was requested, so the v1.05 wording 'Bid-ask spread in pips at signal trigger / at order execution' is unchanged. D15/D16/D22 (restart rows, partial fills, NOT_YET_EVALUABLE, hard-stop MISS mechanics) and the commission-unavailable handling in D6 are also not in this draft.
7. D12 makes an EXTERNAL closure halt the EA. v1.06 labels EXTERNAL as non-evidential but does not add a halt or an INVALID trigger to section 5.2 (not requested).
8. Section 1.1 ('preceding 20 closed M1 bars') was not edited; it is consistent with C1 (the 20 completed bars preceding the signal bar).

---

## Operator decisions D-1..D-4 (2026-10-14, before any evidential data)

| Item | Section | Change | Why it is not a re-tuning |
|---|---|---|---|
| 11 (D-1) | §6.2 | Open position's unrealised pips marked to the adverse side (Bid for long, Ask for short), added to the day's closed net pips | Resolves the open point of item 4; the 30.0-pip threshold is unchanged |
| 12 (D-2) | §3.1, §10 | ACCOUNT.md never contains its own hash; hash pair (git blob SHA1 + blob-content SHA256 at the freeze commit) recorded in tag message, STATUS.md, EA input InpAccountMdSha256, final report start line | Recording procedure only; no parameter |
| 13 (D-3) | §5.2 | Hard Stop Date = start + 8 weeks fixed at freeze; not reset after an operational restart | v1.05 ACCOUNT.md already fixes the hard stop at start + 8 weeks; this states it survives a restart |
| 14 (D-4) | §5.2 item 5, §7.1 | Close not initiated by the EA's exit logic = operational INVALID, consumes the single restart, incident log | Classification of an operational event; no statistical parameter |

Automated parameter check: `check_params.py` (this folder) on v1.05 (e7c54b0 PREREG.md + ACCOUNT.md) vs v1.06: all 24 registered parameters identical (`check_params_output.txt`).
