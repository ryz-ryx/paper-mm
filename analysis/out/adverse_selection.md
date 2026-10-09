_Dataset: Phase 1a / v1 archive (exploratory only; excluded from Phase 1b statistics by Amendment 3)._

### Hyperliquid

_Arm A primary fills, n = 3026; window 2026-10-08 06:43 .. 2026-10-08 17:30 UTC (647 min, 121 five-minute blocks); 24 instruments. **All cells are exploratory / post-hoc.** Markouts are mid-based, side-signed (+ = good for the maker) in bps; 'gross +10s' is the pre-registered fill -> far-touch-exit edge. CI = 5-minute block bootstrap (10,000 resamples, seeded)._

**Markout curve by arm** (B and C are nested subsets of A)

| arm | n | half-spread earned | mid markout +1s | +10s | +60s | drift +10s vs half-spread | gross +10s far-touch [95% CI] |
|---|---|---|---|---|---|---|---|
| A | 3026 | 1.87 | 0.84 | -2.98 | -3.20 | -4.85 | -4.60 [-4.93, -4.30] |
| B | 947 | 1.81 | 0.72 | -2.85 | -3.80 | -4.66 | -4.41 [-5.09, -3.73] |
| C | 916 | 1.80 | 0.77 | -2.82 | -3.65 | -4.62 | -4.40 [-5.10, -3.71] |

**Filter-value check (descriptive, same fills)**

| filter step | fills | fill drop % | gross delta (bps) | mk +10s delta (bps) | pre-reg requirement (10 s markout delta, drop <= 60%) | share of arm fills with adverse flow_1s > 0 |
|---|---|---|---|---|---|---|
| B vs A | 3026 -> 947 | 68.70 | 0.20 | 0.13 | >= +0.5 bps | 7.81 |
| C vs B | 947 -> 916 | 3.27 | 0.01 | 0.03 | >= +0.3 bps | 4.48 |

