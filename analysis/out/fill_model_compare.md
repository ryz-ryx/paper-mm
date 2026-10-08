_Primary fills: n = 241 rows; queue-depleted events: n = 58 rows; window 2026-10-08 06:43 .. 2026-10-08 07:22 UTC (39 min, 9 five-minute blocks). Exploratory / secondary only._

**(a) Are outcomes logged for queue-depleted events?** No: every outcome field is empty, so the edge of a queue-depleted fill is not measurable from `queue_depleted.csv` (and the book path is not stored anywhere else).

| field | primary rows with value | queue-depleted rows with value |
|---|---|---|
| mid_1s | 241 | 0 |
| mid_10s | 241 | 0 |
| mid_60s | 241 | 0 |
| far_touch_exit_10s | 241 | 0 |
| exit_time_ms | 241 | 0 |
| round_trip_edge_bps | 241 | 0 |

**(b) Counts**

| venue | arm | primary (trade-through) | queue-depleted | QD per primary |
|---|---|---|---|---|
| hyperliquid | A | 161 | 38 | 0.24 |
| hyperliquid | B | 41 | 10 | 0.24 |
| hyperliquid | C | 39 | 10 | 0.26 |
| binance | A | 0 | 0 |  |
| binance | B | 0 | 0 |  |
| binance | C | 0 | 0 |  |

**(c) Logged features at placement, arm A**

| fill rule (arm A) | n | mean spread bps | median spread bps | mean own-side imbalance | median queue ahead (x size) | share flow_1s = 0 | share vol_10s = 0 | distinct instruments |
|---|---|---|---|---|---|---|---|---|
| primary (trade-through) | 161 | 4.16 | 2.57 | 0.48 | 39.99 | 0.97 | 0.99 | 12 |
| queue-depleted | 38 | 5.05 | 3.49 | 0.43 | 4.59 | 0.95 | 1.00 | 9 |

**(d) How the two rules relate.** A trade-through fill requires a print *below* our bid (a move through the level), so by construction the primary rule samples fills that coincide with price breaking against the quote; a queue-depleted event needs only prints *at* our price. Share of queue-depleted events that later become a primary fill:

| window after the queue-depleted event | QD events (arm A) | followed by a primary fill, same instrument+side | share |
|---|---|---|---|
| 2 s | 38 | 7 | 0.18 |
| 10 s | 38 | 10 | 0.26 |

**Conclusion for item 3:** the data cannot show an edge difference. The primary rule is mechanically adverse (fills are conditioned on a through-print), so primary edge is a conservative lower bound, not an unbiased estimate of queue-position economics. Measuring the secondary variant needs the engine to log mids / far-touch exit for queue-depleted events (an engine change, therefore a new pre-registration amendment, outside this task).
