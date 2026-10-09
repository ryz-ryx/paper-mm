_Dataset: Phase 1a / v1 archive (exploratory only; excluded from Phase 1b statistics by Amendment 3). Primary (trade-through) fills only; window 2026-10-08 06:43 .. 2026-10-08 17:30 UTC (647 min, 127 five-minute blocks). Gross edge is recomputed from raw prices (side-signed far-touch exit vs fill price), not taken from the engine column. CIs: 5-minute block bootstrap, 10,000 resamples, seeded._

**Break-even gross round-trip edge by fee set**

| fee set | break-even gross edge (bps) |
|---|---|
| HL maker+taker (1.5+4.5) | 6.0 |
| HL maker+maker (1.5+1.5) | 3.0 |
| Binance VIP0 (10+10) | 20.0 |
| Binance BNB (7.5+7.5) | 15.0 |
| zero fee | 0.0 |

**Measured gross vs break-even (gap = measured - break-even; negative = shortfall, bps).** Column suffix = round-trip fee in bps (6 = HL maker+taker, 3 = HL maker+maker, 20 = Binance VIP0, 15 = Binance BNB, 0 = zero fee).

| venue | arm | n | blocks | measured gross (bps) [95% CI] | gap vs 6 | gap vs 3 | gap vs 20 | gap vs 15 | gap vs 0 |
|---|---|---|---|---|---|---|---|---|---|
| hyperliquid | A | 3026 | 121 | -4.60 [-4.93, -4.30] | -10.60 | -7.60 | -24.60 | -19.60 | -4.60 |
| hyperliquid | B | 947 | 116 | -4.41 [-5.09, -3.73] | -10.41 | -7.41 | -24.41 | -19.41 | -4.41 |
| hyperliquid | C | 916 | 116 | -4.40 [-5.10, -3.71] | -10.40 | -7.40 | -24.40 | -19.40 | -4.40 |
| binance | A | 866 | 111 | -6.16 [-6.82, -5.52] | -12.16 | -9.16 | -26.16 | -21.16 | -6.16 |
| binance | B | 153 | 78 | -5.82 [-7.28, -4.48] | -11.82 | -8.82 | -25.82 | -20.82 | -5.82 |
| binance | C | 156 | 80 | -6.14 [-7.43, -4.93] | -12.14 | -9.14 | -26.14 | -21.14 | -6.14 |

**Hyperliquid gap with block-bootstrap 95% CI** (fee sets that apply to this venue)

| arm | n | gap vs 6 [95% CI] | gap vs 3 [95% CI] | gap vs 0 [95% CI] |
|---|---|---|---|---|
| A | 3026 | -10.60 [-10.93, -10.30] | -7.60 [-7.93, -7.30] | -4.60 [-4.93, -4.30] |
| B | 947 | -10.41 [-11.09, -9.73] | -7.41 [-8.09, -6.73] | -4.41 [-5.09, -3.73] |
| C | 916 | -10.40 [-11.10, -9.71] | -7.40 [-8.10, -6.71] | -4.40 [-5.10, -3.71] |

**Binance gap with block-bootstrap 95% CI** (fee sets that apply to this venue)

| arm | n | gap vs 20 [95% CI] | gap vs 15 [95% CI] | gap vs 0 [95% CI] |
|---|---|---|---|---|
| A | 866 | -26.16 [-26.82, -25.52] | -21.16 [-21.82, -20.52] | -6.16 [-6.82, -5.52] |
| B | 153 | -25.82 [-27.28, -24.48] | -20.82 [-22.28, -19.48] | -5.82 [-7.28, -4.48] |
| C | 156 | -26.14 [-27.43, -24.93] | -21.14 [-22.43, -19.93] | -6.14 [-7.43, -4.93] |

**Where the gross edge goes (Hyperliquid, bps)**: gross = half-spread earned at placement + mid drift after fill - half-spread paid at the exit. The last two columns are the naive quoted spread that would clear the fee if drift and exit cost stayed at their measured values (optimistic: drift grows with spread).

| arm | n | half-spread earned at placement | mid drift 0..+10s (adverse sel.) | half-spread paid at far-touch exit | gross (= sum) | quoted spread needed for 6 bps (D,E held) | quoted spread needed for 3 bps (D,E held) |
|---|---|---|---|---|---|---|---|
| A | 3026 | 1.87 | -4.85 | 1.62 | -4.60 | 24.95 | 18.95 |
| B | 947 | 1.81 | -4.66 | 1.56 | -4.41 | 24.43 | 18.43 |
| C | 916 | 1.80 | -4.62 | 1.57 | -4.40 | 24.39 | 18.39 |

