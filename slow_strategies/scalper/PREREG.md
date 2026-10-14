# Pre-Registration: MT5 M1 Breakout Demo Scalper (v1.01)

- **Document Version**: `1.01`
- **Pre-Registration Tag**: `scalper-prereg-v1` (to be created after ACCOUNT.md is complete)
- **Date**: 2026-10-14
- **Branch Target**: `scalper-prereg` (branched from `origin/main`)
- **Status**: NOT FROZEN until tag scalper-prereg-v1 is created after ACCOUNT.md is complete

---

## Change Log

### v1.01 (2026-10-14)
1. **Cost Model & PnL Accounting (§2.5)**: Updated net PnL formula to $\text{net\_pips} = \text{fill-based gross\_pips} - 2 \times \text{commission\_pips}$. Clarified that bid-ask spread is already embedded in executed fill prices (buys fill at Ask, sells fill at Bid; exit sell fills at Bid, exit buy fills at Ask) and must not be subtracted a second time. Defined `signal_price` as the relevant Ask (for BUY) or Bid (for SELL) quote at signal time, and `slippage_pips` as fill price vs the relevant quote at order dispatch only. Spread and slippage are logged as informational telemetry components. Updated $p_0$ derivation: $\bar{c} = \text{mean}(\text{spread\_at\_fill\_entry} + \text{spread effect at exit} + 2 \times \text{commission})$ measured on burn-in from fill data; documented algebra yielding $p_0 = 0.50 + \bar{c}/10.0$.
2. **Account Fields Migration (§3.1)**: Moved all account configuration fields to `slow_strategies/scalper/ACCOUNT.md` (template with REQUIRED blanks, including starting demo balance, start date, hard stop date = start date + 8 weeks, pre-start spread measurement results, news calendar file path, and SHA256). Mandated that `ACCOUNT.md` must be committed and its SHA256 recorded prior to the first burn-in trade.
3. **Pre-Start Spread Measurement (§3.3)**: Added requirement for 5 trading days of pre-start spread logging (no trading, 07:00–16:00 UTC) sampled at every completed M1 bar. Defined spread gate per symbol as $\min(0.3\text{ pip}, \text{60th percentile of observed session spread})$ and $S_{\text{pre-test}}$ as mean observed session spread per symbol. Both are frozen in `ACCOUNT.md` prior to burn-in. Updated §5.1.3 spread fidelity check to reference these values.
4. **Position Concurrency & Cluster-Robust Primary Test (§2.1, §4.2)**: Updated position concurrency to at most one open position globally across all symbols (not per symbol). Primary $t$-test is evaluated on per-`window_id` mean net pips (cluster = `window_id`), while the exact binomial test remains on individual trades. Explicitly stated the clustered SE assumption and derived effective sample size and statistical power ($83.04\%$) while keeping total trade count $N = 900$.
5. **Decision Criteria Split (§5)**: Partitioned Section 5 into:
   - §5.1 Statistical HIT / MISS: Co-primary tests (clustered $t$-test on per-`window_id` mean net pips and exact binomial on trades), spread fidelity check ($\bar{S}_{\text{realized}} \le 1.20 \times S_{\text{pre-test}}$), and target $N = 900$ completed before hard stop date.
   - §5.2 Operational INVALID: Non-statistical execution failures (unhandled crash, socket dropout, orphan position, non-trading risk limit breaker). Defined recovery policy: exactly one documented restart permitted from zero ($N = 0$) with burn-in redone; a second INVALID permanently closes the objective.
6. **Daily Risk Stop Revision (§6.2)**: Replaced percentage equity stop with a daily loss limit of 30 pips cumulative net per day. Maintained requirement for starting demo balance in `ACCOUNT.md`. Retained daily volume cap, consecutive error breaker, and external kill switch.
7. **Sigma Bounds & Burn-In Check (§4.2)**: Added analytical note that the 5-minute time stop compresses the outcome distribution such that true $\sigma \le 5.0$ pips (rendering the $\sigma = 5.0$ model conservative). Added a burn-in $\sigma$ empirical check ($s_{\text{burn}}$ calculated over the 100 burn-in trades, report-only, $N$ unchanged).
8. **News Calendar Mandate (§2.3.4)**: Required a committed news calendar file with path and SHA256 recorded in `ACCOUNT.md`. Maintained fallback fixed exclusion windows (`12:25–12:40` and `13:25–13:40 UTC`) strictly as a labelled degraded mode that must be disclosed in the final report.

