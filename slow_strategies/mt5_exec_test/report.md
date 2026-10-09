# MT5 Demo Execution Quality Report: 5-Day Benchmark

**Generated:** 2026-10-09 18:03:29 UTC  
**Current Session:** New York  
**Safety Status:** Active | Demo Account Verified | Equity Drawdown < 50 EUR  

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

**Total Orders Logged:** 6 | **Total Completed Round Trips:** 3

### Two Cost Measures per Round Trip:
1. **Fill-to-Fill Cost:** Pure execution price difference $-(P_{\text{sell}} - P_{\text{buy}})$.
2. **Mid-Adjusted Cost:** Fill-to-fill difference minus market mid price change during 60s hold: $(\Delta M) - (P_{\text{sell}} - P_{\text{buy}})$.

| Symbol | n Trips | Spread Med (pts) | Entry Slip (pts) | Exit Slip (pts) | F2F Cost Med (EUR) | Mid-Adj Cost Med (EUR) | Mid-Adj Cost (bps) | Latency Med (ms) |
| :--- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| **EURUSD** | 1 | 0.0 | +47.0 | +0.0 | 0.0089 | 0.4200 | 4.20 | 42.5 |
| **USDJPY** | 2 | 1.0 | +0.0 | +0.0 | 0.0113 | 0.0085 | 0.09 | 24.6 |

### Breakdown by Liquidity Session:

| Session | n Orders | Symbols Traded | Median Latency (ms) | Median Mid-Adj Cost (bps) |
| :--- | :---: | :---: | :---: | :---: |
| **New York** | 6 | EURUSD, USDJPY | 24.6 ms | 0.09 bps |

---

## 3. Comparison with Backtest Cost Model (Requirement 6)

Backtest model specification (`slow_strategies/backtest.py`): Full cleaned bar spread charged on entry + full spread charged on exit = **2 spreads per round trip**.

| Symbol | n | Measured Mid-Adj Cost (EUR) | Model Cost (EUR) | Median Ratio | P90 Ratio | Pre-Registered Verdict |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **EURUSD** | **1** | 0.4200 EUR | 0.0000 EUR | **1.00x** | **1.00x** | **INSUFFICIENT SAMPLE (n=1 < 30)** — Pass/Miss withheld |
| **USDJPY** | **2** | 0.0085 EUR | 0.0113 EUR | **0.75x** | **0.75x** | **INSUFFICIENT SAMPLE (n=2 < 30)** — Pass/Miss withheld |

> [!IMPORTANT]
> **Statistical Preregistration Gate:** As mandated, no formal PASS or MISS determination is asserted until $n \ge 30$ round trips are recorded per symbol. Preliminary ratios are reported for telemetry tracking only.
