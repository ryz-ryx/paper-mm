# Phase 2 Pre-Registration: validity checks, two edge studies, hard stop

Registered: 2026-10-09, before any recorder data is analysed. Changes after this point = new registration. This document implements the council's blind spots.

## A. Hard stop and budget (quit rule)
- Stop date: 2026-10-23. No extension unless a study PASSES (section D).
- Spend: $0 (no VPS, no live trading). Exception: section C.3.
- Effort cap: 10 hours of the user's own time before the stop date; log hours in `hours.csv`.
- If S1 and S2 both miss: the scalping/HFT objective is closed. Kept: tooling, recorder data, post-mortem. Optional: funding carry as a hobby after the checks in section F.
- Value statement: the best documented return at $100-200 capital is ~$30-48/yr (carry upper bound); a real +2 bps net edge at 20 round trips/day on $200 is ~$0.08/day. Continued work is justified as learning and as a low-probability search, not as income.

## B. Test counter
Phase 1 tests: 12 (alpha 0.0042). Phase 2 adds S1 and S2: counter 14, alpha = 0.05/14 = 0.0036 one-sided for S1 and S2. Parameter selection on dev counts as part of each study (no extra tests) because selection uses dev only.

## C. Measurement validity (run before S1/S2 results are read)
C.1 Clock skew audit (V1): from recorder logs compute local_ts - exchange_ts per venue, hourly. Require median |skew| < 100 ms and p95 < 300 ms on both venues; also record runner NTP offset. If violated: S1 is voided (lead-lag at <1 s depends on it) and the skew is reported.
C.2 Fill-model sensitivity (V2): replay the Phase 1c quoting rules offline on recorded ticks (dev days) under three fill models: (a) trade-through only (primary, pessimistic), (b) trade-at-or-through, (c) queue-depletion. Report gross edge per model, arm A/B/C, by venue.
C.3 Decision from V2: if gross edge is < 0 under ALL three models -> Phase 1 conclusion stands (edge is negative, not a fill-model artifact). If it is >= +1 bps under (b) or (c) but < 0 under (a) -> the question cannot be settled on paper; the only permitted spend is a one-week, $50, maker-only, Hyperliquid live calibration, with the user's explicit approval, isolated margin, 1x leverage.
C.4 Markout definition (V3): report edge using mid, micro-price, and far-touch exits; a conclusion must hold under all.
C.5 Data quality (V4): list stale-book periods (no update > 2 s), gaps > 10 min and days excluded; excluded days are fixed before analysis.

## D. S1: Binance -> Hyperliquid lead-lag
Hypothesis: signed Binance taker flow over a short window predicts the Hyperliquid mid move over the next seconds by more than the HL round-trip cost.
- Universe: coins present on both venues in the recorder (fixed list at registration date).
- Signal: Binance signed taker volume over window W, entry when |flow| exceeds the rolling-1h quantile Q. Grid (selected on dev only, by mean net edge): W in {100, 250, 500} ms, Q in {0.90, 0.95, 0.99}.
- Action: HL taker entry at the far touch at signal_time + 450 ms (sensitivity: +150, +250 ms); exit at far touch at entry + 5 s. Fees: HL taker 4.5 + 4.5 = 9 bps round trip.
- Splits: dev = 2026-10-10..10-13, hold-out = 2026-10-14..10-19 (includes weekend). Hold-out evaluated once with --final.
- Null: circularly shift the Binance series by random offsets >= 60 s (1,000 shifts); the real result must exceed the 99th percentile of the shuffled net edge.
- PASS: >= 500 hold-out signals, mean net >= +0.5 bps, 5-minute block-bootstrap one-sided lower bound > 0 at 0.0036, beats the shuffled null, positive in both halves of the hold-out.
- MISS: otherwise. STOP early (dev) if upper bound < 0 with >= 500 signals.

## E. S2: liquidation-burst reversion (Hyperliquid)
Hypothesis: after a forced-selling burst, price mean-reverts by more than costs.
- Burst: 1-second HL taker volume > 5 sigma over rolling-1h baseline AND mid move >= 20 bps in the same direction within 5 s. Cooldown 60 s per coin.
- Action (primary): taker entry against the move at burst_end + 450 ms; exit at far touch at +30 s. Fees 9 bps round trip. Secondary (reported only): resting maker bid at 10 bps beyond the burst low, pessimistic fills.
- Splits and null: same as S1; shuffle = random burst-time offsets.
- PASS: >= 300 hold-out events, mean net >= +1.0 bps, lower bound > 0 at 0.0036, positive in both hold-out halves, and the mean of the worst 1% of events better than -100 bps. MISS otherwise.

## F. Operational and legal gate (user, not code) before ANY real money
1. Confirm Hyperliquid and Binance access and legality for a Danish resident (MiCA/ESMA status, terms of service). Unverified as of this date.
2. Tax: Danish treatment of crypto gains/losses and reporting; keep trade records.
3. Minimum order sizes at $100-200 (HL ~$10 notional, Binance ~$5-10); confirm the strategy is feasible at that size.
4. API keys: trade-only, no withdrawal permission, IP-restricted. Isolated margin, <= 2x leverage, hard max loss $20 with an automatic kill switch.
5. Keep funds only on the exchange for the test; counterparty risk accepted explicitly.

## G. Logging
Every analysis script writes its parameters, git SHA, data range and excluded days into its report. Reports are committed before the hold-out is run.