**Where the gross edge goes (Binance, bps)**: gross = half-spread earned at placement + mid drift after fill - half-spread paid at the exit. The last two columns are the naive quoted spread that would clear the fee if drift and exit cost stayed at their measured values (optimistic: drift grows with spread).

| arm | n | half-spread earned at placement | mid drift 0..+10s (adverse sel.) | half-spread paid at far-touch exit | gross (= sum) | quoted spread needed for 20 bps (D,E held) | quoted spread needed for 15 bps (D,E held) |
|---|---|---|---|---|---|---|---|
| A | 866 | 2.62 | -6.11 | 2.67 | -6.16 | 57.56 | 47.56 |
| B | 153 | 2.53 | -5.87 | 2.48 | -5.82 | 56.69 | 46.69 |
| C | 156 | 2.48 | -6.17 | 2.46 | -6.14 | 57.25 | 47.25 |

**Hyperliquid arm A by instrument (top 15 by fills; descriptive; instruments are not independent of time blocks)**

| instrument | n | spread_bps | gross | mk10 | net_after_6bps |
|---|---|---|---|---|---|
| VVV | 627 | 3.24 | -2.98 | -1.56 | -8.98 |
| kPEPE | 416 | 2.98 | -4.13 | -2.58 | -10.13 |
| CASHCAT | 355 | 6.85 | -7.81 | -4.38 | -13.81 |
| FARTCOIN | 273 | 3.14 | -3.11 | -1.96 | -9.11 |
| CRV | 240 | 2.70 | -4.68 | -3.61 | -10.68 |
| AERO | 162 | 2.66 | -2.51 | -1.61 | -8.51 |
| ZRO | 139 | 3.07 | -2.89 | -1.98 | -8.89 |
| PONS | 132 | 3.61 | -6.02 | -4.78 | -12.02 |
| JUP | 86 | 3.31 | -5.64 | -4.86 | -11.64 |
| CHIP | 78 | 3.15 | -4.52 | -3.32 | -10.52 |
| TAO | 77 | 2.63 | -3.07 | -2.41 | -9.07 |
| GRAM | 65 | 2.59 | -2.63 | -1.73 | -8.63 |
| MON | 63 | 3.05 | -3.93 | -3.15 | -9.93 |
| MINA | 60 | 4.31 | -9.03 | -7.07 | -15.03 |
| SAND | 54 | 3.04 | -4.28 | -3.04 | -10.28 |

**Binance arm A by instrument (top 15 by fills; descriptive; instruments are not independent of time blocks)**

| instrument | n | spread_bps | gross | mk10 | net_after_20bps |
|---|---|---|---|---|---|
| FETUSDT | 125 | 4.31 | -4.69 | -2.53 | -24.69 |
| ENAUSDT | 111 | 4.59 | -5.24 | -2.94 | -25.24 |
| ZROUSDT | 108 | 5.06 | -6.26 | -3.59 | -26.26 |
| RAYUSDT | 97 | 4.05 | -4.90 | -3.10 | -24.90 |
| ADAUSDT | 93 | 4.00 | -5.36 | -3.37 | -25.36 |
| PROMUSDT | 88 | 6.67 | -8.66 | -5.03 | -28.66 |
| ORCAUSDT | 78 | 4.88 | -6.17 | -3.65 | -26.17 |
| TAOUSDT | 70 | 3.55 | -4.15 | -2.38 | -24.15 |
| XLMUSDT | 35 | 5.03 | -5.02 | -2.50 | -25.02 |
| MOVRUSDT | 20 | 7.35 | -11.03 | -7.35 | -31.03 |
| HEMIUSDT | 15 | 16.59 | -13.27 | -4.42 | -33.27 |
| ALGOUSDT | 12 | 8.30 | -13.06 | -8.91 | -33.06 |
| PEPEUSDT | 11 | 24.97 | -13.55 | -0.02 | -33.55 |
| METUSDT | 2 | 4.34 | -14.10 | -11.39 | -34.10 |
| WUSDT | 1 | 6.16 | -55.45 | -52.37 | -75.45 |
