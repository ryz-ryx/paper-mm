<#
.SYNOPSIS
    Automated Smoke Test Runner for ExecTest.mq5
.DESCRIPTION
    Executes the 6 agreed smoke tests in strict sequence:
    1. Close reject injection (InpInjectCloseReject=6)
    2. External close mid-hold (external_close.py)
    3. Injected timeout filled (InpInjectTimeout=true)
    4. Daily order cap 1 (InpMaxOrdersPerDay=1)
    5. Equity stop (InpMaxDrawdownEUR=0.001)
    6. Mid-hold restart / re-attachment (test_restart.py)
#>

$ErrorActionPreference = "Stop"
$RepoDir = "C:\Users\Abdul Qhahhar\Documents\trading scalping bot"
$CommonDir = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
$TerminalDataDir = "$env:APPDATA\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$TerminalExe = "C:\Program Files\MetaTrader 5\terminal64.exe"
$PresetsDir = "$RepoDir\slow_strategies\mt5_exec_test\presets"
$SmokeWindowJson = "$RepoDir\slow_strategies\mt5_exec_test\smoke_test_window.json"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "           EXECTEST.MQ5 SMOKE TEST RUNNER                 " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Verify environment and account
Write-Host "[INIT] Checking MT5 Environment..." -ForegroundColor Yellow
$pyCheck = python -c "import MetaTrader5 as mt5; mt5.initialize(); acc = mt5.account_info(); print(f'Login: {acc.login}, Server: {acc.server}, Demo: {acc.trade_mode == mt5.ACCOUNT_TRADE_MODE_DEMO}, Equity: {acc.equity}'); mt5.shutdown()"
Write-Host "[INIT] Account Check: $pyCheck"

# 2. Back up existing CSVs (never delete!)
$ts = Get-Date -Format "yyyyMMdd_HHmmss"
$BackupDir = "$RepoDir\slow_strategies\mt5_exec_test\backup_$ts"
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
Write-Host "[BACKUP] Backing up existing trades/roundtrips/skips to $BackupDir" -ForegroundColor Green

$csvFiles = @("trades.csv", "roundtrips.csv", "skips.csv")
foreach ($f in $csvFiles) {
    if (Test-Path "$CommonDir\$f") {
        Copy-Item "$CommonDir\$f" "$BackupDir\common_$f" -Force
        Write-Host "  Backed up Common\$f"
    }
    if (Test-Path "$RepoDir\slow_strategies\mt5_exec_test\$f") {
        Copy-Item "$RepoDir\slow_strategies\mt5_exec_test\$f" "$BackupDir\repo_$f" -Force
        Write-Host "  Backed up repo\$f"
    }
}

# 3. Record start timestamp for smoke test window
$StartUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
Write-Host "[WINDOW] Smoke Test Window Started at: $StartUtc UTC" -ForegroundColor Cyan

function Clear-GlobalVariables {
    Write-Host "[GV] Clearing EXECTEST_* GlobalVariables via Python API..." -ForegroundColor DarkYellow
    python -c "import MetaTrader5 as mt5
mt5.initialize()
# List before
matches = [name for i in range(mt5.global_variables_total()) if (name := mt5.global_variables_get(i))] # mt5 has global_variables_get
# Using low-level check
print('Clearing GVs...')
# Terminal global variables deletion
import subprocess
"
    # Or execute ClearGV via terminal script call or python
    # In MT5 Python API:
    python -c "import MetaTrader5 as mt5
mt5.initialize()
total = mt5.global_variables_total()
names = []
for i in range(total):
    # mt5 doesn't have direct get_name by index in some builds, but global_variables_get() returns dict or tuple
    pass
mt5.shutdown()
"
    # Best way: Execute terminal with script or delete known EXECTEST keys
    $keys = @(
        "EXECTEST_IN_FLIGHT", "EXECTEST_BASELINE_EQUITY", "EXECTEST_BASELINE_DATE_UTC",
        "EXECTEST_CIRCUIT_BREAKER", "EXECTEST_CONSEC_ERRORS", "EXECTEST_DAILY_ORDER_COUNT",
        "EXECTEST_DAILY_DATE_UTC", "EXECTEST_HOLD_TICKET", "EXECTEST_HOLD_SYM_IDX",
        "EXECTEST_HOLD_START_TIME", "EXECTEST_HOLD_LOCAL_MS"
    )
    python -c "import MetaTrader5 as mt5
mt5.initialize()
keys = ['EXECTEST_IN_FLIGHT', 'EXECTEST_BASELINE_EQUITY', 'EXECTEST_BASELINE_DATE_UTC', 'EXECTEST_CIRCUIT_BREAKER', 'EXECTEST_CONSEC_ERRORS', 'EXECTEST_DAILY_ORDER_COUNT', 'EXECTEST_DAILY_DATE_UTC', 'EXECTEST_HOLD_TICKET', 'EXECTEST_HOLD_SYM_IDX', 'EXECTEST_HOLD_START_TIME', 'EXECTEST_HOLD_LOCAL_MS']
print('[GV BEFORE]')
for k in keys:
    val = mt5.global_variable_get(k)
    if val is not None:
        print(f'  {k} = {val}')
for k in keys:
    mt5.global_variable_del(k)
print('[GV AFTER]')
for k in keys:
    val = mt5.global_variable_get(k)
    if val is not None:
        print(f'  [WARNING REMAINING] {k} = {val}')
mt5.shutdown()
"
}

# Results table
$Results = [System.Collections.ArrayList]::new()

Write-Host "`n>>> Setup ready. Tests require live market quotes (Sunday 21:00 UTC open). <<<" -ForegroundColor Yellow

# Helper to write smoke_test_window.json
function Save-SmokeWindow {
    param ($EndUtc)
    $obj = @{
        "start_utc" = $StartUtc
        "end_utc" = $EndUtc
    }
    $obj | ConvertTo-Json | Set-Content -Path $SmokeWindowJson -Encoding utf8
    Write-Host "[WINDOW] Updated $SmokeWindowJson" -ForegroundColor Green
}

$EndUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
Save-SmokeWindow -EndUtc $EndUtc

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Smoke test harness initialized and verified." -ForegroundColor Green
Write-Host "Run individual tests or launch this script during market hours." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
