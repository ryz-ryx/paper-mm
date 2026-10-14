# Scalper Account Configuration & Environment Specification (ACCOUNT.md)

- **Version**: `1.05`
- **Associated Pre-Registration**: `PREREG.md` (`v1.05`)
- **Status**: TEMPLATE — MUST BE COMPLETED AND COMMITTED PRIOR TO FIRST BURN-IN TRADE

---

## 1. Broker & Account Identification

All fields in this section are mandatory and must be populated with verified demo account credentials prior to initiating the burn-in phase.

- **Broker Name**: `IC Markets (EU) Ltd` *(recorded 2026-10-14)*
- **Server Name**: `ICMarketsEU-Demo` *(recorded 2026-10-14)*
- **Account Number**: `53098320` *(recorded 2026-10-14)*
- **Account Type (Raw Spread / ECN / STP)**: `Raw Spread` *(recorded 2026-10-14)*
- **Account Base Currency**: `USD` *(recorded 2026-10-14)*
- **Account Leverage**: `1:30` *(recorded 2026-10-14)*
- **Starting Demo Balance**: `10000` *(recorded 2026-10-14)*
- **Smoke Run Status on this Specific Account**: `[ REQUIRED: PASSED / NOT RUN ]`
- **Smoke Results File Name**: `[ REQUIRED: ____________________ ]`
- **Smoke Results File Git Blob SHA1**: `[ REQUIRED: ____________________ ]`
- **Smoke Results File SHA256**: `[ REQUIRED: ____________________ ]`
- **ExecTest Harness Commit SHA**: `[ REQUIRED: ____________________ ]`

> [!IMPORTANT]
> ExecTest (blob `e38465857daf5bdd5fcb026a1c128066eaa6f858`, harness commit recorded above) must report PASS for T1, T2, T3A, T4, T5A and T6 and PASS or CONDITIONAL for T5B, on this exact account; T3B is NOT TESTABLE and does not count. If the smoke test requirements are not met on this account, testing cannot start.

---

## 2. Test Execution Timeline

- **Start Date (UTC)**: `[ REQUIRED: ____________________ ]`
- **Hard Stop Date (UTC)**: `[ REQUIRED: ____________________ ]` *(Strictly set to Start Date + 8 weeks)*

If the target evaluation sample ($N = 900$ closed trades) is not achieved on or before the Hard Stop Date, the test terminates as a statistical MISS.

---

## 3. Pre-Start Spread Measurement Results (§3.3)

Prior to the burn-in phase, spread telemetry was collected across 5 full trading days (Monday–Friday) during the session window (`07:00:00` to `16:00:00 UTC`) with zero trades executed. Spread was sampled at every completed M1 bar.

### EURUSD
- **Observed Sample Size (M1 bars)**: `[ REQUIRED: ____________________ ]`
- **60th Percentile Observed Session Spread**: `[ REQUIRED: _______ pips ]`
- **Spread Gate ($\min(0.3\text{ pip}, \text{60th percentile})$)**: `[ REQUIRED: _______ pips ]`
- **$S_{\text{pre-test}}$ (Mean Observed Session Spread)**: `[ REQUIRED: _______ pips ]`

### USDJPY
- **Observed Sample Size (M1 bars)**: `[ REQUIRED: ____________________ ]`
- **60th Percentile Observed Session Spread**: `[ REQUIRED: _______ pips ]`
- **Spread Gate ($\min(0.3\text{ pip}, \text{60th percentile})$)**: `[ REQUIRED: _______ pips ]`
- **$S_{\text{pre-test}}$ (Mean Observed Session Spread)**: `[ REQUIRED: _______ pips ]`

The spread gates and $S_{\text{pre-test}}$ values populated above are frozen upon commitment of this file and govern entry filters and Section 5.1.2 spread fidelity checks.

---

## 4. Economic News Calendar Specification

- **Committed News Calendar File Path**: `[ REQUIRED: ____________________ ]`
- **Committed News Calendar File SHA256**: `[ REQUIRED: ____________________ ]`
- **Degraded Fallback Mode Activated**: `[ REQUIRED: NO / YES (Degraded Mode Disclosed in Final Report) ]`

If a committed calendar file is supplied, its path and cryptographic hash must match the values above. If unavailable, degraded mode (`12:25–12:40` and `13:25–13:40 UTC` fixed windows) must be explicitly affirmed and declared in the final evaluation report.

---

## 5. Pre-Execution Freeze Record

This completed file must be committed to the repository, and its Git commit hash and SHA256 checksum recorded in `PREREG.md` prior to executing the first burn-in trade.

- **File SHA256**: `[ TO BE COMPUTED UPON COMPLETION ]`
- **Commit SHA**: `[ TO BE RECORDED UPON COMMIT ]`
