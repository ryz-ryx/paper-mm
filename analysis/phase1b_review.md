# Phase 1b review: commit 97aea8d (D1-D4, D7, reporter seed, cutover) against `phase1_preregistration.md`

Scope: `git diff 37037b2 HEAD` for `paper_mm2/engine.py`, `models.py`, `bot.py`, `reporter.py`, `tests/test_paper_mm2.py`, `EPOCH.json`,
`phase1_preregistration.md` (Amendment 3) and `recorder/`. Read-only review; nothing was modified. The 11 unit tests pass.

## Verdict

D1-D4 and D7 are implemented as Amendment 3 describes, and **D1 and D3 restore the original pre-registered rules** (requote every 1 s; cancel
when 1 s flow exceeds the 80th percentile, which for a zero percentile means any flow). No strategy parameter, fee, latency (450 ms), fill
rule or exit rule changed. There are **no arithmetic or logic bugs** in the diff. There are, however, **4 material issues** (one of which makes the
hold-out criteria unsatisfiable) and 6 minor ones.

## Material (act before relying on Phase 1b data)

| ID | Where | Issue | Effect | Suggested action |
|---|---|---|---|---|
| M1 | Amendment 3 calendar; `reporter.py` weekday/weekend criterion; pre-reg line 36 | Hold-out is 2026-10-13..16 = **Tue-Fri, no weekend day**. The PASS rule requires a positive mean "in both weekday/weekend" **on the hold-out**, so it is unsatisfiable: no arm can PASS regardless of edge. (Phase 1a's hold-out Mon 12 - Thu 15 had the same flaw; the dev window holds both weekend days.) The "≥ 7 consecutive days covering a weekend" rule (line 31) is met only because the weekend falls in the dev period. | Every arm fails the hold-out by construction. | Amend before the hold-out is opened: either move the hold-out to include a Saturday and Sunday, or drop/replace the weekend criterion with a dev-based one. Do not wait until `--final`. |
| M2 | `models.py`: `maybe_sample_flow` now also called from `update_bids_asks` | The rolling-1 h flow sample used for the 80th percentile used to be taken **only when a trade arrived** (seconds with trades). It is now taken on every book update too, so quiet seconds enter the history as zeros. For most instruments the 80th percentile will therefore be 0, and arm C degenerates to "pull the side on any adverse taker print in the last second". Amendment 3 lists D3 as the zero-percentile rule only; **the change to how the percentile is built is not disclosed**. | Arm C becomes much more restrictive than the v1 arm C (and than a reading of "rolling 80th percentile" over active seconds); fill counts for C will fall (needs 2,000 hold-out fills). Also makes B vs C differences hard to read. | Disclose it in the amendment (it is a strategy-behaviour change, not a pure logging fix) or sample only on trade/second boundaries as before; add a test on the percentile itself. |
| M3 | `engine._manage_side_quote` x D1 timer | A requote overwrites `active_quotes[arm][inst][side]` with the new quote, so the **old quote can no longer fill during its 450 ms cancel window while the new one is not live for 450 ms**. With quotes now replaced every 1.0-1.25 s there is a ~450 ms blind window in each cycle (about 36-45 % of the time on a quiet book; more when price moves). In v1 quote age at fill had a median of 2.9 s (Hyperliquid), so the effect was small; with D1 it is large. | Fill rates (all arms, both venues) will drop sharply versus Phase 1a; this is conservative for the edge but threatens the 2,000-fill requirement and changes the arm-A population (fills only on quotes of age 450 ms - 1.25 s, i.e. the freshest quotes). Not a deviation from the pre-reg text (the 450 ms rule is unchanged), but a modelling consequence nobody has quantified. | Keep the outgoing quote fillable until its cancel completes (it is "live" in reality), or at least log and report the share of time quotes are live; decide before the dev data is read. |
| M4 | `bot.run_requote_timer_loop` | Timer calls `update_quote_logic` for every book at 4 Hz with local wall-clock `now_ms`, even when the feed has stalled (no staleness check). A frozen book keeps being requoted at a stale price, and `get_10s_realised_vol`, `get_1s_taker_flow` and the pause logic run on stale inputs. | Fills need a trade, so a stalled feed mostly produces no fills; but quotes and vol readings logged during stalls are unreliable and the 60 s fast-move pause cannot trigger without updates. | Skip books whose last update is older than a few seconds (and log the gap in `downtime.csv`). |

## Minor

| ID | Where | Issue |
|---|---|---|
| m1 | `reporter.py` | Printed label "99.58% CI [lo, hi]": the interval is (alpha, 1-alpha) = 99.16 % two-sided; 99.58 % is the one-sided confidence of the lower bound alone (the same labelling slip existed with 99.17 % before). The decision rule (lower bound at alpha 0.0042) is correct. |
| m2 | No tests for D1 (timer loop) or D7 (screen file) | Tests added: D2 vol, D3 zero percentile, D4 outcome logging. The timer and `screen_YYYYMMDD.json` writer are untested. |
| m3 | `engine.process_trade` docstring | Still says queue-depleted events are logged "without ... creating a pending exit"; D4 now creates one (stale docstring). |
| m4 | Amendment 3, test counter | Counts 6 prior + 6 new = 12 (alpha 0.0042). Line 45 still states "prior programme tests: 10 hypotheses + market-making variants", which the 12 does not include; the Phase 1a tests are counted although their hold-out was never opened (conservative). State the counting rule explicitly. |
| m5 | Same commit adds `recorder/recorder.py` (394 lines) and a workflow | Not mentioned in Amendment 3. It records trades and 250 ms snapshots to parquet and does not touch the strategy, but it is scope the amendment does not cover. |
| m6 | D2 | `realised_vol_10s` is the stratification variable for the terciles; redefining it after seeing the v1 data (where it was 99.6 % zeros on Hyperliquid) is reasonable and disclosed, but it is a post-hoc specification: the terciles are only meaningful from Phase 1b data on. |

## Checked and fine

- D1 requote: condition (≥ 1 tick move or ≥ 1000 ms) matches pre-reg line 23; granularity is the 250 ms poll (requote at 1.0-1.25 s), negligible.
- D2 vol: 11 one-second-sampled mids, 10 returns, sample stdev × 1e4, 0 when flat or invalid, as in Amendment 3.
- D3 zero-percentile branch and the "re-quote after 1 s calm" (the 1 s flow window empties by itself): implemented as written; test covers it.
- D4: queue-depleted events create a pending exit that never changes inventory (checked for both live and restart-restore paths), outcomes land in `queue_depleted.csv`, and the primary fill count is unaffected.
- D7: `screen_YYYYMMDD.json` is written atomically (tmp file then `os.replace`) with both venues' lists.
- Reporter: seed 20261009, alpha 0.0042, new calendar read from `EPOCH.json`; decision logic unchanged.
- `EPOCH.json` matches Amendment 3 (cutover 2026-10-08T17:45Z, dev 10-09..12, hold-out 10-13..16, partial first day excluded). `paper_mm2/data/` is empty and the v1 data sits in `data_v1/`, so Phase 1b has not yet produced a row.