**Cell table: 53 cells over 7 single-dimension cuts** (every row exploratory). Cells with n >= 300: 22. Cells with positive mean gross edge: 0. **Cells with positive gross edge AND n >= 300: 0.** One-sided Bonferroni level over this venue's 53 cells: 0.0009.

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|---|---|---|
| spread at placement (bps) | <3 | exploratory (post-hoc) | 1617 | 116 | 0.48 | -2.60 | -2.31 | -3.83 | -3.79 [-4.12, -3.47] |
| spread at placement (bps) | [3,5) | exploratory (post-hoc) | 921 | 115 | 0.84 | -2.68 | -3.34 | -4.56 | -4.10 [-4.63, -3.60] |
| spread at placement (bps) | [5,10) | exploratory (post-hoc) | 399 | 108 | 1.76 | -4.90 | -6.91 | -8.33 | -7.94 [-9.27, -6.72] |
| spread at placement (bps) | >=10 | exploratory (post-hoc) | 89 | 49 | 3.13 | -4.42 | -1.38 | -10.95 | -9.69 [-12.08, -7.59] |
| own-side top-5 imbalance | <0.3 | exploratory (post-hoc) | 729 | 108 | 1.10 | -2.79 | -2.93 | -4.67 | -4.29 [-4.90, -3.75] |
| own-side top-5 imbalance | [0.3,0.4) | exploratory (post-hoc) | 368 | 103 | 0.88 | -3.36 | -1.36 | -5.32 | -5.08 [-5.99, -4.22] |
| own-side top-5 imbalance | [0.4,0.5) | exploratory (post-hoc) | 545 | 107 | 0.87 | -3.17 | -3.15 | -4.98 | -4.85 [-5.62, -4.16] |
| own-side top-5 imbalance | [0.5,0.6) | exploratory (post-hoc) | 473 | 109 | 0.53 | -3.21 | -3.25 | -5.18 | -4.99 [-5.74, -4.27] |
| own-side top-5 imbalance | >=0.6 | exploratory (post-hoc) | 911 | 115 | 0.76 | -2.76 | -4.17 | -4.57 | -4.31 [-5.02, -3.64] |
| adverse 1 s taker flow | flow = 0 | exploratory (post-hoc) | 2825 | 121 | 0.83 | -2.99 | -3.10 | -4.84 | -4.62 [-4.96, -4.30] |
| adverse 1 s taker flow | flow > 0 | exploratory (post-hoc) | 201 | 84 | 1.00 | -2.92 | -4.70 | -5.05 | -4.33 [-5.35, -3.38] |
| realised vol 10 s | vol = 0 | exploratory (post-hoc) | 3013 | 121 | 0.84 | -2.98 | -3.23 | -4.85 | -4.60 [-4.93, -4.29] |
| realised vol 10 s | vol > 0 | exploratory (post-hoc) | 13 | 6 | 0.31 | -3.96 | 3.19 | -6.68 | -5.86 [-10.16, -1.30] |
| queue ahead (x own size) | <1x | exploratory (post-hoc) | 8 | 8 | 0.71 | -1.49 | -3.67 | -3.83 | -4.12 [-8.26, -0.08] |
| queue ahead (x own size) | [1,10)x | exploratory (post-hoc) | 1028 | 105 | 1.08 | -2.64 | -3.08 | -4.55 | -4.33 [-4.89, -3.85] |
| queue ahead (x own size) | [10,100)x | exploratory (post-hoc) | 1408 | 120 | 0.71 | -3.21 | -3.54 | -5.12 | -4.81 [-5.32, -4.35] |
| queue ahead (x own size) | >=100x | exploratory (post-hoc) | 582 | 113 | 0.73 | -3.05 | -2.60 | -4.76 | -4.60 [-5.45, -3.77] |
| hour of day (UTC) | 06h | exploratory (post-hoc) | 70 | 4 | 1.27 | -3.33 | -6.16 | -5.83 | -5.88 [-7.23, -4.75] |
| hour of day (UTC) | 07h | exploratory (post-hoc) | 319 | 11 | 0.59 | -2.79 | -2.33 | -4.51 | -4.28 [-5.27, -3.35] |
| hour of day (UTC) | 08h | exploratory (post-hoc) | 382 | 12 | 0.86 | -2.53 | -2.67 | -4.30 | -3.99 [-4.62, -3.32] |
| hour of day (UTC) | 09h | exploratory (post-hoc) | 448 | 12 | 0.81 | -2.76 | -2.98 | -4.49 | -4.18 [-5.20, -3.29] |
| hour of day (UTC) | 10h | exploratory (post-hoc) | 395 | 12 | 0.92 | -2.81 | -2.70 | -4.57 | -4.39 [-5.16, -3.78] |
| hour of day (UTC) | 11h | exploratory (post-hoc) | 407 | 12 | 0.99 | -2.84 | -2.32 | -4.82 | -4.64 [-5.48, -3.96] |
| hour of day (UTC) | 12h | exploratory (post-hoc) | 330 | 12 | 0.89 | -4.09 | -4.63 | -6.23 | -5.97 [-7.05, -4.99] |
| hour of day (UTC) | 13h | exploratory (post-hoc) | 233 | 12 | 0.33 | -2.83 | -4.34 | -4.66 | -4.31 [-5.54, -3.22] |
| hour of day (UTC) | 14h | exploratory (post-hoc) | 285 | 12 | 1.03 | -3.21 | -3.89 | -5.06 | -4.77 [-5.53, -4.10] |
| hour of day (UTC) | 15h | exploratory (post-hoc) | 81 | 8 | 1.61 | -2.58 | -5.03 | -4.68 | -4.62 [-7.19, -3.08] |
| hour of day (UTC) | 16h | exploratory (post-hoc) | 55 | 10 | 0.17 | -4.89 | -2.44 | -6.98 | -6.71 [-9.62, -4.60] |
| hour of day (UTC) | 17h | exploratory (post-hoc) | 21 | 4 | -0.11 | -1.56 | 2.37 | -3.35 | -2.85 [-4.35, -0.36] |
| instrument (extra, not requested) | ADA | exploratory (post-hoc) | 41 | 20 | 0.13 | -2.72 | -6.40 | -4.06 | -3.62 [-5.52, -2.12] |
| instrument (extra, not requested) | AERO | exploratory (post-hoc) | 162 | 54 | 0.59 | -1.61 | -1.28 | -2.94 | -2.51 [-3.30, -1.80] |
| instrument (extra, not requested) | ALGO | exploratory (post-hoc) | 23 | 15 | 0.64 | -8.18 | -17.15 | -9.98 | -9.97 [-15.75, -4.76] |
| instrument (extra, not requested) | AVAX | exploratory (post-hoc) | 6 | 3 | -0.77 | -5.53 | -10.98 | -7.37 | -6.60 [-9.67, -5.07] |
| instrument (extra, not requested) | CASHCAT | exploratory (post-hoc) | 355 | 97 | 1.92 | -4.38 | -6.43 | -7.80 | -7.81 [-8.85, -6.88] |
| instrument (extra, not requested) | CHIP | exploratory (post-hoc) | 78 | 49 | 0.04 | -3.32 | -5.82 | -4.90 | -4.52 [-7.33, -2.22] |
| instrument (extra, not requested) | CRV | exploratory (post-hoc) | 240 | 65 | 0.38 | -3.61 | -3.36 | -4.96 | -4.68 [-5.44, -3.97] |
| instrument (extra, not requested) | FARTCOIN | exploratory (post-hoc) | 273 | 87 | 0.39 | -1.96 | -0.91 | -3.53 | -3.11 [-3.89, -2.40] |
| instrument (extra, not requested) | GRAM | exploratory (post-hoc) | 65 | 38 | 0.48 | -1.73 | -1.26 | -3.02 | -2.63 [-3.64, -1.64] |
| instrument (extra, not requested) | GRIFFAIN | exploratory (post-hoc) | 43 | 23 | 5.02 | -4.11 | -4.89 | -10.89 | -11.78 [-17.16, -8.04] |
| instrument (extra, not requested) | JUP | exploratory (post-hoc) | 86 | 47 | 0.88 | -4.86 | -4.59 | -6.51 | -5.64 [-6.99, -4.29] |
| instrument (extra, not requested) | LIT | exploratory (post-hoc) | 9 | 7 | 0.25 | -2.49 | -4.89 | -3.82 | -3.44 [-5.07, -1.88] |
| instrument (extra, not requested) | MET | exploratory (post-hoc) | 13 | 9 | -1.19 | -7.88 | -12.03 | -11.55 | -10.90 [-18.58, -3.92] |
| instrument (extra, not requested) | MINA | exploratory (post-hoc) | 60 | 38 | -0.68 | -7.07 | -5.24 | -9.23 | -9.03 [-13.74, -5.33] |
| instrument (extra, not requested) | MON | exploratory (post-hoc) | 63 | 39 | 0.53 | -3.15 | -3.93 | -4.68 | -3.93 [-5.47, -2.43] |
| instrument (extra, not requested) | NEAR | exploratory (post-hoc) | 21 | 14 | 0.98 | -3.15 | -3.18 | -4.56 | -3.43 [-6.82, -0.69] |
| instrument (extra, not requested) | PENGU | exploratory (post-hoc) | 11 | 7 | 0.06 | -4.68 | -7.90 | -5.84 | -5.47 [-10.38, -2.91] |
| instrument (extra, not requested) | PONS | exploratory (post-hoc) | 132 | 55 | 0.39 | -4.78 | -4.05 | -6.59 | -6.02 [-7.72, -4.62] |
| instrument (extra, not requested) | SAND | exploratory (post-hoc) | 54 | 24 | -0.21 | -3.04 | -2.05 | -4.56 | -4.28 [-5.85, -2.85] |
| instrument (extra, not requested) | TAO | exploratory (post-hoc) | 77 | 26 | 0.65 | -2.41 | -2.39 | -3.73 | -3.07 [-4.17, -2.14] |
| instrument (extra, not requested) | VVV | exploratory (post-hoc) | 627 | 81 | 1.13 | -1.56 | -2.08 | -3.18 | -2.98 [-3.50, -2.53] |
| instrument (extra, not requested) | W | exploratory (post-hoc) | 32 | 25 | 0.01 | -10.58 | -2.58 | -14.74 | -15.91 [-21.63, -10.44] |
| instrument (extra, not requested) | ZRO | exploratory (post-hoc) | 139 | 50 | 0.83 | -1.98 | -4.16 | -3.51 | -2.89 [-3.92, -1.96] |
| instrument (extra, not requested) | kPEPE | exploratory (post-hoc) | 416 | 101 | 0.74 | -2.58 | -1.37 | -4.07 | -4.13 [-4.68, -3.62] |

