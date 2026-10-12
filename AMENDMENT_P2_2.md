# AMENDMENT_P2_2.md
**Phase 2 Protocol Amendment P2-2 — High-Frequency Recorder BBO Stream & Cross-Venue Latency Alignment**

---

### 1. Motivation & Context
- In Phase 2 Pre-Registration (`phase2_preregistration.md`), Study S1 evaluates the Binance -> Hyperliquid lead-lag relationship (signed taker flow predicting subsequent price movements across venues).
- Section C.1 mandates a clock skew audit ($V1$) computing `ts_local - ts_exchange`.
- In Phase 1c diagnostics, exchange timestamps from Hyperliquid WebSocket updates showed substantial batching artifacts and variable transit skews relative to real-time arrival. Cross-venue event ordering based on heterogeneous exchange timestamps is vulnerable to relative clock drift and packet batching.

---

### 2. Stream Specification: Addition of Dedicated `bbo` Parquet Stream
- **New Parquet Table**: `bbo_YYYYMMDD_HH.parquet` is introduced into `recorder_data/`.
- **Schema**:
  | Field | Type | Description |
  |---|---|---|
  | `ts_exchange` | `int64` (nullable) | Exchange-reported timestamp in milliseconds (if provided) |
  | `ts_local` | `int64` | Monotonic local system arrival timestamp in milliseconds (`int(time.time() * 1000)`) |
  | `venue` | `string` | Venue identifier (`hyperliquid`) |
  | `coin` | `string` | Standard mapped coin symbol (e.g., `BTC`, `ETH`, `PURR`) |
  | `bid_px` | `float64` | Best bid price at touch |
  | `bid_sz` | `float64` | Best bid displayed size |
  | `ask_px` | `float64` | Best ask price at touch |
  | `ask_sz` | `float64` | Best ask displayed size |
  | `mid` | `float64` | Top-of-book mid price `(bid_px + ask_px) / 2.0` |
- **Buffer & Partitioning**:
  - `bbo_buffer` accumulates events in-memory and flushes on hourly boundaries using Snappy-compressed Parquet, matching existing recorder streams (`trades`, `depth`, `bursts`, `funding`).
  - Existing streams remain unaltered.

---

### 3. Cross-Venue Latency & Timestamp Policy
- **Mandate**: **Local Receive Timestamp (`ts_local`) Exclusivity for Cross-Venue Analysis**.
  - All cross-venue ordering, lead-lag event alignments, and S1 signal/response windows MUST use `ts_local` captured on the recorder instance.
  - Exchange timestamps (`ts_exchange`) are strictly prohibited as primary sequencing keys for cross-venue calculations due to disparate clock sync, upstream buffering, and venue-specific batching cycles.
  - `ts_exchange` remains logged solely for intra-venue validation and Section C.1 clock skew audits.
