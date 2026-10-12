# Recovered Data Directory

The files in this directory:
- `trades_recovered.csv`
- `pending_recovered.csv`
- `queue_depleted_recovered.csv`

contain historical rows recovered from prior committed revisions and run artifacts (including `main@11a9035` and cancelled run artifact `11736019599` covering 2026-10-12 07:26 UTC through 09:08 UTC).

**CRITICAL**: These files are static reference data and are **never appended to by the bot or overwritten by runner state loops**.
Analysis scripts and reporters load both the active live directory (`paper_mm2/data/`) and `paper_mm2/data_recovered/`, deduplicating records by composite key (`fill_id, timestamp_ms` / `fill_id, timestamp_ms, status`) to ensure continuous, gapless historical evaluations without being impacted by runner git rebases.
