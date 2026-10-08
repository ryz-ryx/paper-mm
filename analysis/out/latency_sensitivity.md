_Arm A primary fills, Hyperliquid, n = 161; window 2026-10-08 06:43 .. 2026-10-08 07:22 UTC (39 min, 9 five-minute blocks). Exploratory._

**Matching and gate check**

| check | count | of |
|---|---|---|
| fills with a prior PLACE row (same arm/instrument/side) | 161 | 161 |
| ...whose price equals the fill's quote price | 161 | 161 |
| matched fills with age < 450 ms (latency-gate violation / clock skew) | 0 | 161 |
| matched fills with age > 1500 ms (quote older than the 1 s requote rule) | 133 | 161 |

**Quote age at fill (ms)**

| stat | ms |
|---|---|
| count | 161 |
| mean | 2937 |
| std | 1389 |
| min | 451 |
| 5% | 795 |
| 25% | 1715 |
| 50% | 2935 |
| 75% | 4024 |
| 95% | 5165 |
| max | 5787 |

**Edge by quote age (exploratory, post-hoc buckets)**

| quote age (ms) | n | blocks | mk +1s | mk +10s | drift +10s | gross +10s [95% CI] |
|---|---|---|---|---|---|---|
| <500 | 1 | 1 | 1.24 | -6.19 | -7.43 | -7.43 [n/a: 1 block] |
| [500,600) | 5 | 3 | 1.76 | -1.38 | -3.60 | -3.06 [-9.84, +1.99] |
| [600,700) | 1 | 1 | 1.25 | -4.98 | -6.23 | -7.47 [n/a: 1 block] |
| [700,800) | 2 | 2 | 2.06 | -10.10 | -12.16 | -11.95 [-18.95, -4.96] |
| [800,900) | 4 | 3 | 1.78 | 0.30 | -5.05 | -3.67 [-7.64, +4.74] |
| [900,1000) | 2 | 2 | 1.28 | -2.70 | -3.98 | -3.33 [-6.41, -0.26] |
| >=1000 | 146 | 9 | 0.71 | -3.42 | -5.43 | -5.40 [-6.43, -4.40] |

**Longer-latency emulation: keep fills with age >= L** (shorter latencies cannot be evaluated from this data)

| emulated latency L (ms) | fills still live (age >= L) | share of all | gross +10s [95% CI] | mk +10s |
|---|---|---|---|---|
| 450 | 161 | 1.00 | -5.36 [-6.15, -4.58] | -3.37 |
| 500 | 160 | 0.99 | -5.35 [-6.15, -4.55] | -3.35 |
| 600 | 155 | 0.96 | -5.42 [-6.37, -4.47] | -3.41 |
| 700 | 154 | 0.96 | -5.41 [-6.35, -4.45] | -3.40 |
| 800 | 152 | 0.94 | -5.33 [-6.20, -4.40] | -3.31 |
| 900 | 148 | 0.92 | -5.37 [-6.32, -4.40] | -3.41 |
| 1000 | 146 | 0.91 | -5.40 [-6.43, -4.40] | -3.42 |

Spearman correlation, quote age vs gross +10s edge: **-0.042** (permutation p = 0.598, n = 161; fills within a 5-minute block are autocorrelated so the true p is larger); vs mid markout +10s: -0.085.

**Fill -> measured-exit lag** (exit_time - fill timestamp): min 10006, median 10238, max 10501 ms (the 10 s horizon is polled every 0.5 s, so the exit is read 0-500 ms late). Spearman(exit lag, gross) = +0.046.
