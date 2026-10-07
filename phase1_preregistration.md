# Phase 1 Pre-Registration: filtered passive quoting on wide-spread instruments

Date registered: 2026-10-07 (before any phase-1 data is collected). Parameters below are frozen. Any change = new registration and a new test counter entry.

## Background (measured, phase 0)
- BTC/ETH spot at the touch: gross spread ~0.05 bps/fill, mean markout -0.90 / -1.33 / -1.34 bps (1s/10s/60s), true pre-fee P&L -$82.84 on $695k, n=11,119 markouts. No conditional subset positive (25 cells).
- Universe screen 2026-10-07 (snapshot, median of 6 samples): Binance spot 77 of 125 USDT pairs (>$2M 24h vol) have median spread >= 3 bps; BTC 0.001 bps, ETH 0.04 bps. Hyperliquid perps: 41 coins >$5M vol, median spread 0.89 bps, only 6 coins >= 3 bps (all $7-16M/day).

## Hypothesis
H1: On instruments whose live book spread is >= 3 bps, a post-only quote at the touch placed only when filters allow earns a positive mean net edge per fill after maker fees and a conservative exit cost.

## Definitions (frozen)
- Edge per fill (bps) = side-signed (exit_price - fill_price) / fill_price * 1e4, side-sign +1 for buys, -1 for sells.
- Primary exit price = far touch at fill_time + 10 s (sell at bid for longs, buy at ask for shorts). Secondary (reported only): mid at +1 s, +10 s, +60 s.
- Round-trip net (the decision metric) = edge per fill measured to the far-touch exit - maker_fee_bps (entry is a post-only maker fill) - taker_fee_bps (exit crosses to the far touch). Fee sets reported: Hyperliquid perps (maker 1.5, taker 4.5), Binance spot VIP0 (10 / 10), Binance spot with BNB (7.5 / 7.5), zero-fee reference (0 / 0). Primary decision uses the Hyperliquid set for Hyperliquid coins and the zero-fee reference for Binance alts (to measure gross edge only; Binance alt fees at 7.5-10 bps cannot be cleared by a 3-10 bps spread).

## Arms (6 pre-registered tests; Bonferroni alpha = 0.05 / 6 = 0.0083 one-sided)
Venues: V1 Binance spot alts (>= $5M 24h vol, median spread >= 3 bps, re-screened every 24 h, max 12 pairs, excludes stablecoin and leveraged tokens). V2 Hyperliquid perps with median spread >= 2 bps and >= $5M 24h vol (re-screened daily).
Variants:
- A: quote both sides at the touch when live spread >= 3 bps (>= 2 bps on V2), no other filter.
- B: A plus book-imbalance filter: quote bid only if top-5 bid depth / (top-5 bid + ask depth) >= 0.60; mirror for ask.
- C: B plus cancel-on-flow: pull the bid if taker-sell volume over the last 1 s exceeds the rolling 80th percentile (rolling 1 h); mirror for ask; re-quote after 1 s of calm.
Fixed for all: size = max($10 notional, exchange minimum), requote on >= 1 tick mid move or every 1 s, 60 s pause after > 10 bps / 10 s move, inventory limit +/- 3 quote sizes per instrument, no periodic taker flatten (positions are exited only through the far-touch exit measurement; paper inventory is reset to flat after each 10 s exit).

## Fill model (frozen, deliberately stricter than phase 0)
- Latency: 450 ms on placement and on cancel (observed median 434 ms).
- Primary fill rule (pessimistic): a resting bid fills only when an aggTrade prints strictly below the bid price AFTER the 450 ms latency; mirror for asks. Queue-depletion fills are logged and reported as a secondary variant only.
- Full-size fill; own-order impact ignored.

## Data and splits
- Collect >= 7 consecutive days covering a weekend; hard stop at 14 days. All hours (24 h).
- Dev set = first half of calendar days; hold-out = second half, locked: no parameter changes after viewing hold-out; hold-out evaluated once.
- Statistics: block bootstrap by 5-minute buckets (autocorrelation 0.38 observed), 10,000 resamples.

## Decision rules
- Per arm PASS: >= 2,000 fills on the hold-out, mean round-trip net >= +0.3 bps, bootstrap one-sided CI lower bound > 0 at alpha 0.0083, and positive mean in >= 2 of 3 volatility terciles and in both weekday/weekend.
- Per arm STOP: bootstrap upper bound < 0 at >= 1,000 fills (checked every 24 h on dev data only).
- Filter-value test (B vs A, C vs B): require 10 s markout improvement >= 0.5 bps (B) / >= 0.3 bps (C) with fill count falling by <= 60%.
- Overall: if no arm passes, phase 1 ends with no live deployment; the finding is recorded and phase 3 (slow strategies) continues. A passing arm moves to phase 2 (micro-live calibration), never directly to scale.

## Logging requirements
Per quote and per fill: timestamp, instrument, side, quote price, spread bps at placement, top-5 imbalance, 1 s taker flow, 10 s realised vol, queue ahead (displayed at placement), fill reason, fill price, mid at +1/+10/+60 s, far-touch exit price at +10 s, exit time. Persist append-only with fsync; restore state on restart; record every downtime gap.

## Test counter
Registered tests this phase: 6. Prior programme tests: 10 hypotheses + market-making variants (0 passes).
