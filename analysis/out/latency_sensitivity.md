_Dataset: Phase 1a / v1 archive (exploratory only; excluded from Phase 1b statistics by Amendment 3)._

### Hyperliquid

_Arm A primary fills, n = 3026; window 2026-10-08 06:43 .. 2026-10-08 17:30 UTC (647 min, 121 five-minute blocks). Exploratory._

**Matching and gate check**

| check | count | of |
|---|---|---|
| fills with a prior PLACE row (same arm/instrument/side) | 3026 | 3026 |
| ...whose price equals the fill's quote price | 3026 | 3026 |
| matched fills with age < 450 ms (latency-gate violation / clock skew) | 0 | 3026 |
| matched fills with age > 1500 ms | 2335 | 3026 |

**Quote age at fill (ms)**

| stat | ms |
|---|---|
| count | 3026 |
| mean | 2858 |
| std | 1448 |
| min | 451 |
| 5% | 638 |
| 25% | 1600 |
| 50% | 2860 |
| 75% | 4075 |
| 95% | 5242 |
| max | 6195 |

**Edge by quote age (exploratory, post-hoc buckets)**

| quote age (ms) | n | blocks | mk +1s | mk +10s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|
| <500 | 46 | 38 | 1.59 | -2.20 | -3.79 | -3.56 [-5.39, -1.78] |
| [500,600) | 78 | 56 | 1.92 | -3.14 | -5.09 | -4.68 [-6.86, -2.82] |
| [600,700) | 67 | 51 | 1.91 | -4.60 | -6.51 | -5.90 [-8.52, -3.61] |
| [700,800) | 54 | 41 | 1.83 | -3.41 | -5.24 | -5.04 [-7.53, -3.05] |
| [800,900) | 73 | 52 | 1.72 | -2.20 | -4.12 | -3.86 [-5.33, -2.41] |
| [900,1000) | 67 | 49 | 1.88 | -4.14 | -6.02 | -5.72 [-9.59, -2.75] |
| [1000,1250) | 154 | 75 | 1.89 | -3.01 | -4.90 | -4.69 [-6.46, -3.26] |
| [1250,1500) | 151 | 72 | 1.83 | -2.51 | -4.35 | -4.13 [-5.27, -3.03] |
| >=1500 | 2336 | 120 | 0.54 | -2.96 | -4.83 | -4.59 [-4.96, -4.25] |

**Longer-latency emulation: keep fills with age >= L** (shorter latencies cannot be evaluated from this data)

| emulated latency L (ms) | fills still live (age >= L) | share of all | gross +10s [95% CI] | mk +10s |
|---|---|---|---|---|
| 450 | 3026 | 1.00 | -4.60 [-4.93, -4.30] | -2.98 |
| 500 | 2980 | 0.98 | -4.62 [-4.95, -4.30] | -2.99 |
| 600 | 2902 | 0.96 | -4.62 [-4.95, -4.31] | -2.99 |
| 700 | 2835 | 0.94 | -4.59 [-4.92, -4.27] | -2.95 |
| 800 | 2781 | 0.92 | -4.58 [-4.92, -4.26] | -2.94 |
| 900 | 2708 | 0.89 | -4.60 [-4.94, -4.28] | -2.96 |
| 1000 | 2641 | 0.87 | -4.57 [-4.92, -4.24] | -2.93 |
| 1250 | 2487 | 0.82 | -4.56 [-4.93, -4.22] | -2.93 |

Spearman correlation, quote age vs gross +10s edge: **-0.075** (permutation p = 0.000, n = 3026; fills within a 5-minute block are autocorrelated so the true p is larger); vs mid markout +10s: -0.074.

**Fill -> measured-exit lag** (exit_time - fill timestamp): min 10000, median 10252, max 59890 ms (the 10 s horizon is polled every 0.5 s, so the exit is read 0-500 ms late). Spearman(exit lag, gross) = +0.016.

### Binance

_Arm A primary fills, n = 866; window 2026-10-08 07:30 .. 2026-10-08 17:30 UTC (600 min, 111 five-minute blocks). Exploratory._

**Matching and gate check**

| check | count | of |
|---|---|---|
| fills with a prior PLACE row (same arm/instrument/side) | 866 | 866 |
| ...whose price equals the fill's quote price | 866 | 866 |
| matched fills with age < 450 ms (latency-gate violation / clock skew) | 0 | 866 |
| matched fills with age > 1500 ms | 85 | 866 |

**Quote age at fill (ms)**

| stat | ms |
|---|---|
| count | 866 |
| mean | 979 |
| std | 698 |
| min | 450 |
| 5% | 484 |
| 25% | 613 |
| 50% | 794 |
| 75% | 1040 |
| 95% | 2231 |
| max | 7756 |

**Edge by quote age (exploratory, post-hoc buckets)**

| quote age (ms) | n | blocks | mk +1s | mk +10s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|
| <500 | 67 | 42 | -5.24 | -4.76 | -7.21 | -7.32 [-9.38, -5.42] |
| [500,600) | 122 | 67 | -3.10 | -2.46 | -4.98 | -5.20 [-6.24, -4.22] |
| [600,700) | 131 | 70 | -3.20 | -3.20 | -5.61 | -5.72 [-7.45, -4.17] |
| [700,800) | 117 | 62 | -3.74 | -2.68 | -5.24 | -5.26 [-6.99, -3.86] |
| [800,900) | 118 | 66 | -2.56 | -2.09 | -4.70 | -4.41 [-5.69, -3.14] |
| [900,1000) | 72 | 51 | -2.72 | -3.96 | -6.80 | -6.82 [-8.47, -5.31] |
| [1000,1250) | 97 | 64 | -4.19 | -4.88 | -7.58 | -7.82 [-9.74, -6.17] |
| [1250,1500) | 57 | 42 | -2.65 | -2.98 | -5.68 | -5.60 [-7.82, -3.49] |
| >=1500 | 85 | 52 | -3.98 | -5.82 | -8.81 | -8.91 [-11.05, -6.80] |

**Longer-latency emulation: keep fills with age >= L** (shorter latencies cannot be evaluated from this data)

| emulated latency L (ms) | fills still live (age >= L) | share of all | gross +10s [95% CI] | mk +10s |
|---|---|---|---|---|
| 450 | 866 | 1.00 | -6.16 [-6.82, -5.52] | -3.49 |
| 500 | 799 | 0.92 | -6.06 [-6.72, -5.41] | -3.38 |
| 600 | 677 | 0.78 | -6.22 [-6.96, -5.50] | -3.55 |
| 700 | 546 | 0.63 | -6.34 [-7.16, -5.55] | -3.63 |
| 800 | 429 | 0.50 | -6.63 [-7.50, -5.81] | -3.89 |
| 900 | 311 | 0.36 | -7.48 [-8.55, -6.47] | -4.58 |
| 1000 | 239 | 0.28 | -7.67 [-9.00, -6.46] | -4.76 |
| 1250 | 142 | 0.16 | -7.58 [-9.31, -5.86] | -4.68 |

Spearman correlation, quote age vs gross +10s edge: **-0.072** (permutation p = 0.037, n = 866; fills within a 5-minute block are autocorrelated so the true p is larger); vs mid markout +10s: -0.056.

**Fill -> measured-exit lag** (exit_time - fill timestamp): min 10000, median 10243, max 60454 ms (the 10 s horizon is polled every 0.5 s, so the exit is read 0-500 ms late). Spearman(exit lag, gross) = -0.018.
