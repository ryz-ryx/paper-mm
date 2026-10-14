# Pre-Registration: MT5 M1 Breakout Demo Scalper (v1.00)

- **Document Version**: `1.00`
- **Pre-Registration Tag**: `scalper-prereg-v1`
- **Date**: 2026-10-14
- **Branch Target**: `scalper-prereg` (branched from `origin/main`)
- **Status**: FROZEN PRIOR TO CALIBRATION & EXECUTION

---

## 1. Hypothesis

### 1.1 Core Scientific Claim
An M1 price breakout beyond the 20-bar rolling price channel (highest high / lowest low of the preceding 20 closed M1 bars) contains sufficient short-horizon directional momentum on liquid major FX pairs (`EURUSD`, `USDJPY`) during core European/London trading sessions to overcome bid-ask spread, broker commissions, and execution slippage under a fixed symmetric $5.0$-pip take-profit (TP) and stop-loss (SL) bracket.

### 1.2 Formal Statistical Hypotheses
The evaluation is conducted across $N = 900$ consecutive post-burn-in completed round-trip trades. Two co-primary criteria are defined:

1. **Co-Primary 1: Win Rate ($p$) vs Break-Even Threshold ($p_0$)**
   - $H_0^{(1)}: p \le p_0$
   - $H_1^{(1)}: p > p_0$
   - **Test Statistic**: One-sided exact binomial test on success count $K \sim \text{Binomial}(N, p)$ with null probability $p_0$.

2. **Co-Primary 2: Net PnL per Trade ($\mu_{\text{net}}$)**
   - $H_0^{(2)}: \mu_{\text{net}} \le 0$
   - $H_1^{(2)}: \mu_{\text{net}} > 0$
   - **Test Statistic**: One-sided Student's $t$-test on net pips per completed round-trip trade:
     $$t = \frac{\bar{x}_{\text{net}} - 0}{s / \sqrt{N}}$$

**Decision Rule**: Both null hypotheses ($H_0^{(1)}$ and $H_0^{(2)}$) must be rejected simultaneously at their adjusted significance level for the test to declare a HIT.

---

## 2. Fixed Strategy Design

The system configuration is frozen. No parameter optimization, indicator tuning, or rule alterations are permitted during or after data collection.

### 2.1 Symbols & Sizing
- **Eligible Symbols**: `EURUSD`, `USDJPY`.
- **Trade Volume**: Strictly `0.01` lot ($1,000$ base currency units) per trade.
- **Position Concurrency**: At most one active open position at a time per symbol.
- **Order Execution Type**: Direct market orders (`ORDER_TYPE_BUY`, `ORDER_TYPE_SELL`) with `TRADE_ACTION_DEAL`. No pending orders (`LIMIT`, `STOP`) are permitted.

### 2.2 Signal Generation
- **Timeframe**: M1 (1-minute bar series).
- **Lookback Window**: Prior 20 completed M1 bars ($[t-20, t-1]$). Current incomplete bar $t$ is strictly excluded from channel calculation.
- **Trigger Conditions**:
  - **BUY Signal**: The most recent bar close ($C_{t-1}$) is strictly greater than the maximum high of the preceding 20 bars:
    $$C_{t-1} > \max_{i=1..20} H_{t-i}$$
  - **SELL Signal**: The most recent bar close ($C_{t-1}$) is strictly less than the minimum low of the preceding 20 bars:
    $$C_{t-1} < \min_{i=1..20} L_{t-i}$$
- **Window Throttling**: At most one order signal is accepted per 5-minute time window per symbol (`window_id = floor(epoch_seconds / 300)`). If multiple breakout bars occur within the same 5-minute rolling window, only the first signal is dispatched; all subsequent signals in that window are ignored.
- **No Parameter Sweeps**: Lookback length is strictly fixed at 20 bars.

