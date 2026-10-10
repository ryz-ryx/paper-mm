# MT5 Demo Execution Quality Report: 7-Day Benchmark

**Generated:** 2026-10-10 17:17:59 UTC  
**Current Session:** Market closed  
**Safety Status:** Active | Demo Account Verified | Equity Drawdown < 50 EUR | Cap: 40 orders/day  

---

## 1. Symbol Eligibility & Untestable Status

Per protocol requirement 1, only **EURUSD** and **USDJPY** are actively traded. All other instruments are formally documented as UNTESTABLE:

| Symbol | Asset Class | Status | Specific Reason |
| :--- | :---: | :---: | :--- |
| **EURUSD** | FX | **ACTIVE** | Tradeable under 1:1 account leverage (margin fits EUR 1,000 equity) |
| **USDJPY** | FX | **ACTIVE** | Tradeable under 1:1 account leverage (margin fits EUR 1,000 equity) |
| **GBPUSD** | FX | **UNTESTABLE** | Insufficient margin: requires ~1,182 EUR > 1,000 EUR equity under 1:1 leverage |
| **XAUUSD** | Commodity | **UNTESTABLE** | Insufficient margin: 0.01 lot (1 oz) requires ~3,747 EUR > 1,000 EUR equity under 1:1 leverage |
| **US500** | Index CFD | **UNTESTABLE** | Broker trading disabled (trade_mode=0) and volume_min 0.1 > 0.01 lot safety limit |
| **DE40** | Index CFD | **UNTESTABLE** | Broker trading disabled (trade_mode=0) and volume_min 0.1 > 0.01 lot safety limit |

---

## 2. Order Parameters & Execution Mode Audit

| Symbol | `trade_exemode` | Mode Description | `filling_mode` | Request `deviation` | Request `price` Used | Fills at Requested Price Guaranteed? |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **EURUSD** | `2` | `SYMBOL_TRADE_EXECUTION_MARKET` | `1` (FOK) | 20 pts | Ask (Buy) / Bid (Sell) | **NO** — Market execution executes at current broker market price; request price is advisory |
| **USDJPY** | `2` | `SYMBOL_TRADE_EXECUTION_MARKET` | `1` (FOK) | 20 pts | Ask (Buy) / Bid (Sell) | **NO** — Market execution executes at current broker market price; request price is advisory |

> [!NOTE]
> **Execution Guarantee:** Under `SYMBOL_TRADE_EXECUTION_MARKET` (mode 2), fills at the requested price are **never guaranteed** by the execution mode. The broker fills at the prevailing market price upon arrival. Slippage can occur even if deviation is specified.

---

## 3. Execution Quality Metrics & Slippage Breakdown

**Total Orders Logged:** 13 | **Total Completed Round Trips:** 5 valid (1 pre-filter trip excluded)

### Two Cost Measures per Round Trip:
1. **Fill-to-Fill Cost:** Pure price execution difference $-(P_{\text{sell}} - P_{\text{buy}})$.
2. **Mid-Adjusted Cost:** Signed $(P_{\text{buy}} - M_{\text{entry}}) + (M_{\text{exit}} - P_{\text{sell}})$, minus nothing else.

### Slippage Metrics per Fill:
1. **Execution Slippage:** Fill price vs prevailing Bid/Ask at `deal.time_msc` (looked up from `copy_ticks_range`). Result: **0 of 5 trips (0.0%)** have nonzero execution slippage.
2. **Decision-to-Fill Drift:** Fill price vs Bid/Ask at decision quote at send. Result: **2 of 5 trips (40.0%)** have nonzero drift.

> [!NOTE]
> **Historical Trips Recomputed:** All 5 historical trips have been recomputed with corrected clock offset ($-722.4\text{ ms}$) and marked with `age_uncorrected=true` in `roundtrips.csv`.

**Clock Offset Estimation (P2-1 Protocol):** Estimated offset = **-722.4 ms** (rolling 5th percentile of local_return - server_deal) | Median = **-691.0 ms** | Jitter (P95 - P5) = **90.4 ms**  
*(Online rolling offset applied to stale-tick gate at 500 ms threshold and to snapshot_age_ms)*

### Slippage by Corrected Snapshot Age at Send:

| Metric | Corrected Snapshot Age < 500 ms | Corrected Snapshot Age >= 500 ms | Overall Valid Trips |
| :--- | :---: | :---: | :---: |
| **Sample Size (n trips)** | 0 | 5 | 5 |
| **Median Snapshot Age (ms)** | - | 1096.4 ms | 1096.4 ms |
| **Trips with Nonzero Drift** | - | 2 (40.0%) | 2 (40.0%) |
| **Execution Slippage vs Prevailing Tick** | 0.0 pts (all fills matched quote) | 0.0 pts (all fills matched quote) | **0.0 pts (0% execution slip)** |

### Exit Gate Telemetry:

- **Median Exit Gate Wait:** 0.0 ms
- **Trips with Zero-Spread / Crossed at Exit:** 1 of 5 (Trip 5 had zero spread at exit snapshot)

### Summary by Symbol:

| Symbol | n Trips | Spread Med (pts) | Exec Slip Med (pts) | Drift Med (pts) | F2F Cost Med (EUR) | Mid-Adj Cost Med (EUR) | Mid-Adj Cost (bps) | Latency Med (ms) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **EURUSD** | 0 | - | - | - | - | - | - | - |
| **USDJPY** | 5 | 1.0 | +0.0 | +0.0 | 0.0113 | 0.0085 | 0.09 | 27.3 |