**No cell qualifies (n >= 300 with positive mean gross edge).**

**Five highest-gross cells (any n; descriptive leads, not findings)**

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|---|---|---|
| instrument (extra, not requested) | AERO | exploratory (post-hoc) | 162 | 54 | 0.59 | -1.61 | -1.28 | -2.94 | -2.51 [-3.30, -1.80] |
| instrument (extra, not requested) | GRAM | exploratory (post-hoc) | 65 | 38 | 0.48 | -1.73 | -1.26 | -3.02 | -2.63 [-3.64, -1.64] |
| hour of day (UTC) | 17h | exploratory (post-hoc) | 21 | 4 | -0.11 | -1.56 | 2.37 | -3.35 | -2.85 [-4.35, -0.36] |
| instrument (extra, not requested) | ZRO | exploratory (post-hoc) | 139 | 50 | 0.83 | -1.98 | -4.16 | -3.51 | -2.89 [-3.92, -1.96] |
| instrument (extra, not requested) | VVV | exploratory (post-hoc) | 627 | 81 | 1.13 | -1.56 | -2.08 | -3.18 | -2.98 [-3.50, -2.53] |

### Binance

_Arm A primary fills, n = 866; window 2026-10-08 07:30 .. 2026-10-08 17:30 UTC (600 min, 111 five-minute blocks); 15 instruments. **All cells are exploratory / post-hoc.** Markouts are mid-based, side-signed (+ = good for the maker) in bps; 'gross +10s' is the pre-registered fill -> far-touch-exit edge. CI = 5-minute block bootstrap (10,000 resamples, seeded)._