### 2.3 Entry Execution Filters
Before dispatching a trade, the following conditions must be satisfied; otherwise, the signal is dropped:
1. **Spread Filter**: Current bid-ask spread must be $\le 0.3$ pip ($3.0$ points on a 5-digit broker) at the instant of signal generation AND at the instant immediately preceding broker order dispatch.
2. **Tick Staleness Filter**: Quote tick age $\le 500\text{ ms}$ relative to local observation time.
3. **Trading Session Filter**: Orders permitted strictly between `07:00:00 UTC` and `16:00:00 UTC`, Monday through Friday.
4. **High-Impact News Exclusion Filter**:
   - No order entries are permitted within 10 minutes before through 10 minutes after any scheduled high-impact economic announcement.
   - A static, immutable news calendar file must be committed prior to the commencement of data collection.
   - *Design Fallback*: In the absence of a committed calendar file, the mandatory exclusion windows are `12:25:00 - 12:40:00 UTC` (covering 12:30 UTC US releases) and `13:25:00 - 13:40:00 UTC` (covering 13:30 UTC US releases).

### 2.4 Exit Rules
Every executed position is governed by three mutually exclusive exit conditions:
1. **Take-Profit (TP)**: Fixed bracket at exactly $+5.0$ pips ($+50$ points) from actual fill price (`fill_price`).
2. **Stop-Loss (SL)**: Fixed bracket at exactly $-5.0$ pips ($-50$ points) from actual fill price (`fill_price`).
3. **Time-Based Stop**: Position duration is monitored. If neither TP nor SL has been triggered within exactly $5$ minutes ($300$ seconds) from position open time, the position is immediately liquidated at market.

### 2.5 Cost Model & PnL Accounting
For every completed round trip:
- **Gross PnL (pips)**:
  - Long: $(\text{exit\_fill\_price} - \text{entry\_fill\_price}) / \text{pip\_size}$
  - Short: $(\text{entry\_fill\_price} - \text{exit\_fill\_price}) / \text{pip\_size}$
- **Friction & Transaction Costs**:
  - Recorded spread at entry and exit ($S_{\text{entry}}, S_{\text{exit}}$).
  - Commission cost per trade expressed in pips ($C_{\text{pip}}$) derived from the broker contract specification.
  - Realized entry slippage vs signal price: $\text{Slip}_{\text{entry}} = (\text{fill\_price} - \text{signal\_price}) / \text{pip\_size}$ (for buys).
- **Net PnL Formula (pips)**:
  $$\text{Net P\&L} = \text{gross} - \text{spread} - 2 \times \text{comm} - \text{slippage\_in} - \text{slippage\_out}$$
  where:
  - $\text{gross}$: gross price difference in pips.
  - $\text{spread}$: half-turn or full-turn bid-ask spread charged at execution.
  - $2 \times \text{comm}$: round-turn broker commission (entry + exit commission) converted to pips.
  - $\text{slippage\_in}$: realized entry slippage $(\text{fill\_price} - \text{signal\_price}) / \text{pip\_size}$ (for buys) or $(\text{signal\_price} - \text{fill\_price}) / \text{pip\_size}$ (for sells).
  - $\text{slippage\_out}$: realized exit slippage $(\text{exit\_fill\_price} - \text{exit\_target\_price}) / \text{pip\_size}$.

### 2.6 Calibration Burn-In & Break-Even Win Rate ($p_0$)
1. **Burn-in Phase**: The first 100 executed trades ($N_{\text{burn}} = 100$) serve exclusively to empirically calibrate broker fee structures and friction.
2. **Burn-in Exclusion**: The initial 100 trades are strictly excluded from the formal evaluation sample ($N = 900$).
3. **Break-Even Win Rate Formula**:
   Under symmetric $5.0$-pip TP ($W_{\text{gross}} = +5.0$) and $5.0$-pip SL ($L_{\text{gross}} = -5.0$), letting $\bar{c}$ denote the sample mean total friction cost per trade in pips (spread + commission + slippage) observed over the burn-in sample:
   - Net gain on winning trade: $W_{\text{net}} = 5.0 - \bar{c}$
   - Net loss on losing trade: $L_{\text{net}} = 5.0 + \bar{c}$
   Setting expected net profit to zero:
   $$E[\text{Net PnL}] = p_0 \cdot W_{\text{net}} - (1 - p_0) \cdot L_{\text{net}} = 0$$
   $$p_0 (5.0 - \bar{c}) - (1 - p_0)(5.0 + \bar{c}) = 0$$
   $$p_0 \cdot 10.0 = 5.0 + \bar{c} \implies p_0 = \frac{5.0 + \bar{c}}{10.0} = 0.50 + \frac{\bar{c}}{10.0}$$