### Breakdown by Liquidity Session:

| Session | n Orders | Symbols Traded | Median Latency (ms) | Median Mid-Adj Cost (bps) |
| :--- | :---: | :---: | :---: | :---: |
| **New York** | 13 | EURUSD, USDJPY | 27.3 ms | 0.09 bps |

---

## 4. Tick Distribution & Synthetic Feed Audit (Requirements 3 & 4)

> [!WARNING]
> **SYNTHETIC FEED DISCLOSURE:** This demo feed is synthetic (about 53% zero-spread ticks on EURUSD and 9% on USDJPY) and its costs are not evidence for any real broker.

### Share of Zero-Spread Ticks (Bid == Ask) by Session (1-Hour Sample):

| Symbol | Session | Sample Ticks | Zero-Spread Ticks | Zero-Spread Share (%) | Mean Spread (All Ticks) | Mean Spread (Spread > 0) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: |
| **EURUSD** | Asia | 5,821 | 2,832 | **48.7%** | 0.51 pts | 1.00 pts |
| **EURUSD** | London | 14,721 | 8,174 | **55.5%** | 0.45 pts | 1.00 pts |
| **EURUSD** | New York | 18,506 | 10,056 | **54.3%** | 0.46 pts | 1.00 pts |
| **USDJPY** | Asia | 8,622 | 490 | **5.7%** | 2.20 pts | 2.33 pts |
| **USDJPY** | London | 12,518 | 1,391 | **11.1%** | 1.71 pts | 1.92 pts |
| **USDJPY** | New York | 13,842 | 1,332 | **9.6%** | 1.75 pts | 1.94 pts |

### Cost Comparison: Conditional on Spread > 0 vs Unconditional:

| Symbol | Cost Model (Primary 2-sp) | Conditional Cost (Spread > 0) *(Biased Upward)* | Unconditional Cost (Time-Average Spread) | Discrepancy / Upward Bias |
| :--- | :---: | :---: | :---: | :--- |
| **EURUSD** | 2 spreads / round trip | **0.0179 EUR** (1.00 pts) | **0.0084 EUR** (0.47 pts) | **+113% upward bias** (due to skipping ~53% zero-spread ticks) |
| **USDJPY** | 2 spreads / round trip | **0.0233 EUR** (2.06 pts) | **0.0213 EUR** (1.89 pts) | **+9.4% upward bias** (due to skipping ~9% zero-spread ticks) |

> [!NOTE]
> **Upward Bias Note:** The conditional cost figure requires `spread > 0` at order entry and is formally labelled as **biased upward** because it intentionally skips zero-spread intervals that exist in the synthetic feed.

---

## 5. Comparison with Backtest Cost Model (Requirement 4 & 6)

### Pre-Registered Primary Cost Model (2 Spreads / Round Trip):
Per `PREREG_SLOW.md`, model cost is $2.0 \times \text{spread\_at\_entry}$. Both conditional and unconditional ratios are reported below:
- **Primary Conditional Ratio (Spread > 0):** Evaluated against entry quotes where spread > 0 *(Biased Upward)*.
- **Primary Unconditional Ratio (Time-Average Spread):** Evaluated against the unconditional synthetic feed spread (including zero-spread intervals).

| Symbol | n | Measured Cost (EUR) | Conditional Model (2-sp) | Conditional Ratio (Med) | Unconditional Model (2-sp) | Unconditional Ratio (Med) | Secondary Model (1-sp) | Pre-Registered Verdict |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :--- |
| **EURUSD** | 0 | - | - | - | - | - | - | **INSUFFICIENT SAMPLE (n=0 < 30)** — Pass/Miss withheld |
| **USDJPY** | **5** | 0.0085 EUR | 0.0113 EUR | **0.75x** | 0.0213 EUR | **0.40x** | 1.52x (post-hoc) | **INSUFFICIENT SAMPLE (n=5 < 30)** — Pass/Miss withheld |

> [!IMPORTANT]
> **Pre-Registered Protocol Verdict:** The demo feed is synthetic, and because $n < 30$ ($n=5$ for USDJPY, $n=0$ for EURUSD), **no PASS or MISS verdict can be claimed**. Formal verdict is strictly withheld until $n \ge 30$ completed round trips per symbol.

---

## 6. EURUSD Skip Rate Telemetry & Underpowered Check (Requirement 3)

Entry filter requires `spread > 0` and `tick_age <= 2.0s`. Filter is strictly fixed and never relaxed.

**Total EURUSD Attempts:** 5 | **Valid Entries Completed:** 0 | **Skips:** 5 | **Overall Skip Rate:** **100.0%** *(1 pre-filter entry excluded)*

| Session | Attempts | Entries Completed | Skips (Spread <= 0 / Stale) | Skip Rate (%) | Session Status |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Asia** | 0 | 0 | 0 | 0.0% | No attempts yet |
| **London** | 0 | 0 | 0 | 0.0% | No attempts yet |
| **New York** | 5 | 0 | 5 | 100.0% | Monitoring (100.0% skip rate) |
| **Off-Peak** | 0 | 0 | 0 | 0.0% | No attempts yet |

> [!NOTE]
> **EURUSD STATUS: MONITORING (Day 1)** — Underpowered evaluation triggers if skip rate remains > 50% after 3 full trading days.
