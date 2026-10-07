# Live Paper Market-Making Bot (Binance WebSocket)

A high-frequency paper market-making bot running on live Binance public WebSocket streams without accounts or API keys.

## Architecture & Data Streams
- **URL**: `wss://stream.binance.com:9443/stream`
- **Active Streams**:
  - `btcusdt@bookTicker`, `ethusdt@bookTicker` (Best Bid/Ask real-time updates)
  - `btcusdt@aggTrade`, `ethusdt@aggTrade` (Live trades)
  - `btcusdt@depth20@100ms` (Top 20 order book levels for depth size ahead)
- **Data Persistence**: Raw market messages buffered and written to `paper_mm/raw_data/events_<timestamp>.parquet` every 60 seconds.

## Strategy Specifications
- **Symbols**: `BTCUSDT`, `ETHUSDT`
- **Quote Sizing**: 0.001 BTC / 0.01 ETH per quote side.
- **Half-Spread**: `max(1 tick, 0.5 * trailing 60s median spread)`.
- **Quote Refresh**: Cancel & requote whenever mid moves $> 1$ tick or every 1.0 second.
- **Volatility Filter**: Quoting automatically pauses for 60 seconds if trailing 10-second price move exceeds 10 bps.
- **Inventory Management**:
  - Threshold limit: $\pm 0.01$ BTC / $\pm 0.1$ ETH.
  - If limit is breached, quotes only the reducing side.
  - Periodic Flattening: Every 10 minutes, non-zero inventory is flattened at the touch (paying taker fee).

## Conservative Fill Model
1. **150 ms Latency**: Simulated network latency on all new quotes and cancellations (`live_after = now + 0.150s`).
2. **Resting Bid Execution**:
   - **Trade-Through**: Fills immediately if an `aggTrade` prints strictly below the bid price (`p < bid`).
   - **Queue Depletion**: If an `aggTrade` prints at the bid price, the size ahead of the order (full displayed depth at placement) must be exhausted before the fill occurs.
3. **Resting Ask Execution**: Symmetric logic for asks.
4. **Zero Partial Fill Optimism**: Requires the complete queue to clear.

## Fee Scenarios Evaluated in Parallel
From the exact same fill sequence, four fee regimes are computed:
1. `maker_10_taker_10`: 0.10% maker / 0.10% taker
2. `maker_02_taker_10`: 0.02% maker / 0.10% taker (standard VIP / referral tier)
3. `maker_00_taker_10`: 0.00% maker / 0.10% taker (zero-fee promos)
4. `rebate_005_taker_10`: -0.005% maker rebate / 0.10% taker

## Automated Stop Rules
1. **Adverse Selection Rule (Day 3)**:
   - Evaluated after 72 hours of continuous run.
   - If 10s markout averages below `-(half-spread captured)`, the bot automatically stops with verdict: *"adverse selection exceeds spread captured"*.
2. **Net P&L Rule (Day 7)**:
   - Evaluated after 168 hours of continuous run.
   - Net P&L must be positive in at least 5 of 7 days under at least one realistic fee scenario (`maker_02_taker_10` or better) to continue to Day 14.

## Process Management & How to Resume

### Process Status
The bot runs as a background process with auto-reconnect logic on WebSocket drops.

### Output Files & Directories
- `paper_mm/paper_mm.log`: Real-time operation and fill log.
- `paper_mm/raw_data/`: Hourly/minutely parquet dumps of raw market events.
- `paper_mm/fills/fills_latest.parquet`: Full table of simulated fills with queue depletion reason, mid at fill, and inventory state.
- `paper_mm/reports/latest_report.txt`: 24-hour summary report with markouts and P&L decomposition.
- `paper_mm/reports/report_history.txt`: Cumulative history of daily reports.

### Inspecting Live Status
To inspect the running log:
```powershell
Get-Content -Path "paper_mm/paper_mm.log" -Tail 20
```

To view current fills:
```python
import pandas as pd
df = pd.read_parquet('paper_mm/fills/fills_latest.parquet')
print(df.tail(10))
```

### Stopping the Bot
To terminate the process:
Identify the Python process running `paper_mm_bot.py` via Task Manager or PowerShell:
```powershell
Get-Process python | Where-Object { $_.CommandLine -like "*paper_mm_bot.py*" } | Stop-Process
```

### Resuming the Bot
If interrupted or rebooted, simply restart the daemon:
```powershell
python -u paper_mm/paper_mm_bot.py
```
It will resume appending to `paper_mm/paper_mm.log` and save subsequent raw files.

## Operational History & Restart Log (For Analysis Gap Exclusion)
- **Initial Launch**: `2026-10-03 14:51:17 UTC`
- **Maintenance Stop 1 (Parquet Typing Fix)**: `2026-10-03 14:57:11 UTC` to `14:58:25 UTC` (Duration: 74s).
- **Maintenance Stop 2 (Persistent Trade Logging Upgrade)**: `2026-10-03 15:01:19 UTC` to `15:02:43 UTC` (Duration: 84s).
- **Verification Stop & Restart Test**: `2026-10-03 15:08:34 UTC` to `15:08:41 UTC` (Duration: 7s).
- **User Stop**: `2026-10-03 15:24:32 UTC`.
- **System Server Restart Gap**: `2026-10-03 17:55:00 UTC` to `2026-10-04 16:41:06 UTC`.
- **Background Daemon Restart**: `2026-10-04 16:41:06 UTC` (Task ID `task-2705`).
  - State restore confirmed: Restored 249 historical trades from `trades.csv`, restored inventory BTC (`0.0000`), ETH (`0.0000`), next `trade_id: 249`.
  - Immediate new live fills confirmed in `paper_mm.log` and `trades.csv` (e.g. trade_id 249: ETHUSDT BUY 0.01 @ 2704.39).
- **Maintenance Stop 3 (Queue Ahead Logging-Only Patch)**: `2026-10-04 17:01:13 UTC` to `17:01:57 UTC` (Duration: 44s, Task ID `task-2869`).
  - Patched `paper_mm_bot.py` to record `queue_ahead_initial` at quote placement and log it into `queue_ahead_at_placement` in `trades.csv`.
  - State restore confirmed: Restored 291 trades from `trades.csv`, restored inventory BTC (`0.0000`), ETH (`0.0000`), next `trade_id: 291`.
- **Audit Note**: All strategy rules, quoting parameters, $150\text{ ms}$ latency penalties, and conservative fill execution models were **100% untouched**.