4. **Freezing $p_0$**: Once computed on trade $100$, $p_0$ is frozen for the entirety of the subsequent $N = 900$ evaluation run. The pre-registered success threshold is $p_0 + 0.00$.

---

## 3. Data & Account Specification

To ensure realistic liquidity and execution quality, testing must run on a true ECN/STP demo infrastructure, not a synthetic demo server.

### 3.1 Account Environment Profile (User-Configured Prior to Run)
The testing account must be a demo account on a broker that offers raw/ECN spreads (<0.3 pip typical on EURUSD during European/London trading hours). The following configuration parameters must be supplied by the operator prior to test launch:

- **Broker Name**: `[ REQUIRED: ____________________ ]`
- **Server Name**: `[ REQUIRED: ____________________ ]`
- **Account Number**: `[ REQUIRED: ____________________ ]`
- **Account Type (Raw Spread / ECN / STP)**: `[ REQUIRED: ____________________ ]`
- **Account Base Currency**: `[ REQUIRED: ____________________ ]`
- **Account Leverage**: `[ REQUIRED: ____________________ ]`
- **Hard Stop Expiration Date (UTC)**: `[ REQUIRED: ____________________ ]`
- **Smoke Run Status on this Specific Account**: `[ REQUIRED: PASSED / NOT RUN ]`

> [!IMPORTANT]
> **Smoke Test Prerequisite**: The full MT5 ExecTest smoke test suite (`T1` through `T6`) must have executed and PASSED on this specific account before data collection begins. If the smoke test suite did not pass on this specific account, the test cannot start.

### 3.2 Feed Restrictions
- **No Synthetic Feeds**: Testing on `MetaQuotes-Demo` or synthetic quote feeds is strictly prohibited for evidential testing.
- **Plumbing & Smoke Exemption**: Pre-flight operational checks on `MetaQuotes-Demo` are permitted solely to verify socket connectivity, order dispatch pipelines, and CSV logging mechanics. Any trades executed during plumbing runs are explicitly flagged as non-evidential and excluded from the $N = 900$ dataset.

---

## 4. Statistical Plan & Sample Size Arithmetic

### 4.1 Multiple Testing & Alpha Budget
- **Hypotheses Count**: $1$ core strategy hypothesis.
- **Co-Primary Endpoints**: $2$ statistical tests (Exact Binomial on win rate, and one-sided $t$-test on mean net pips).
- **Family-Wise Error Rate ($\alpha$)**: Overall $\alpha = 0.05$.
- **Bonferroni Adjustment**:
  $$\alpha_{\text{adj}} = \frac{0.05}{2} = 0.025$$
  Each co-primary test is evaluated at $\alpha = 0.025$. This testing counter is independent and does not reuse or inherit from preceding `paper-mm` counters.

### 4.2 Sample Size Derivation: Continuous Net P&L Test
We test the primary hypothesis $H_0: \mu_{\text{net}} \le 0$ vs $H_1: \mu_{\text{net}} > 0$.

- **Target Net Edge ($\mu_1$)**: $+0.5$ pip net per trade.
- **Outcome Standard Deviation ($\sigma$)**: $5.0$ pips (dictated by the symmetric $\pm 5.0$-pip TP/SL exit brackets).
- **One-Sided Significance Level ($\alpha$)**: $\alpha = 0.025$ (Bonferroni-adjusted for two co-primary tests from family-wise $\alpha = 0.05$).
  $$z_\alpha = z_{0.025} = 1.95996 \approx 1.960$$
- **Target Statistical Power ($1 - \beta$)**: $80\%$ ($\beta = 0.20$).
  $$z_\beta = z_{0.20} = 0.84162 \approx 0.842$$