### v1.00 (2026-10-14)
- Initial pre-registration document draft.

---

## 1. Hypothesis

### 1.1 Core Scientific Claim
An M1 price breakout beyond the 20-bar rolling price channel (highest high / lowest low of the preceding 20 closed M1 bars) contains sufficient short-horizon directional momentum on liquid major FX pairs (`EURUSD`, `USDJPY`) during core European/London trading sessions to overcome broker transaction costs and execution friction under a fixed symmetric $5.0$-pip take-profit (TP) and stop-loss (SL) bracket.

### 1.2 Formal Statistical Hypotheses
The evaluation is conducted across $N = 900$ consecutive post-burn-in completed round-trip trades. Two co-primary criteria are defined:

1. **Co-Primary 1: Win Rate ($p$) vs Break-Even Threshold ($p_0$)**
   - $H_0^{(1)}: p \le p_0$
   - $H_1^{(1)}: p > p_0$
   - **Test Statistic**: One-sided exact binomial test on success count $K \sim \text{Binomial}(N, p)$ with null probability $p_0$.

2. **Co-Primary 2: Cluster-Adjusted Net PnL ($\mu_{\text{net}}$)**
   - $H_0^{(2)}: \mu_{\text{net}} \le 0$
   - $H_1^{(2)}: \mu_{\text{net}} > 0$
   - **Test Statistic**: One-sided Student's $t$-test on per-`window_id` mean net pips (clustering by 5-minute time window `window_id`):
     $$t = \frac{\bar{x}_{\text{cluster}} - 0}{\text{SE}_{\text{cluster}}}$$

**Decision Rule**: Both null hypotheses ($H_0^{(1)}$ and $H_0^{(2)}$) must be rejected simultaneously at their adjusted significance level ($\alpha = 0.025$) for the test to declare a statistical HIT.

---

## 2. Fixed Strategy Design

The system configuration is frozen. No parameter optimization, indicator tuning, or rule alterations are permitted during or after data collection.

### 2.1 Symbols & Sizing
- **Eligible Symbols**: `EURUSD`, `USDJPY`.
- **Trade Volume**: Strictly `0.01` lot ($1,000$ base currency units) per trade.
- **Position Concurrency**: At most **one active open position globally** across all symbols (not per symbol). If an open position exists in `EURUSD`, no order may be opened in `USDJPY`, and vice versa.
- **Order Execution Type**: Direct market orders (`ORDER_TYPE_BUY`, `ORDER_TYPE_SELL`) with `TRADE_ACTION_DEAL`. No pending orders (`LIMIT`, `STOP`) are permitted.

### 2.2 Signal Generation
- **Timeframe**: M1 (1-minute bar series).
- **Lookback Window**: Prior 20 completed M1 bars ($[t-20, t-1]$). Current incomplete bar $t$ is strictly excluded from channel calculation.
- **Trigger Conditions**:
  - **BUY Signal**: The most recent bar close ($C_{t-1}$) is strictly greater than the maximum high of the preceding 20 bars:
    $$C_{t-1} > \max_{i=1..20} H_{t-i}$$
  - **SELL Signal**: The most recent bar close ($C_{t-1}$) is strictly less than the minimum low of the preceding 20 bars:
    $$C_{t-1} < \min_{i=1..20} L_{t-i}$$
- **Window Throttling**: At most one order signal is accepted per 5-minute time window globally (`window_id = floor(epoch_seconds / 300)`). If multiple breakout bars occur within the same 5-minute rolling window, only the first signal is dispatched; all subsequent signals in that window are dropped.
- **No Parameter Sweeps**: Lookback length is strictly fixed at 20 bars.

