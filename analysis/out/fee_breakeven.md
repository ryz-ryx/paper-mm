_Primary (trade-through) fills only; window 2026-10-08 06:43 .. 2026-10-08 07:22 UTC (39 min, 9 five-minute blocks). Gross edge is recomputed from raw prices (side-signed far-touch exit vs fill price), not taken from the engine column. CIs: 5-minute block bootstrap, 10,000 resamples, seeded._

**Break-even gross round-trip edge by fee set**

| fee set | break-even gross edge (bps) |
|---|---|
| HL maker+taker (1.5+4.5) | 6.0 |
| HL maker+maker (1.5+1.5) | 3.0 |
| Binance VIP0 (10+10) | 20.0 |
| Binance BNB (7.5+7.5) | 15.0 |
| zero fee | 0.0 |

**Measured gross vs break-even (gap = measured - break-even; negative = shortfall, bps).** Column suffix = round-trip fee in bps (6 = HL maker+taker, 3 = HL maker+maker, 20 = Binance VIP0, 15 = Binance BNB, 0 = zero fee). Binance rows are empty: no Binance fills exist in the clean-epoch data.

| venue | arm | n | blocks | measured gross (bps) [95% CI] | gap vs 6 | gap vs 3 | gap vs 20 | gap vs 15 | gap vs 0 |
|---|---|---|---|---|---|---|---|---|---|
| hyperliquid | A | 161 | 9 | -5.36 [-6.15, -4.58] | -11.36 | -8.36 | -25.36 | -20.36 | -5.36 |
| hyperliquid | B | 41 | 8 | -4.81 [-6.46, -2.96] | -10.81 | -7.81 | -24.81 | -19.81 | -4.81 |
| hyperliquid | C | 39 | 8 | -5.12 [-6.72, -3.28] | -11.12 | -8.12 | -25.12 | -20.12 | -5.12 |
| binance | A | 0 | 0 | n/a |  |  |  |  |  |
| binance | B | 0 | 0 | n/a |  |  |  |  |  |
| binance | C | 0 | 0 | n/a |  |  |  |  |  |

**Hyperliquid gap with block-bootstrap 95% CI**

| arm | n | gap vs 6 [95% CI] | gap vs 3 [95% CI] | gap vs 0 [95% CI] |
|---|---|---|---|---|
| A | 161 | -11.36 [-12.15, -10.58] | -8.36 [-9.15, -7.58] | -5.36 [-6.15, -4.58] |
| B | 41 | -10.81 [-12.46, -8.96] | -7.81 [-9.46, -5.96] | -4.81 [-6.46, -2.96] |
| C | 39 | -11.12 [-12.72, -9.28] | -8.12 [-9.72, -6.28] | -5.12 [-6.72, -3.28] |

**Where the gross edge goes (Hyperliquid, bps)**: gross = half-spread earned at placement + mid drift after fill - half-spread paid at the exit. The last two columns are the naive quoted spread that would clear 6 / 3 bps if the drift and exit cost stayed at their measured values (drift is likely to get worse with wider spreads, so this is optimistic).

| HL arm | n | half-spread earned at placement | mid drift 0..+10s (adverse sel.) | half-spread paid at far-touch exit | gross (= sum) | quoted spread needed for 6 bps (D,E held) | quoted spread needed for 3 bps (D,E held) |
|---|---|---|---|---|---|---|---|
| A | 161 | 2.08 | -5.45 | 2.00 | -5.36 | 26.89 | 20.89 |
| B | 41 | 2.67 | -4.69 | 2.78 | -4.81 | 26.95 | 20.95 |
| C | 39 | 2.67 | -4.91 | 2.88 | -5.12 | 27.57 | 21.57 |

**Hyperliquid arm A by instrument (descriptive; instruments are not independent of time blocks)**

| instrument | n | spread_bps | gross | mk10 | net_6bps |
|---|---|---|---|---|---|
| kPEPE | 32 | 2.56 | -5.57 | -4.10 | -11.57 |
| VVV | 30 | 3.00 | -4.24 | -3.20 | -10.24 |
| CRV | 22 | 3.06 | -7.66 | -6.46 | -13.66 |
| GRIFFAIN | 15 | 11.88 | -3.54 | 3.75 | -9.54 |
| CASHCAT | 13 | 5.23 | -8.30 | -4.81 | -14.30 |
| PENGU | 10 | 2.32 | -4.30 | -3.54 | -10.30 |
| LIT | 9 | 2.66 | -3.44 | -2.49 | -9.44 |
| FARTCOIN | 8 | 2.81 | -4.30 | -3.25 | -10.30 |
| MINA | 8 | 5.86 | -8.74 | -6.19 | -14.74 |
| PONS | 7 | 3.28 | -2.18 | -1.44 | -8.18 |
| AVAX | 6 | 3.69 | -6.60 | -5.53 | -12.60 |
| MET | 1 | 23.28 | 4.74 | 10.31 | -1.26 |