#### Exact Sample Size Formula
$$N_{\text{formula}} = \frac{(z_\alpha + z_\beta)^2 \cdot \sigma^2}{\mu_1^2} = \frac{(1.95996 + 0.84162)^2 \cdot (5.0)^2}{(0.5)^2} = (2.80158)^2 \times 100 = 7.84885 \times 100 \approx 784.89 \implies \mathbf{785\text{ trades}}$$

#### Sample Size Specification & Difference
- **Pre-Registered Evaluation Sample**: $N = 900$ closed trades pooled across both symbols ($450$ trades per symbol).
- **Difference from Minimum Formula**:
  $$N_{\text{fixed}} - N_{\text{formula}} = 900 - 785 = \mathbf{+115\text{ trades}} \quad (+14.65\%)$$
- **Statistical Power at $N = 900$**:
  - Standard Error of the mean: $\text{SE} = \sigma / \sqrt{N} = 5.0 / \sqrt{900} = 5.0 / 30 = 0.16667$ pips.
  - Critical mean threshold: $\bar{x}_{\text{crit}} = 0.0 + 1.95996 \times 0.16667 = 0.32666$ pips.
  - Standardized distance under $H_1$: $z_\beta = (0.32666 - 0.50000) / 0.16667 = -1.0400$.
  - Achieved statistical power: $\text{Power} = 1 - \Phi(-1.0400) = \Phi(1.0400) = \mathbf{85.08\%}$.
  *(Note: If tested per symbol individually at $N=450$, $\text{SE} = 5.0/\sqrt{450} \approx 0.2357$, critical mean $= 0.4619$, $z_\beta = -0.1616$, giving power $56.4\%$. Hence the confirmatory test pools both symbols to ensure power $\ge 80\%$.)*

### 4.3 Statistical Power: Discrete Win Rate Test
Complementary evaluation of statistical power to detect true win rate $p_1 = 0.67$ against baseline null threshold $p_0 = 0.62$ ($\Delta = 0.05$):
- $\sigma_0 = \sqrt{0.62 \times 0.38 / 900} \approx 0.016179$
- $\sigma_1 = \sqrt{0.67 \times 0.33 / 900} \approx 0.015674$
- At $\alpha = 0.025$: $p_{\text{crit}} = 0.62 + 1.95996 \times 0.016179 = 0.65171 \implies k_{\text{crit}} = 587$ wins.
- $z_\beta = (0.65171 - 0.67) / 0.015674 \approx -1.1669 \implies \text{Power} = \Phi(1.1669) = \mathbf{87.84\%}$ (Exact Binomial: $\mathbf{87.87\%}$).
- At conservative $\alpha = 0.010$: $p_{\text{crit}} = 0.65764 \implies k_{\text{crit}} = 592$ wins, $z_\beta = -0.7886 \implies \text{Power} = \mathbf{78.48\%}$ (Exact Binomial: $\mathbf{77.22\%}$).

### 4.4 No Interim Peeking
- Statistical evaluation occurs exactly once upon reaching $N = 900$ completed trades.
- No interim alpha-spending or early stopping for efficacy/success is permitted.
- Early termination is allowed strictly for hard risk futility limits as specified in Section 6.

---

## 5. HIT / MISS Decision Criteria

### 5.1 Criteria for HIT
The test is declared an unequivocal **HIT** if and only if ALL of the following conditions are met upon completing $N = 900$ post-burn-in trades:
1. **Statistical Significance on Primary Test**: Realized net P&L is strictly positive ($\bar{x}_{\text{net}} > 0$) with one-sided Student's $t$-test $p$-value $< 0.025$, and the win rate achieves $p < 0.025$ on the exact binomial test.
2. **Spread Fidelity**: Realized average bid-ask spread across all fills is within $20\%$ of the pre-test estimate:
   $$\bar{S}_{\text{realized}} \le 1.20 \times \bar{S}_{\text{pre-test}}$$
3. **Execution & Operational Integrity**: Zero unhandled crashes, zero terminal disconnect dropouts, and zero orphaned positions throughout the entire $N = 900$ evaluation run.