### 2.3 Entry Execution Filters
Before dispatching a trade, the following conditions must be satisfied; otherwise, the signal is dropped:
1. **Spread Filter**: Current bid-ask spread must be less than or equal to the frozen symbol spread gate ($\min(0.3\text{ pip}, \text{60th percentile of observed session spread})$ defined in Section 3.3) at the instant of signal generation AND at the instant immediately preceding broker order dispatch.
2. **Tick Staleness Filter**: Quote tick age $\le 500\text{ ms}$ relative to local observation time.
3. **Trading Session Filter**: Orders permitted strictly between `07:00:00 UTC` and `16:00:00 UTC`, Monday through Friday.
4. **High-Impact News Exclusion Filter**:
   - No order entries are permitted within 10 minutes before through 10 minutes after any scheduled high-impact economic announcement.
   - A static, immutable news calendar file must be committed prior to test start, with its path and SHA256 recorded in `ACCOUNT.md`.
   - *Degraded Fallback Mode*: If no external calendar file is provided, the test enters a labelled degraded mode with mandatory fixed exclusion windows of `12:25:00 - 12:40:00 UTC` and `13:25:00 - 13:40:00 UTC`. The final evaluation report must explicitly disclose the operation of degraded mode.

### 2.4 Exit Rules
Every executed position is governed by three mutually exclusive exit conditions:
1. **Take-Profit (TP)**: Fixed bracket at exactly $+5.0$ pips ($+50$ points) from actual fill price (`fill_price`).
2. **Stop-Loss (SL)**: Fixed bracket at exactly $-5.0$ pips ($-50$ points) from actual fill price (`fill_price`).
3. **Time-Based Stop**: Position duration is monitored. If neither TP nor SL has been triggered within exactly $5$ minutes ($300$ seconds) from position open time, the position is immediately liquidated at market.

### 2.5 Cost Model & PnL Accounting
For every completed round trip:
- **Gross PnL (pips)**:
  Computed directly from executed fill prices:
  - Long: $(\text{exit\_fill\_price} - \text{entry\_fill\_price}) / \text{pip\_size}$
  - Short: $(\text{entry\_fill\_price} - \text{exit\_fill\_price}) / \text{pip\_size}$
- **Net PnL (pips)**:
  $$\text{net\_pips} = \text{gross\_pips} - 2 \times \text{commission\_pips}$$
  *Rationale*: Spread is already embedded in executed fill prices (long positions enter at Ask and exit at Bid; short positions enter at Bid and exit at Ask). Subtracting spread separately would double-count transaction costs.
- **Telemetry Components (Informational Logging Only)**:
  - `signal_price`: The prevailing Ask quote (for BUY) or Bid quote (for SELL) at the exact timestamp of signal generation.
  - `slippage_pips`: Realized execution price delta between actual `fill_price` and the prevailing quote at order dispatch only:
    - Long entry: $(\text{fill\_price} - \text{dispatch\_ask}) / \text{pip\_size}$
    - Short entry: $(\text{dispatch\_bid} - \text{fill\_price}) / \text{pip\_size}$
  - `spread_at_signal`: Bid-ask spread in pips at signal trigger.
  - `spread_at_fill`: Bid-ask spread in pips at order execution.
  - `commission_pips`: Broker commission charged per turn, expressed in pips based on contract size.

### 2.6 Calibration Burn-In & Break-Even Win Rate ($p_0$)
1. **Burn-in Phase**: The first 100 executed trades ($N_{\text{burn}} = 100$) serve exclusively to empirically calibrate broker fee structures and friction.
2. **Burn-in Exclusion**: The initial 100 trades are strictly excluded from the formal evaluation sample ($N = 900$).
3. **Break-Even Win Rate Derivation ($p_0$)**:
   Let $\bar{c}$ denote the sample mean round-trip friction in pips measured on the 100 burn-in trades from fill data:
   $$\bar{c} = \frac{1}{N_{\text{burn}}} \sum_{i=1}^{N_{\text{burn}}} \left( \text{spread\_at\_fill\_entry}_i + \text{spread effect at exit}_i + 2 \times \text{commission\_pips}_i \right)$$
   Under symmetric $5.0$-pip TP ($W_{\text{gross}} = +5.0$) and $5.0$-pip SL ($L_{\text{gross}} = -5.0$) relative to the mid-quote:
   - Net gain on winning trade: $W_{\text{net}} = 5.0 - \bar{c}$
   - Net loss on losing trade: $L_{\text{net}} = 5.0 + \bar{c}$
   Setting expected net profit to zero:
   $$E[\text{Net PnL}] = p_0 \cdot W_{\text{net}} - (1 - p_0) \cdot L_{\text{net}} = 0$$
   $$p_0 (5.0 - \bar{c}) - (1 - p_0)(5.0 + \bar{c}) = 0$$
   $$p_0 (5.0 - \bar{c} + 5.0 + \bar{c}) - (5.0 + \bar{c}) = 0$$
   $$p_0 \cdot 10.0 = 5.0 + \bar{c} \implies p_0 = \frac{5.0 + \bar{c}}{10.0} = 0.50 + \frac{\bar{c}}{10.0}$$
