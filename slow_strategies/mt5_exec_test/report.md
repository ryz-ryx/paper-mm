# MT5 Demo Execution Quality Report: 7-Day Benchmark

**Generated:** 2026-10-09 18:59:11 UTC  
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

**Total Orders Logged:** 12 | **Total Completed Round Trips:** 6

### Two Cost Measures per Round Trip:
1. **Fill-to-Fill Cost:** Pure price execution difference $-(P_{\text{sell}} - P_{\text{buy}})$.
2. **Mid-Adjusted Cost:** Signed $(P_{\text{buy}} - M_{\text{entry}}) + (M_{\text{exit}} - P_{\text{sell}})$, minus nothing else.

| Symbol | n Trips | Spread Med (pts) | Entry Slip (pts) | Exit Slip (pts) | F2F Cost Med (EUR) | Mid-Adj Cost Med (EUR) | Mid-Adj Cost (bps) | Latency Med (ms) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **EURUSD** | 1 | 0.0 | +47.0 | +0.0 | 0.0089 | 0.4198 | 4.20 | 42.5 |
| **USDJPY** | 5 | 1.0 | +0.0 | +0.0 | 0.0113 | 0.0085 | 0.09 | 26.9 |

### Breakdown by Liquidity Session:

| Session | n Orders | Symbols Traded | Median Latency (ms) | Median Mid-Adj Cost (bps) |
| :--- | :---: | :---: | :---: | :---: |
| **New York** | 12 | EURUSD, USDJPY | 26.9 ms | 0.09 bps |

---

## 3. Comparison with Backtest Cost Model (Requirement 6)

Backtest model assumption (`slow_strategies/backtest.py`): 2 spreads per round trip.
Ratio = `mid_adjusted_cost_eur / model_cost_eur`. For zero-spread quotes, ratio is **N/A**.

| Symbol | n | Measured Mid-Adj Cost (EUR) | Model Cost (EUR) | Median Ratio | P90 Ratio | Pre-Registered Verdict |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **EURUSD** | **1** | 0.4198 EUR | 0.0000 EUR | **N/A** | **N/A** | **INSUFFICIENT SAMPLE (n=1 < 30)** — Pass/Miss withheld |
| **USDJPY** | **5** | 0.0085 EUR | 0.0113 EUR | **0.75x** | **0.75x** | **INSUFFICIENT SAMPLE (n=5 < 30)** — Pass/Miss withheld |

> [!IMPORTANT]
> **Pre-registered Gate:** No formal PASS or MISS is declared below $n = 30$ completed round trips per symbol.

---

## 4. EURUSD Skip Rate Telemetry & Underpowered Check (Requirement 3)

Entry filter requires `spread > 0` and `tick_age <= 2.0s`. Filter is strictly fixed and never relaxed.

**Total EURUSD Attempts:** 4 | **Completed Entries:** 1 | **Skips:** 3 | **Overall Skip Rate:** **75.0%**

| Session | Attempts | Entries Completed | Skips (Spread <= 0 / Stale) | Skip Rate (%) | Session Status |
| :--- | :---: | :---: | :---: | :---: | :--- |
| **Asia** | 0 | 0 | 0 | 0.0% | No attempts yet |
| **London** | 0 | 0 | 0 | 0.0% | No attempts yet |
| **New York** | 4 | 1 | 3 | 75.0% | Monitoring (75.0% skip rate) |
| **Off-Peak** | 0 | 0 | 0 | 0.0% | No attempts yet |

> [!NOTE]
> **EURUSD STATUS: MONITORING (Day 1)** — Underpowered evaluation triggers if skip rate remains > 50% after 3 full trading days.