### 5.2 Criteria for MISS
The test is declared a **MISS** if any of the following occur:
1. Either of the primary statistical tests fails to achieve significance ($p \ge 0.025$) or $\bar{x}_{\text{net}} \le 0$ at $N = 900$.
2. Realized average spread exceeds the pre-test estimate by more than $20\%$ ($\bar{S}_{\text{realized}} > 1.20 \times \bar{S}_{\text{pre-test}}$).
3. Any unhandled EA crash, abnormal abort, or unpersisted orphaned position occurs.
4. Target sample size $N = 900$ is not reached by the pre-registered Hard Stop Expiration Date.
5. The test is aborted due to a breach of any hard risk limit in Section 6.

**Consequence of a MISS**:
A declaration of MISS permanently closes the scalper objective for this breakout signal. No post-hoc re-tuning of parameters, alteration of indicator lookback, re-filtering of data, or secondary testing on the same dataset is permitted.

---

## 6. Hard Risk Limits & Circuit Breakers

The test harness must enforce the following non-discretionary safety halts:

1. **Daily Volume Cap**: Maximum of $20$ completed trades per day per symbol. Upon reaching 20 trades on a symbol, all subsequent signals for that symbol are dropped until 00:00 UTC.
2. **Daily Equity Loss Stop**: If cumulative intraday equity loss reaches or exceeds $5.0\%$ of starting demo balance, the EA liquidates any open positions immediately and transitions to `STATE_HALTED` until the next calendar day.
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
| `signal_price` | Double | Close price of breakout bar triggering signal |
| `fill_price` | Double | Actual executed fill price |
| `spread_at_signal` | Double | Bid-ask spread in pips at signal trigger |
| `spread_at_fill` | Double | Bid-ask spread in pips at order execution |
| `slippage_pips` | Double | Difference between `fill_price` and `signal_price` in pips |
| `commission` | Double | Broker commission deducted, expressed in pips |
| `exit_reason` | String | Exit classification: `TAKE_PROFIT`, `STOP_LOSS`, or `TIME_STOP` |
| `gross_pips` | Double | Raw price difference in pips |
| `net_pips` | Double | Gross pips minus realized spread, commission, and slippage |
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
   - If an automated calendar integration is unavailable, reliance on the static fallback windows (`12:25-12:40` and `13:25-13:40 UTC`) may leave the system vulnerable to unscheduled economic events or European morning releases (e.g., 08:00 UTC UK/German data).
5. **Fixed Design Flags & Vulnerabilities (Noted for Review)**:
   - *Spread Gate Mismatch*: The entry filter enforces spread $\le 0.3$ pip. On many retail demo feeds, `EURUSD` and `USDJPY` spreads routinely fluctuate between $0.4$ and $1.0$ pip, which may induce heavy signal starvation and prevent reaching $N = 900$.
   - *Time-Stop Asymmetry*: Closing trades at market after 5 minutes breaks the strict symmetry of the $5.0$-pip TP/SL bracket, altering the distribution of winning vs losing trades and rendering the binary break-even formula an approximation.
   - *Symmetric Break-Even Shift*: In high-friction conditions (e.g. commission $\approx 0.5$ pip, spread $\approx 0.3$ pip, slippage $\approx 0.1$ pip), total cost $\bar{c} \approx 0.9$ pip, pushing $p_0$ to $59\%$, demanding an exceptionally high hit rate from a simple M1 momentum breakout.

---

## 9. Freeze Statement

Following the initial commit of this document tagged `scalper-prereg-v1`:
- This document and all operational parameters (lookback period, TP/SL points, time stops, filters, risk limits, statistical test specifications) are strictly frozen.
- No modifications, amendments, or parameter optimizations are permitted.
- Any change after this tag invalidates the test as confirmatory and demotes it to exploratory.
- Any alteration to trading logic or testing scope constitutes an invalidation of this pre-registration, requiring a new pre-registration version (`v2.00`) and a complete reset of the test counter and burn-in phase.

---

## 10. Tamper-Evidence & Integrity Verification

To guarantee cryptographic immutability, the SHA256 hash of this document is recorded in the git commit message upon freezing.

```
File: slow_strategies/scalper/PREREG.md
Status: FROZEN
Tag: scalper-prereg-v1
```