4. **Freezing $p_0$**: Once computed on trade $100$, $p_0$ is frozen for the entirety of the subsequent $N = 900$ evaluation run. The pre-registered success threshold is $p_0 + 0.00$.

---

## 3. Data & Account Specification

To ensure realistic liquidity and execution quality, testing must run on a true ECN/STP demo infrastructure, not a synthetic demo server.

### 3.1 Account Environment Profile (ACCOUNT.md)
All specific account configuration parameters (broker, server, account number, base currency, leverage, starting balance, timeline, spread results, news calendar) are maintained in:
[ACCOUNT.md](file:///C:/Users/Abdul%20Qhahhar/Documents/mt5_exec_test_wt/slow_strategies/scalper/ACCOUNT.md)

> [!IMPORTANT]
> **Pre-Execution Requirement**: `ACCOUNT.md` must be completed and committed to the repository, with its Git commit hash and SHA256 checksum recorded, before the first burn-in trade is executed. Testing cannot commence until `ACCOUNT.md` is fully populated and committed.

### 3.2 Feed Restrictions & Smoke Exemption
- **No Synthetic Feeds**: Testing on `MetaQuotes-Demo` or synthetic quote feeds is strictly prohibited for evidential testing.
- **Plumbing & Smoke Exemption**: Pre-flight operational checks on `MetaQuotes-Demo` are permitted solely to verify socket connectivity, order dispatch pipelines, and CSV logging mechanics. Any trades executed during plumbing runs are explicitly flagged as non-evidential and excluded from the $N = 900$ dataset.

### 3.3 Pre-Start Spread Measurement Protocol
Prior to executing the first burn-in trade:
1. **Sampling Duration**: Spread telemetry must be logged across $5$ consecutive trading days (Monday–Friday) during the session window (`07:00:00` to `16:00:00 UTC`).
2. **Trading State**: Zero trades are executed during this measurement phase.
3. **Telemetry Frequency**: Bid and ask quotes are recorded at every completed M1 bar close.
4. **Parameter Calculation**:
   - **Spread Gate**: Defined per symbol as:
     $$\text{Spread Gate} = \min(0.3\text{ pip}, \text{60th percentile of observed session spread})$$
   - **Pre-Test Baseline Spread ($S_{\text{pre-test}}$)**: Defined per symbol as the sample mean observed session spread:
     $$S_{\text{pre-test}} = \frac{1}{K} \sum_{k=1}^K S_k$$
5. **Freezing**: Both values for `EURUSD` and `USDJPY` must be recorded and frozen in `ACCOUNT.md` prior to beginning burn-in.

---

## 4. Statistical Plan & Sample Size Arithmetic

### 4.1 Multiple Testing & Alpha Budget
- **Hypotheses Count**: $1$ core strategy hypothesis.
- **Co-Primary Endpoints**: $2$ statistical tests (Exact Binomial on trade win rate, and one-sided $t$-test on per-`window_id` mean net pips).
- **Family-Wise Error Rate ($\alpha$)**: Overall $\alpha = 0.05$.
- **Bonferroni Adjustment**:
  $$\alpha_{\text{adj}} = \frac{0.05}{2} = 0.025$$
  Each co-primary test is evaluated at $\alpha = 0.025$. This testing counter is independent and does not reuse or inherit from preceding `paper-mm` counters.

### 4.2 Sample Size Derivation: Clustered Net P&L Test
We test the primary hypothesis $H_0: \mu_{\text{net}} \le 0$ vs $H_1: \mu_{\text{net}} > 0$.

- **Target Net Edge ($\mu_1$)**: $+0.5$ pip net per trade.
- **Outcome Standard Deviation ($\sigma$)**: Modeled at $5.0$ pips (dictated by the symmetric $\pm 5.0$-pip TP/SL exit brackets).
  *Analytical Note on $\sigma$*: The 5-minute time stop closes trades at market before TP or SL is reached. Because $|x| < 5.0$ for time-stop exits, the true population standard deviation satisfies $\sigma \le 5.0$ pips. The assumption of $\sigma = 5.0$ pips is therefore mathematically conservative, as any compression in true variance strictly increases test power.
- **Burn-In Sigma Verification**: During the initial 100 burn-in trades, the sample standard deviation $s_{\text{burn}}$ is computed and documented in the final report to verify empirical dispersion against the $5.0$-pip baseline. This check is report-only; sample size $N = 900$ remains strictly fixed.
- **Significance Level ($\alpha$)**: $\alpha = 0.025$ (one-sided, Bonferroni-adjusted).
  $$z_\alpha = z_{0.025} = 1.95996 \approx 1.960$$
- **Target Statistical Power ($1 - \beta$)**: $80\%$ ($\beta = 0.20$).
  $$z_\beta = z_{0.20} = 0.84162 \approx 0.842$$

#### Exact Unclustered Formula
$$N_{\text{formula}} = \frac{(z_\alpha + z_\beta)^2 \cdot \sigma^2}{\mu_1^2} = \frac{(1.95996 + 0.84162)^2 \cdot (5.0)^2}{(0.5)^2} = (2.80158)^2 \times 100 = 7.84885 \times 100 \approx 784.89 \implies \mathbf{785\text{ trades}}$$

#### Clustered Standard Error & Effective Sample Size
- **Clustering Dimension**: 5-minute time window (`window_id`).
- **Cluster Structure**: Under the single global position rule (Section 2.1) and 5-minute signal throttling (Section 2.2), at most one trade can be initiated per 5-minute window globally. Because trades have a maximum duration of 5 minutes, an overwhelming majority of active windows contain exactly $1$ trade ($m \approx 1.0$).
- **Clustered Variance Inflation Factor (VIF)**:
  $$\text{VIF} = 1 + (m - 1)\rho$$
  where $m$ is the average cluster size and $\rho$ is the intra-cluster correlation.
- **Conservative Clustered SE Assumption**: Even if a minor fraction of windows contain consecutive trades such that $M \approx 850$ distinct clusters across $N = 900$ trades ($\text{VIF} \approx 900/850 \approx 1.059$):
  $$\text{SE}_{\text{cluster}} = \frac{\sigma}{\sqrt{M}} = \frac{5.0}{\sqrt{850}} \approx 0.1715\text{ pips}$$
  $$\bar{x}_{\text{crit}} = 0.0 + 1.95996 \times 0.1715 = 0.3361\text{ pips}$$
  $$z_\beta = \frac{0.3361 - 0.5000}{0.1715} = \frac{-0.1639}{0.1715} \approx -0.9557$$
  $$\text{Power} = 1 - \Phi(-0.9557) = \Phi(0.9557) = \mathbf{83.04\%}$$
  Even under conservative clustering, power remains comfortably above the $80\%$ target ($83.04\% > 80.0\%$).

#### Sample Size Specification & Difference
- **Pre-Registered Evaluation Sample**: $N = 900$ closed trades pooled across both symbols ($450$ trades per symbol).
- **Difference from Unclustered Formula**:
  $$N_{\text{fixed}} - N_{\text{formula}} = 900 - 785 = \mathbf{+115\text{ trades}} \quad (+14.65\%)$$

### 4.3 Statistical Power: Discrete Win Rate Test
Complementary evaluation of statistical power to detect true win rate $p_1 = 0.67$ against baseline null threshold $p_0 = 0.62$ ($\Delta = 0.05$):
- $\sigma_0 = \sqrt{0.62 \times 0.38 / 900} \approx 0.016179$
- $\sigma_1 = \sqrt{0.67 \times 0.33 / 900} \approx 0.015674$
- At $\alpha = 0.025$: $p_{\text{crit}} = 0.62 + 1.95996 \times 0.016179 = 0.65171 \implies k_{\text{crit}} = 587$ wins.
- $z_\beta = (0.65171 - 0.67) / 0.015674 \approx -1.1669 \implies \text{Power} = \Phi(1.1669) = \mathbf{87.84\%}$ (Exact Binomial: $\mathbf{87.87\%}$).

### 4.4 No Interim Peeking
- Statistical evaluation occurs exactly once upon reaching $N = 900$ completed trades.
- No interim alpha-spending or early stopping for efficacy/success is permitted.
- Early termination is allowed strictly for hard risk futility limits as specified in Section 6.

---

## 5. Decision Criteria

Evaluation outcomes are strictly partitioned into Statistical Outcomes (Section 5.1) and Operational Outcomes (Section 5.2).

### 5.1 Statistical HIT / MISS

#### 5.1.1 Criteria for HIT
The test is declared an unequivocal **HIT** if and only if ALL of the following statistical conditions are met upon completing $N = 900$ post-burn-in trades:
1. **Cluster-Adjusted Net PnL Test**: Primary $t$-test on per-`window_id` mean net pips achieves $\bar{x}_{\text{cluster}} > 0$ with one-sided $p$-value $< 0.025$.
2. **Win Rate Test**: Exact binomial test on the $N = 900$ trades achieves $p$-value $< 0.025$ against the frozen null threshold $p_0$.
3. **Spread Fidelity Check**: Realized average bid-ask spread across all executed fills satisfies:
   $$\bar{S}_{\text{realized}} \le 1.20 \times S_{\text{pre-test}}$$
   evaluated individually for `EURUSD` and `USDJPY` against their respective pre-test values frozen in `ACCOUNT.md`.
4. **Timeline Compliance**: Target sample size $N = 900$ completed on or before the Hard Stop Date recorded in `ACCOUNT.md`.

#### 5.1.2 Criteria for MISS
The test is declared a **MISS** if any of the following occur:
1. Either of the primary statistical tests does not achieve significance ($p \ge 0.025$) or $\bar{x}_{\text{cluster}} \le 0$ at $N = 900$.
2. Realized average spread on either symbol exceeds $1.20 \times S_{\text{pre-test}}$.
3. Target sample size $N = 900$ is not reached on or before the Hard Stop Date recorded in `ACCOUNT.md`.
4. The test is halted due to a breach of the daily net loss stop (Section 6.2).

**Consequence of a MISS**:
A declaration of MISS permanently closes the scalper objective for this breakout signal. No post-hoc re-tuning of parameters, alteration of indicator lookback, re-filtering of data, or secondary testing on the same dataset is permitted.

### 5.2 Operational INVALID

An evaluation run is declared **INVALID** if execution is terminated or contaminated by non-statistical infrastructure anomalies:
1. **Unhandled Process Crash**: EA unhandled exception, fatal memory fault, or MT5 terminal crash.
2. **Communications Drop**: Sustained terminal disconnect or broker socket dropout causing lost fills or unrecorded orders.
3. **Orphaned Position**: Occurrence of an unpersisted, untracked, or orphaned open position in MT5.
4. **Operational Risk Breaker**: Execution halt triggered by non-trading hardware/environment errors (e.g. 5 consecutive socket/order dispatch errors under Section 6.3).

**Recovery Policy for INVALID**:
- An operational INVALID allows **exactly one documented restart**.
- Upon an initial INVALID, the entire run is reset to zero ($N = 0$), root-cause remediation is documented, and the 100-trade burn-in phase ($N_{\text{burn}} = 100$) must be re-executed from scratch.
- If a **second operational INVALID** occurs, the test is terminated and the scalper objective is permanently closed.

---

## 6. Hard Risk Limits & Circuit Breakers

The test harness must enforce the following non-discretionary safety halts:

1. **Daily Volume Cap**: Maximum of $20$ completed trades per day per symbol. Upon reaching 20 trades on a symbol, all subsequent signals for that symbol are dropped until 00:00 UTC.
2. **Daily Net Loss Stop**: If cumulative net loss within a single calendar day reaches or exceeds **$30.0$ pips**, the EA liquidates any active open position immediately and transitions to `STATE_HALTED` until 00:00 UTC of the next trading day. The starting demo balance is documented in `ACCOUNT.md` for baseline account tracking.
3. **Consecutive Error Breaker**: If $5$ consecutive order dispatches result in an error or broker reject, execution halts immediately and requires operator investigation.
4. **External Kill Switch**: The test harness polls for the existence of `kill_switch.txt` in the terminal common directory every cycle. If the file is detected, all trading halts immediately and open positions are closed.

---

## 7. Logging & Telemetry Specification

All execution telemetry must be recorded to append-only CSV files in `%APPDATA%\MetaQuotes\Terminal\Common\Files\`.

### 7.1 Field Definitions
The fields conform to the established `trades.csv` and `roundtrips.csv` conventions:

| Field Name | Type | Description |
| :--- | :--- | :--- |
| `ticket` | Int64 | MT5 position / deal ticket identifier |
| `symbol` | String | `EURUSD` or `USDJPY` |
| `side` | String | `BUY` or `SELL` |
| `signal_time_msc` | Int64 | Epoch millisecond timestamp of breakout bar close |
| `dispatch_time_msc` | Int64 | Epoch millisecond timestamp of `OrderSend` invocation |
| `fill_time_msc` | Int64 | Epoch millisecond timestamp of broker execution deal |
| `signal_price` | Double | Prevailing Ask (BUY) or Bid (SELL) quote at signal close |
| `fill_price` | Double | Actual executed fill price |
| `spread_at_signal` | Double | Bid-ask spread in pips at signal trigger |
| `spread_at_fill` | Double | Bid-ask spread in pips at order execution |
| `slippage_pips` | Double | Difference between `fill_price` and dispatch quote in pips |
| `commission_pips` | Double | Broker commission deducted, expressed in pips |
| `exit_reason` | String | Exit classification: `TAKE_PROFIT`, `STOP_LOSS`, or `TIME_STOP` |
| `gross_pips` | Double | Fill-based price difference in pips |
| `net_pips` | Double | Gross pips minus round-turn commission ($2 \times \text{commission\_pips}$) |
| `window_id` | Int64 | Integer 5-minute bucket ID (`floor(time / 300)`) |

---

## 8. Known Limitations & Design Flags

The user and research team acknowledge the following inherent constraints:

1. **Demo Execution vs Live Venue Realities**:
   - Broker demo servers do not replicate institutional ECN matching engine matching dynamics.
   - Demo environments provide synthetic fill confirmations without modeling queue position or market depth consumption.
2. **Zero Market Impact Assumption**:
   - The test assumes $0.01$ lot orders produce zero market impact. This holds for small lot sizes but cannot be generalized to institutional sizes.
3. **Execution Latency from Host Environment**:
   - Order routing latency is subject to the network connection between the user's host PC and the broker's trade access point.
4. **Economic News Calendar Dependency**:
   - If an automated calendar integration is unavailable, reliance on the static fallback windows (`12:25-12:40` and `13:25-13:40 UTC`) operates in degraded mode and leaves the system vulnerable to unscheduled economic events or European morning releases (e.g., 08:00 UTC UK/German data).
5. **Fixed Design Flags & Vulnerabilities (Noted for Review)**:
   - *Spread Gate Mismatch*: If retail demo spreads routinely exceed the spread gate, signal starvation may occur, threatening completion of $N = 900$ within the 8-week timeline.
   - *Time-Stop Asymmetry*: Closing trades at market after 5 minutes introduces variable exit prices between $-5.0$ and $+5.0$ pips, making the binary break-even formula $p_0 = 0.50 + \bar{c}/10.0$ an analytical approximation.
   - *High Break-Even Hurdle*: In high-commission conditions, $\bar{c}$ may exceed $0.8$ pips, requiring $p_0 \ge 58\%$.

---

## 9. Freeze Statement

Following the completion of `ACCOUNT.md` and creation of git tag `scalper-prereg-v1`:
- This document and all operational parameters (lookback period, TP/SL points, time stops, filters, risk limits, statistical test specifications) are strictly frozen.
- No modifications, amendments, or parameter optimizations are permitted.
- Any change after this tag invalidates the test as confirmatory and demotes it to exploratory.
- Any alteration to trading logic or testing scope constitutes an invalidation of this pre-registration, requiring a new pre-registration version (`v2.00`) and a complete reset of the test counter and burn-in phase.

---

## 10. Tamper-Evidence & Integrity Verification

To guarantee cryptographic immutability, the SHA256 hash of this document is recorded upon freezing.

```
File: slow_strategies/scalper/PREREG.md
Version: 1.01
Status: NOT FROZEN until tag scalper-prereg-v1 is created after ACCOUNT.md is complete
```
