_Independent recomputation from raw logged fields (side, fill_price, far_touch_exit_10s, mids); nothing is imported from engine.py._

| check | result | detail |
|---|---|---|
| round_trip_edge_bps == side-signed (far_touch_exit - fill)/fill*1e4 | PASS | n=241, max |diff| = 4.99e-05 bps (tolerance 0.0005, engine rounds to 4 dp) |
| rt_net_hl == edge - 6 | PASS | max |diff| = 4.99e-05 bps |
| rt_net_binance_vip0 == edge - 20 | PASS | max |diff| = 4.99e-05 bps |
| rt_net_binance_bnb == edge - 15 | PASS | max |diff| = 4.99e-05 bps |
| rt_net_zero_fee == edge - 0 | PASS | max |diff| = 4.99e-05 bps |
| fee totals match the task / pre-registration (HL 1.5+4.5, VIP0 10+10, BNB 7.5+7.5) | PASS | 6 / 20 / 15 bps round trip; the 3 bps maker+maker set has no engine column (computed here as edge - 3) |
| far-touch exit lies on the unfavourable side of mid_10s (buys exit at bid <= mid, sells at ask >= mid) | PASS | 0 violations of 241 |
| implied exit half-spread >= 0 and same scale as placement spread / 2 | PASS | exit half-spread mean 2.27 bps vs placement half-spread mean 2.28 bps |
| no silent fallback exit (engine falls back to fill_price if far_touch is missing/0, which would book edge = 0) | PASS | missing/zero far_touch rows: 0. 6 rows have exit == fill price exactly: legitimate (the resting level was unchanged 10 s later); all of them satisfy the exit-side check above |
| fill_price == quote_price on every primary fill | PASS | fills are booked at the quoted price, not at the (possibly better) trade print |
| quote size is $10 notional (Amendment 2) | PASS | notional min 9.9884, max 10.0078 |
| fill_id unique; flags consistent (primary=True, queue_depleted=False, reason trade_through) | PASS | 241 unique ids |
| exit read no earlier than 10 s after the fill and within one 0.5 s poll | PASS | lag min 10006 / median 10230 / max 10501 ms |
| 8-decimal price logging is not material | PASS | max rounding error 0.0125 bps (lowest price 0.004015) |
| pending.csv EXIT_10S / COMPLETED records agree with trades.csv | PASS | 241 trades vs 241 COMPLETED, 256 EXIT_10S |
| arm B and C fills are subsets of arm A fills (same trade print) | PASS | 241 rows = 161 distinct physical fill events; pooled arm statistics double count |
| reporter.py printed gross means == independent recomputation | PASS | HY-A: reporter -5.36 vs independent -5.36; HY-B: reporter -4.81 vs independent -4.81; HY-C: reporter -5.12 vs independent -5.12 |

**Data-quality observations**

| observation | value |
|---|---|
| share of fills where mid_1s == mid_10s (book unchanged for 9 s) | 0.8% |
| share of fills where mid_1s == fill price (zero half-spread) | 0.4% |
| realised_vol_10s == 0 at placement | 99.2% |
| flow_1s == 0 at placement | 97.1% |
