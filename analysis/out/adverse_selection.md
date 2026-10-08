_Arm A primary fills, Hyperliquid (the only venue with fills); window 2026-10-08 06:43 .. 2026-10-08 07:22 UTC (39 min, 9 five-minute blocks); n = 161 fills. **All cells are exploratory / post-hoc.** Markouts are mid-based, side-signed (+ = good for the maker) in bps; 'gross +10s' is the pre-registered fill -> far-touch-exit edge. 95% CI = 5-minute block bootstrap (10,000 resamples, seeded); with few blocks it is optimistic._

**Overall markout curve by arm** (B and C are nested subsets of A)

| arm | n | half-spread earned | mid markout +1s | +10s | +60s | drift +10s vs half-spread | gross +10s far-touch [95% CI] |
|---|---|---|---|---|---|---|---|
| A | 161 | 2.08 | 0.80 | -3.37 | -4.87 | -5.45 | -5.36 [-6.15, -4.58] |
| B | 41 | 2.67 | 1.32 | -2.02 | -5.67 | -4.69 | -4.81 [-6.46, -2.96] |
| C | 39 | 2.67 | 1.67 | -2.24 | -5.63 | -4.91 | -5.12 [-6.72, -3.28] |

**Filter-value check (exploratory; uses the same fills, descriptive only)**. B removes 74% of fills for a small gain; C is almost identical to B because the flow condition is rarely non-zero.

| filter step | fills | fill drop % | gross delta (bps) | mk +10s delta (bps) | pre-reg requirement (10 s markout delta, drop <= 60%) | share of arm fills with adverse flow_1s > 0 |
|---|---|---|---|---|---|---|
| B vs A | 161 -> 41 | 74.53 | 0.56 | 1.34 | >= +0.5 bps | 4.88 |
| C vs B | 41 -> 39 | 4.88 | -0.31 | -0.21 | >= +0.3 bps | 0.00 |