**Markout curve by arm** (B and C are nested subsets of A)

| arm | n | half-spread earned | mid markout +1s | +10s | +60s | drift +10s vs half-spread | gross +10s far-touch [95% CI] |
|---|---|---|---|---|---|---|---|
| A | 866 | 2.62 | -3.44 | -3.49 | -3.12 | -6.11 | -6.16 [-6.82, -5.52] |
| B | 153 | 2.53 | -3.06 | -3.34 | -3.59 | -5.87 | -5.82 [-7.28, -4.48] |
| C | 156 | 2.48 | -3.37 | -3.68 | -3.45 | -6.17 | -6.14 [-7.43, -4.93] |

**Filter-value check (descriptive, same fills)**

| filter step | fills | fill drop % | gross delta (bps) | mk +10s delta (bps) | pre-reg requirement (10 s markout delta, drop <= 60%) | share of arm fills with adverse flow_1s > 0 |
|---|---|---|---|---|---|---|
| B vs A | 866 -> 153 | 82.33 | 0.35 | 0.15 | >= +0.5 bps | 17.65 |
| C vs B | 153 -> 156 | -1.96 | -0.33 | -0.35 | >= +0.3 bps | 9.62 |

**Cell table: 42 cells over 7 single-dimension cuts** (every row exploratory). Cells with n >= 300: 4. Cells with positive mean gross edge: 0. **Cells with positive gross edge AND n >= 300: 0.** One-sided Bonferroni level over this venue's 42 cells: 0.0012.

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|---|---|---|
| spread at placement (bps) | [3,5) | exploratory (post-hoc) | 673 | 97 | -3.11 | -3.10 | -2.61 | -5.21 | -5.31 [-5.97, -4.69] |
| spread at placement (bps) | [5,10) | exploratory (post-hoc) | 157 | 76 | -4.10 | -5.18 | -5.48 | -8.57 | -8.41 [-10.09, -6.82] |
| spread at placement (bps) | >=10 | exploratory (post-hoc) | 36 | 25 | -6.82 | -3.39 | -2.30 | -12.16 | -12.32 [-17.94, -7.71] |
| own-side top-5 imbalance | <0.3 | exploratory (post-hoc) | 95 | 59 | -3.38 | -4.85 | -3.33 | -7.13 | -7.32 [-9.47, -5.37] |
| own-side top-5 imbalance | [0.3,0.4) | exploratory (post-hoc) | 128 | 63 | -3.98 | -3.89 | -4.37 | -6.58 | -6.50 [-7.86, -5.23] |
| own-side top-5 imbalance | [0.4,0.5) | exploratory (post-hoc) | 273 | 87 | -3.12 | -3.10 | -2.46 | -5.74 | -5.65 [-6.72, -4.65] |
| own-side top-5 imbalance | [0.5,0.6) | exploratory (post-hoc) | 233 | 90 | -3.71 | -3.20 | -2.37 | -5.96 | -6.23 [-7.44, -5.09] |
| own-side top-5 imbalance | >=0.6 | exploratory (post-hoc) | 137 | 74 | -3.17 | -3.43 | -4.37 | -5.96 | -5.94 [-7.43, -4.48] |
| adverse 1 s taker flow | flow = 0 | exploratory (post-hoc) | 730 | 109 | -3.46 | -3.58 | -3.40 | -6.19 | -6.24 [-6.92, -5.59] |
| adverse 1 s taker flow | flow > 0 | exploratory (post-hoc) | 136 | 69 | -3.32 | -2.99 | -1.56 | -5.66 | -5.76 [-7.45, -4.12] |
| realised vol 10 s | vol = 0 | exploratory (post-hoc) | 192 | 77 | -4.22 | -3.69 | -4.74 | -7.06 | -7.25 [-8.60, -6.01] |
| realised vol 10 s | vol > 0 | exploratory (post-hoc) | 674 | 109 | -3.22 | -3.43 | -2.65 | -5.84 | -5.85 [-6.57, -5.15] |
| queue ahead (x own size) | <1x | exploratory (post-hoc) | 88 | 62 | -3.04 | -3.98 | -5.58 | -6.35 | -6.50 [-8.50, -4.69] |
| queue ahead (x own size) | [1,10)x | exploratory (post-hoc) | 115 | 67 | -2.20 | -2.70 | 0.19 | -5.28 | -5.30 [-6.60, -4.08] |
| queue ahead (x own size) | [10,100)x | exploratory (post-hoc) | 297 | 95 | -3.56 | -3.83 | -3.58 | -6.48 | -6.56 [-7.79, -5.44] |
| queue ahead (x own size) | >=100x | exploratory (post-hoc) | 366 | 92 | -3.83 | -3.34 | -3.19 | -6.01 | -6.02 [-7.03, -5.10] |
| hour of day (UTC) | 07h | exploratory (post-hoc) | 57 | 6 | -2.15 | -2.98 | -2.23 | -5.42 | -5.51 [-6.73, -4.46] |
| hour of day (UTC) | 08h | exploratory (post-hoc) | 114 | 12 | -2.97 | -0.98 | 1.48 | -3.37 | -3.50 [-4.88, -2.10] |
| hour of day (UTC) | 09h | exploratory (post-hoc) | 140 | 12 | -3.80 | -3.64 | -1.97 | -6.11 | -6.02 [-7.36, -4.90] |
| hour of day (UTC) | 10h | exploratory (post-hoc) | 110 | 12 | -3.67 | -3.97 | -3.99 | -6.30 | -6.43 [-7.87, -5.05] |
| hour of day (UTC) | 11h | exploratory (post-hoc) | 100 | 12 | -3.29 | -2.85 | -5.89 | -5.37 | -5.19 [-6.97, -3.92] |
| hour of day (UTC) | 12h | exploratory (post-hoc) | 99 | 12 | -4.52 | -5.05 | -4.76 | -7.99 | -8.02 [-10.37, -5.54] |
| hour of day (UTC) | 13h | exploratory (post-hoc) | 93 | 10 | -3.44 | -3.90 | -4.64 | -6.56 | -6.92 [-8.45, -5.21] |
| hour of day (UTC) | 14h | exploratory (post-hoc) | 76 | 12 | -2.94 | -2.56 | -2.66 | -5.16 | -5.47 [-7.81, -3.67] |
| hour of day (UTC) | 15h | exploratory (post-hoc) | 33 | 8 | -2.79 | -6.91 | -5.14 | -10.71 | -9.99 [-12.97, -6.38] |
| hour of day (UTC) | 16h | exploratory (post-hoc) | 31 | 9 | -3.50 | -4.05 | -4.05 | -7.26 | -7.36 [-9.86, -3.93] |
| hour of day (UTC) | 17h | exploratory (post-hoc) | 13 | 6 | -4.89 | -7.62 | -3.06 | -10.74 | -10.97 [-24.51, -4.80] |
| instrument (extra, not requested) | ADAUSDT | exploratory (post-hoc) | 93 | 59 | -3.15 | -3.37 | -3.35 | -5.36 | -5.36 [-6.64, -4.22] |
| instrument (extra, not requested) | ALGOUSDT | exploratory (post-hoc) | 12 | 8 | -8.22 | -8.91 | -13.13 | -13.06 | -13.06 [-29.78, -5.19] |
| instrument (extra, not requested) | ENAUSDT | exploratory (post-hoc) | 111 | 56 | -3.13 | -2.94 | -4.32 | -5.24 | -5.24 [-7.01, -3.72] |
| instrument (extra, not requested) | FETUSDT | exploratory (post-hoc) | 125 | 49 | -3.26 | -2.53 | 0.04 | -4.69 | -4.69 [-5.97, -3.54] |
| instrument (extra, not requested) | HEMIUSDT | exploratory (post-hoc) | 15 | 10 | -4.91 | -4.42 | -10.42 | -12.72 | -13.27 [-24.99, -6.13] |
| instrument (extra, not requested) | METUSDT | exploratory (post-hoc) | 2 | 1 | -5.97 | -11.39 | -61.29 | -13.56 | -14.10 [n/a: 1 block] |
| instrument (extra, not requested) | MOVRUSDT | exploratory (post-hoc) | 20 | 18 | -9.70 | -7.35 | -6.36 | -11.03 | -11.03 [-15.98, -6.82] |
| instrument (extra, not requested) | ORCAUSDT | exploratory (post-hoc) | 78 | 45 | -4.20 | -3.65 | -5.84 | -6.09 | -6.17 [-8.48, -3.99] |
| instrument (extra, not requested) | PEPEUSDT | exploratory (post-hoc) | 11 | 10 | -9.04 | -0.02 | 9.01 | -12.50 | -13.55 [-20.24, -6.78] |
| instrument (extra, not requested) | PROMUSDT | exploratory (post-hoc) | 88 | 40 | -3.01 | -5.03 | -2.52 | -8.36 | -8.66 [-11.03, -6.54] |
| instrument (extra, not requested) | RAYUSDT | exploratory (post-hoc) | 97 | 42 | -2.18 | -3.10 | -0.45 | -5.13 | -4.90 [-6.95, -3.12] |
| instrument (extra, not requested) | TAOUSDT | exploratory (post-hoc) | 70 | 40 | -2.18 | -2.38 | -1.43 | -4.15 | -4.15 [-5.26, -3.14] |
| instrument (extra, not requested) | WUSDT | exploratory (post-hoc) | 1 | 1 | -21.57 | -52.37 | -101.66 | -55.45 | -55.45 [n/a: 1 block] |
| instrument (extra, not requested) | XLMUSDT | exploratory (post-hoc) | 35 | 30 | -2.51 | -2.50 | -3.09 | -5.02 | -5.02 [-6.87, -2.97] |
| instrument (extra, not requested) | ZROUSDT | exploratory (post-hoc) | 108 | 53 | -3.59 | -3.59 | -3.90 | -6.12 | -6.26 [-7.68, -4.93] |

**No cell qualifies (n >= 300 with positive mean gross edge).**

**Five highest-gross cells (any n; descriptive leads, not findings)**

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|---|---|---|
| hour of day (UTC) | 08h | exploratory (post-hoc) | 114 | 12 | -2.97 | -0.98 | 1.48 | -3.37 | -3.50 [-4.88, -2.10] |
| instrument (extra, not requested) | TAOUSDT | exploratory (post-hoc) | 70 | 40 | -2.18 | -2.38 | -1.43 | -4.15 | -4.15 [-5.26, -3.14] |
| instrument (extra, not requested) | FETUSDT | exploratory (post-hoc) | 125 | 49 | -3.26 | -2.53 | 0.04 | -4.69 | -4.69 [-5.97, -3.54] |
| instrument (extra, not requested) | RAYUSDT | exploratory (post-hoc) | 97 | 42 | -2.18 | -3.10 | -0.45 | -5.13 | -4.90 [-6.95, -3.12] |
| instrument (extra, not requested) | XLMUSDT | exploratory (post-hoc) | 35 | 30 | -2.51 | -2.50 | -3.09 | -5.02 | -5.02 [-6.87, -2.97] |
