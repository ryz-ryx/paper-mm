_Independent recomputation from raw logged fields (side, fill_price, far_touch_exit_10s, mids); nothing is imported from engine.py._

| check | result | detail |
|---|---|---|
| round_trip_edge_bps == side-signed (far_touch_exit - fill)/fill*1e4 | PASS | n=6064, max |diff| = 5.00e-05 bps (tolerance 0.0005, engine rounds to 4 dp) |
| rt_net_hl == edge - 6 | PASS | max |diff| = 5.00e-05 bps |
| rt_net_binance_vip0 == edge - 20 | PASS | max |diff| = 5.00e-05 bps |
| rt_net_binance_bnb == edge - 15 | PASS | max |diff| = 5.00e-05 bps |
| rt_net_zero_fee == edge - 0 | PASS | max |diff| = 5.00e-05 bps |
| fee totals match the task / pre-registration (HL 1.5+4.5, VIP0 10+10, BNB 7.5+7.5) | PASS | 6 / 20 / 15 bps round trip; the 3 bps maker+maker set has no engine column (computed here as edge - 3) |
| far-touch exit lies on the unfavourable side of mid_10s (buys exit at bid <= mid, sells at ask >= mid) | PASS | 0 violations of 6064 |
| implied exit half-spread >= 0 and same scale as placement spread / 2 | PASS | exit half-spread mean 1.80 bps vs placement half-spread mean 1.99 bps |
| no silent fallback exit (engine falls back to fill_price if far_touch is missing/0, which would book edge = 0) | PASS | missing/zero far_touch rows: 0. 401 rows have exit == fill price exactly: legitimate (the resting level was unchanged 10 s later); all of them satisfy the exit-side check above |
| fill_price == quote_price on every primary fill | PASS | fills are booked at the quoted price, not at the (possibly better) trade print |
| quote size is $10 notional (Amendment 2) | PASS | notional min 9.9869, max 10.0125 |
| fill_id unique; flags consistent (primary=True, queue_depleted=False, reason trade_through) | PASS | 6064 unique ids |
| exit read no earlier than 10 s after the fill and within one 0.5 s poll (+ margin) | WARN | lag min 10000 / median 10247 / max 60454 ms; 7 of 6064 rows (0.12%) outside [10.0, 10.6] s, read 57-60 s late at 13:09:57, 13:09:59, 13:10:00 UTC (gross there -19.2 vs -4.8 bps elsewhere; effect on the pooled mean -0.017 bps) |
| 8-decimal price logging is not material (mid-based markouts) | WARN | max half-unit rounding error 13.16 bps; 11 fills (0.18%) above 0.5 bps: binance:PEPEUSDT. Fill/exit prices are on-tick and exact, so the gross edge is unaffected; mid_1s/10s/60s (half-tick values) are quantised for those fills |
| pending.csv EXIT_10S / COMPLETED records agree with trades.csv | PASS | 6064 trades vs 6064 COMPLETED, 6064 EXIT_10S |
| arm B and C fills are subsets of arm A fills (same trade print) | WARN | B-in-A 94.6%; C-in-A 92.5%; C-in-B 97.9%. 6064 rows = 3973 distinct physical fill events (81 appear only in B or C): arms requote independently, so they are ~95% nested, not strictly; pooled arm statistics still double count |
| reporter.py printed gross means == independent recomputation | PASS | BIN-A: reporter -6.16 vs independent -6.16; BIN-B: reporter -5.82 vs independent -5.82; BIN-C: reporter -6.14 vs independent -6.14; HYP-A: reporter -4.60 vs independent -4.60; HYP-B: reporter -4.41 vs independent -4.41; HYP-C: reporter -4.40 vs independent -4.40 |

**Data-quality observations**

| observation | value |
|---|---|
| share of fills where mid_1s == mid_10s (book unchanged for 9 s) | 8.9% |
| share of fills where mid_1s == fill price (zero half-spread) | 1.5% |
| realised_vol_10s == 0 at placement | 84.4% |
| flow_1s == 0 at placement | 91.9% |
