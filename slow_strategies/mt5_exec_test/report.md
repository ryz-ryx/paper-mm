# MT5 Demo Execution Quality Report: 7-Day Benchmark

**Generated:** 2026-10-10 14:26:27 UTC  
**Current Session:** New York  
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

## 2. Execution Quality Metrics by Symbol & Session

**Total Orders Logged:** 13 | **Total Completed Round Trips:** 5 valid (1 pre-filter trip excluded)

### Two Cost Measures per Round Trip:
1. **Fill-to-Fill Cost:** Pure price execution difference $-(P_{\text{sell}} - P_{\text{buy}})$.
2. **Mid-Adjusted Cost:** Signed $(P_{\text{buy}} - M_{\text{entry}}) + (M_{\text{exit}} - P_{\text{sell}})$, minus nothing else.

**Trips with Nonzero Slippage (|entry slip| > 0 or |exit slip| > 0 vs mid_at_fill):** **5 of 5 trips (100.0%)**  
*(Pre-registered protocol: if count is 0 after 30 trips, report 'demo fills at quote; no slippage information')*

| Symbol | n Trips | Spread Med (pts) | Entry Slip (pts) | Exit Slip (pts) | F2F Cost Med (EUR) | Mid-Adj Cost Med (EUR) | Mid-Adj Cost (bps) | Latency Med (ms) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **EURUSD** | 0 | - | - | - | - | - | - | - |
| **USDJPY** | 5 | 1.0 | +0.0 | +0.0 | 0.0113 | 0.0085 | 0.09 | 27.3 |

### Breakdown by Liquidity Session:

| Session | n Orders | Symbols Traded | Median Latency (ms) | Median Mid-Adj Cost (bps) |
| :--- | :---: | :---: | :---: | :---: |
| **New York** | 13 | EURUSD, USDJPY | 27.3 ms | 0.09 bps |

---

## 3. Comparison with Backtest Cost Model (Requirement 6)

Cost model definition: 1 spread per round trip ($1.0 \times \text{spread\_at\_entry}$).
*(Note: `PREREG_SLOW.md` applied a conservative 2-spread allowance due to bid-only bar data; on clean 1-spread execution without slippage, expected ratio against 1-spread model is 1.00x, vs 0.50x against 2-spread allowance).*
Ratio = `mid_adjusted_cost_eur / model_cost_eur`. For zero-spread quotes, ratio is **N/A**.

| Symbol | n | Measured Mid-Adj Cost (EUR) | Model Cost (EUR) | Median Ratio | P90 Ratio | Pre-Registered Verdict |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **EURUSD** | 0 | - | - | - | - | **INSUFFICIENT SAMPLE (n=0 < 30)** — Pass/Miss withheld |
| **USDJPY** | **5** | 0.0085 EUR | 0.0056 EUR | **1.52x** | **1.52x** | **INSUFFICIENT SAMPLE (n=5 < 30)** — Pass/Miss withheld |

> [!IMPORTANT]
> **Pre-registered Gate:** No formal PASS or MISS is declared below $n = 30$ completed round trips per symbol.

---

## 4. EURUSD Skip Rate Telemetry & Underpowered Check (Requirement 3)

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
