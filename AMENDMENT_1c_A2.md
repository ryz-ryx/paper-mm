# AMENDMENT_1c_A2.md
**Phase 1c Protocol Amendment A2 — Monday 2026-10-12**

---

### 1. Context & Motivation
Following the diagnostic analysis of the Hyperliquid WebSocket feed documented in `AMENDMENT_1c_A1.md`:
- The upstream `l2Book` stream on Hyperliquid batches book updates on quiet coins in ~5.3 s cycles.
- Condition M4 (requiring book updates within 2000 ms) triggered ~3,796 stale cancellations per run, starving the Hyperliquid arm of resting quotes.
- A 4-way feed test confirmed that the Hyperliquid `bbo` channel delivers sub-second top-of-book updates across quiet coins.
- Option A was adopted: transition the Hyperliquid arm to the `bbo` channel under a new code-version epoch (`EPOCH_1C_BBO_V1`).

---

### 2. Epoch Definition & Pre-Registration Windows
- **New Code Epoch**: `EPOCH_1C_BBO_V1`.
- **Binance Hold-Out Code Version**: `01917b8` (committed 2026-10-12, git tag `holdout-code-v1`).
- **Hold-Out Code Hashes (SHA-256 at `01917b8`)**:
  - `paper_mm2/bot.py`: `a8d92a26e79009b6e0686ca078c6f4ee81517899c6a91c77639e8396f3277bd5`
  - `paper_mm2/engine.py`: `6178446101a5528c4c6c497c4373d46b575127eb2a450c6f99686ec79fb0d330`
  - `paper_mm2/models.py`: `28214df26291a7173c4cad8791b433cdb8d3a8996ef1f63ced35947366d63d2f`
- **Hyperliquid Epoch Start Timestamp**: `2026-10-12 09:08:48 UTC` (first UTC timestamp of the first valid HL bbo message of the running production runner `38227946597` checking out `01917b8`).
- **Hyperliquid Development Window**: The first 48 hours of valid BBO feed data post-deploy (`2026-10-12 09:08:48 UTC` through `2026-10-14 09:08:48 UTC`).
- **Hyperliquid Hold-Out Window**: The following 6 calendar days (`2026-10-14 09:08:48 UTC` through `2026-10-20 09:08:48 UTC`).
- **Parameter Freeze**: All execution parameters remain strictly frozen at the end of the dev window (`2026-10-14 09:08:48 UTC`).
- **Binance Arm Unchanged**: The Binance hold-out period remains locked to **2026-10-13 00:00 UTC through 2026-10-18 23:59:59 UTC**.
- **Data Gap Disclosure (2026-10-12 08:30:57 UTC to 09:08:48 UTC)**:
  - Fills and pending orders occurring between `08:30:57 UTC` and `09:08:48 UTC` are unrecoverable due to runner `38218075606`'s 08:50 UTC rebase onto migrated files prior to cancellation.
  - Quotes were preserved up to `09:08:17 UTC` in `quotes_20261012_09.csv.gz`.
  - Fills cleanly resume at `2026-10-12 09:08:48 UTC` with deployment `01917b8`. Logged in `paper_mm2/data_recovered/gaps.csv`.
- **Bonferroni Test Counter**: Unchanged. The statistical hypothesis and Bonferroni family-wise alpha threshold are maintained across the new data regime, as pre-registered with disclosure.

---

### 3. Hyperliquid M4 Staleness & Recovery Architecture
- **Venue-Level Staleness**:
  - Condition M4 for Hyperliquid is strictly venue-level: a staleness event occurs if no `bbo` OR `trades` message is received from **ANY** Hyperliquid universe coin for `> 2000 ms`.
  - When triggered, all active Hyperliquid quotes are cancelled (`cancel_all_venue('hyperliquid')`), and `venue_stale['hyperliquid'] = True`.
  - Recovery occurs upon receiving the next valid `bbo` OR `trades` message from ANY coin. On recovery, `venue_stale` is cleared to `False`, and a single continuous downtime record is appended to `downtime.csv`.
- **Refactored Bot Methods**:
  - Staleness and recovery logic are encapsulated in `PaperMM2Bot._hl_touch(now_ms)` and `PaperMM2Bot._hl_check_stale(now_ms)`.
  - `_hl_touch(now_ms)` is called on every valid message from `bbo` and `trades` channels.
  - The M4 timer loop (`run_requote_timer_loop`) delegates Hyperliquid checks to `_hl_check_stale(now_ms)`. No inline duplicates exist.
- **Per-Coin Telemetry**:
  - Per-coin BBO age is tracked for diagnostic telemetry only (`hl_coin_last_bbo_ms`, `hl_coin_stale_transitions`). Per-coin gaps do NOT trigger venue quote cancellations.
- **Malformed Message Safeguards**:
  - Upstream BBO messages missing sides, 1-sided, empty, containing `None` price/size, or non-numeric values are rejected without exception.
  - Malformed messages do **NOT** invoke `_hl_touch` and do **NOT** reset the M4 timer, preventing corrupt upstream payloads from masking stalls.

---

### 4. Filter Variable Decision: Top-1 vs Top-5 Imbalance
- **Decision**: Adopt **Option (b)** — Arm A unfiltered; Arms B and C utilize `top1_imbalance` at the exact same **0.60** threshold (`top1_imbalance >= 0.60` for bid, `top1_imbalance <= 0.40` for ask), with **zero re-tuning**.
- **Justification**:
  - The Hyperliquid `bbo` channel only provides top-1 touch depth (`bids[0]`, `asks[0]`). Level-2 to Level-5 depths are not provided by `bbo`.
  - Retaining Arms B and C with `top1_imbalance` preserves the test matrix comparing passive quoting (Arm A) against orderbook imbalance filtering (Arm B) and flow toxicity cancellation (Arm C). Disabling Arms B and C would discard two pre-registered hypotheses.
  - Applying the identical 0.60 threshold without parameter optimization ensures strict fidelity to pre-registration rules.
- **Schema Separation & Isolation**:
  - `OrderBook.get_top5_imbalance()` returns `float('nan')` for Hyperliquid (`venue != 'binance'`), ensuring Hyperliquid never writes a spurious top-5 imbalance.
  - `OrderBook.get_top1_imbalance()` computes `bid_sz / (bid_sz + ask_sz)` directly from touch depth.
  - `top1_imbalance` is persisted as a dedicated distinct column appended as the final field across all output CSV files (`quotes.csv`, `trades.csv`, `pending.csv`, `queue_depleted.csv`), guaranteeing that top-1 and top-5 imbalances are never conflated in subsequent empirical analysis.

---

### 5. Proof of Queue Ahead Validity at Placement
- In `engine.py`, quote placement is invoked via `_manage_side_quote(..., touch_price=book.best_bid, ...)`.
- Inside `_manage_side_quote`:
  ```python
  q_ahead = book.get_displayed_depth_at(side, touch_price)
  new_q = ActiveQuote(..., price=touch_price, queue_ahead=q_ahead, ...)
  ```
- Because every quote is constructed directly with `price = touch_price`, the quote price at placement is mathematically identical to the current BBO touch price.
- In `models.py`, `get_displayed_depth_at('BUY', price)` aggregates all depth at or above `price - 1e-9`. At the touch, this exactly equals the touch bid size `bids[0][1]`.
- Thus, `queue_ahead` corresponds strictly to the pre-existing touch depth in front of the bot's newly placed resting quote.