**Cell table** (30 cells scanned across 7 single-dimension cuts; every row is exploratory). Cells with positive gross edge AND n >= 300: **0**. Cells with n >= 300 at all: 0 (the whole arm has only 161 fills). Cells with positive mean gross at any n: 1 of 30; none can be distinguished from noise: with 30 cells a Bonferroni one-sided level would be 0.0017.

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] | gross>0 | n>=300 & gross>0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| spread at placement (bps) | [2,3) | exploratory (post-hoc) | 99 | 9 | 0.47 | -4.64 | -2.81 | -5.87 | -5.85 [-7.10, -4.77] | no | no |
| spread at placement (bps) | [3,5) | exploratory (post-hoc) | 28 | 8 | 0.05 | -3.46 | -4.87 | -5.25 | -4.86 [-7.00, -2.86] | no | no |
| spread at placement (bps) | [5,10) | exploratory (post-hoc) | 19 | 9 | 0.70 | -1.92 | -13.97 | -5.32 | -5.52 [-10.67, -0.39] | no | no |
| spread at placement (bps) | >=10 | exploratory (post-hoc) | 15 | 6 | 4.51 | 3.40 | -6.97 | -3.17 | -2.87 [-3.83, -0.55] | no | no |
| own-side top-5 imbalance | <0.3 | exploratory (post-hoc) | 27 | 8 | 0.35 | -1.75 | -3.02 | -4.06 | -3.36 [-5.48, -1.09] | no | no |
| own-side top-5 imbalance | [0.3,0.4) | exploratory (post-hoc) | 23 | 8 | 0.65 | -4.26 | -3.04 | -5.89 | -5.82 [-7.63, -4.30] | no | no |
| own-side top-5 imbalance | [0.4,0.5) | exploratory (post-hoc) | 37 | 9 | 1.05 | -3.43 | -3.88 | -5.18 | -5.26 [-6.41, -3.30] | no | no |
| own-side top-5 imbalance | [0.5,0.6) | exploratory (post-hoc) | 33 | 8 | 0.34 | -5.65 | -7.78 | -7.51 | -7.50 [-11.81, -4.92] | no | no |
| own-side top-5 imbalance | >=0.6 | exploratory (post-hoc) | 41 | 8 | 1.32 | -2.02 | -5.67 | -4.69 | -4.81 [-6.46, -2.96] | no | no |
| adverse 1 s taker flow | flow = 0 | exploratory (post-hoc) | 156 | 9 | 0.91 | -3.45 | -4.88 | -5.54 | -5.48 [-6.25, -4.73] | no | no |
| adverse 1 s taker flow | flow > 0 | exploratory (post-hoc) | 5 | 3 | -2.51 | -0.70 | -4.68 | -2.70 | -1.79 [-4.06, +0.97] | no | no |
| realised vol 10 s | vol = 0 | exploratory (post-hoc) | 159 | 9 | 0.79 | -3.27 | -4.78 | -5.36 | -5.27 [-6.04, -4.49] | no | no |
| realised vol 10 s | vol > 0 | exploratory (post-hoc) | 2 | 1 | 2.06 | -10.73 | -12.57 | -12.79 | -13.21 [n/a: 1 block] | no | no |
| queue ahead (x own size) | [1,10)x | exploratory (post-hoc) | 44 | 9 | 1.69 | -2.13 | -3.36 | -4.47 | -4.63 [-7.06, -2.20] | no | no |
| queue ahead (x own size) | [10,100)x | exploratory (post-hoc) | 76 | 9 | 0.48 | -3.85 | -6.96 | -6.18 | -5.94 [-7.31, -4.96] | no | no |
| queue ahead (x own size) | >=100x | exploratory (post-hoc) | 41 | 9 | 0.44 | -3.79 | -2.63 | -5.14 | -5.09 [-6.79, -3.41] | no | no |
| hour of day (UTC) | 06h | exploratory (post-hoc) | 70 | 4 | 1.27 | -3.33 | -6.16 | -5.83 | -5.88 [-7.23, -4.75] | no | no |
| hour of day (UTC) | 07h | exploratory (post-hoc) | 91 | 5 | 0.44 | -3.40 | -3.88 | -5.15 | -4.96 [-5.72, -4.05] | no | no |
| instrument (extra, not requested) | AVAX | exploratory (post-hoc) | 6 | 3 | -0.77 | -5.53 | -10.98 | -7.37 | -6.60 [-9.67, -5.07] | no | no |
| instrument (extra, not requested) | CASHCAT | exploratory (post-hoc) | 13 | 7 | 1.32 | -4.81 | -20.90 | -7.43 | -8.30 [-13.77, -2.80] | no | no |
| instrument (extra, not requested) | CRV | exploratory (post-hoc) | 22 | 6 | 0.07 | -6.46 | -4.95 | -7.99 | -7.66 [-9.24, -6.08] | no | no |
| instrument (extra, not requested) | FARTCOIN | exploratory (post-hoc) | 8 | 4 | -0.23 | -3.25 | -0.40 | -4.65 | -4.30 [-5.79, -1.72] | no | no |
| instrument (extra, not requested) | GRIFFAIN | exploratory (post-hoc) | 15 | 5 | 4.44 | 3.75 | -7.31 | -2.19 | -3.54 [-5.25, -1.19] | no | no |
| instrument (extra, not requested) | LIT | exploratory (post-hoc) | 9 | 7 | 0.25 | -2.49 | -4.89 | -3.82 | -3.44 [-5.07, -1.88] | no | no |
| instrument (extra, not requested) | MET | exploratory (post-hoc) | 1 | 1 | -2.68 | 10.31 | -27.43 | -1.33 | +4.74 [n/a: 1 block] | yes | no |
| instrument (extra, not requested) | MINA | exploratory (post-hoc) | 8 | 5 | 1.09 | -6.19 | -1.03 | -9.12 | -8.74 [-14.59, -4.44] | no | no |
| instrument (extra, not requested) | PENGU | exploratory (post-hoc) | 10 | 6 | 0.58 | -3.54 | -7.90 | -4.70 | -4.30 [-7.75, -2.45] | no | no |
| instrument (extra, not requested) | PONS | exploratory (post-hoc) | 7 | 3 | -2.63 | -1.44 | 11.60 | -3.08 | -2.18 [-2.85, +0.97] | no | no |
| instrument (extra, not requested) | VVV | exploratory (post-hoc) | 30 | 9 | 0.91 | -3.20 | -2.98 | -4.70 | -4.24 [-8.91, -1.75] | no | no |
| instrument (extra, not requested) | kPEPE | exploratory (post-hoc) | 32 | 8 | 0.85 | -4.10 | -1.82 | -5.38 | -5.57 [-6.98, -4.21] | no | no |

**Cells with positive mean gross edge (any n; descriptive leads only, all far below the n threshold)**

| dimension | cell | status | n | blocks | mk +1s | mk +10s | mk +60s | drift +10s | gross +10s [95% CI] | gross>0 | n>=300 & gross>0 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| instrument (extra, not requested) | MET | exploratory (post-hoc) | 1 | 1 | -2.68 | 10.31 | -27.43 | -1.33 | +4.74 [n/a: 1 block] | yes | no |
