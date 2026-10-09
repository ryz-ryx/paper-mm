_Dataset: Phase 1a / v1 archive (exploratory only; excluded from Phase 1b statistics by Amendment 3). Primary fills: 6064 rows; queue-depleted events: 2833 rows; window 2026-10-08 06:43 .. 2026-10-08 17:30 UTC (647 min, 127 five-minute blocks). Exploratory / secondary only._

**(a) Are outcomes logged for queue-depleted events?** No: every outcome field is empty in this dataset (pre-D4 engine), so the edge of a queue-depleted fill is not measurable.

| field | primary rows with value | queue-depleted rows with value |
|---|---|---|
| mid_1s | 6064 | 0 |
| mid_10s | 6064 | 0 |
| mid_60s | 6047 | 0 |
| far_touch_exit_10s | 6064 | 0 |
| exit_time_ms | 6064 | 0 |
| round_trip_edge_bps | 6064 | 0 |

**(b) Counts**

| venue | arm | primary (trade-through) | queue-depleted | QD per primary |
|---|---|---|---|---|
| hyperliquid | A | 3026 | 718 | 0.24 |
| hyperliquid | B | 947 | 169 | 0.18 |
| hyperliquid | C | 916 | 164 | 0.18 |
| binance | A | 866 | 1477 | 1.71 |
| binance | B | 153 | 158 | 1.03 |
| binance | C | 156 | 147 | 0.94 |

**(c) Logged features at placement, hyperliquid arm A**

| fill rule (hyperliquid, arm A) | n | mean spread bps | median spread bps | mean own-side imbalance | median queue ahead (x size) | share flow_1s = 0 | share vol_10s = 0 | distinct instruments |
|---|---|---|---|---|---|---|---|---|
| primary (trade-through) | 3026 | 3.74 | 2.84 | 0.48 | 28.62 | 0.93 | 1.00 | 24 |
| queue-depleted | 718 | 4.56 | 3.36 | 0.43 | 3.93 | 0.94 | 1.00 | 22 |

**(d) hyperliquid: share of queue-depleted events later followed by a primary fill** (a trade-through needs a print *below* our bid, so it samples fills that coincide with price breaking against the quote; queue depletion needs only prints *at* our price)

| window after the queue-depleted event | QD events (arm A) | followed by a primary fill, same instrument+side | share |
|---|---|---|---|
| 2 s | 718 | 96 | 0.13 |
| 10 s | 718 | 190 | 0.26 |

**(c) Logged features at placement, binance arm A**

| fill rule (binance, arm A) | n | mean spread bps | median spread bps | mean own-side imbalance | median queue ahead (x size) | share flow_1s = 0 | share vol_10s = 0 | distinct instruments |
|---|---|---|---|---|---|---|---|---|
| primary (trade-through) | 866 | 5.24 | 4.38 | 0.47 | 59.45 | 0.84 | 0.22 | 15 |
| queue-depleted | 1477 | 4.70 | 4.33 | 0.46 | 15.43 | 0.87 | 0.29 | 15 |

**(d) binance: share of queue-depleted events later followed by a primary fill** (a trade-through needs a print *below* our bid, so it samples fills that coincide with price breaking against the quote; queue depletion needs only prints *at* our price)

| window after the queue-depleted event | QD events (arm A) | followed by a primary fill, same instrument+side | share |
|---|---|---|---|
| 2 s | 1477 | 132 | 0.09 |
| 10 s | 1477 | 205 | 0.14 |

**Conclusion for item 3:** the data cannot show an edge difference. The primary rule is mechanically adverse (a fill needs a through-print), so primary edge is a conservative lower bound, not an unbiased estimate of queue-position economics. D4 (Phase 1b engine) logs the missing outcome fields, so this comparison becomes possible on Phase 1b data.
