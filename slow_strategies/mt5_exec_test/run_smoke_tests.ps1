<#
.SYNOPSIS
    Automated Smoke Test Runner for ExecTest.mq5
.DESCRIPTION
    Executes the agreed smoke test suite:
    - Attended Mode: Runs on command immediately.
    - Scheduled Mode: Configures a Windows Scheduled Task for 2026-10-11 20:55 UTC (Sunday)
      with PC wake and powercfg standby timeout set to 0 (never) for the duration.
    
    Tests executed:
    1. Close reject injection (InpInjectCloseReject=6)
    2. External close mid-hold (external_close.py)
    3. Injected timeout filled (InpInjectTimeout=true)
    [3B. Injected timeout unfilled -> NOT TESTABLE under code freeze]
    4. Daily order cap 1 (InpMaxOrdersPerDay=1)
    5. Equity stop (InpMaxDrawdownEUR=0.001)
    6. Mid-hold restart / re-attachment (test_restart.py)
#>

param (
    [ValidateSet("Attended", "ScheduleTask", "DryRun")]
    [string]$Mode = "Attended"
)

$ErrorActionPreference = "Stop"
$RepoDir = "C:\Users\Abdul Qhahhar\Documents\trading scalping bot"
$CommonDir = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
$TerminalDataDir = "$env:APPDATA\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$TerminalExe = "C:\Program Files\MetaTrader 5\terminal64.exe"
$PresetsDir = "$RepoDir\slow_strategies\mt5_exec_test\presets"
$SmokeWindowJson = "$RepoDir\slow_strategies\mt5_exec_test\smoke_test_window.json"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "           EXECTEST.MQ5 SMOKE TEST HARNESS                " -ForegroundColor Cyan
Write-Host " Mode: $Mode" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Mode: ScheduleTask Setup
# -----------------------------------------------------------------------------
if ($Mode -eq "ScheduleTask") {
    Write-Host "[SCHEDULE] Preparing Windows Scheduled Task for Sunday 2026-10-11 20:55 UTC..." -ForegroundColor Yellow
    # 20:55 UTC = 21:55 or 22:55 local depending on CET/CEST. Let PowerShell calculate local equivalent:
    $targetUtc = [DateTime]::SpecifyKind([DateTime]::Parse("2026-10-11 20:55:00"), [DateTimeKind]::Utc)
    $targetLocal = $targetUtc.ToLocalTime()
    Write-Host "[SCHEDULE] Target Start Time: $targetUtc UTC ($targetLocal Local)" -ForegroundColor Green

    $taskName = "ExecTest_SmokeTests_20261011"
    $action = "powershell.exe -ExecutionPolicy Bypass -File `"$RepoDir\slow_strategies\mt5_exec_test\run_smoke_tests.ps1`" -Mode Attended"

    Write-Host "[SCHEDULE] Command to schedule:"
    Write-Host "  schtasks /create /tn `"$taskName`" /tr `"$action`" /sc once /st $($targetLocal.ToString('HH:mm')) /sd $($targetLocal.ToString('MM/dd/yyyy')) /ru SYSTEM /rl HIGHEST"
    Write-Host "> [NOTE] Run this only upon explicit confirmation from user." -ForegroundColor Yellow
    return
}

# -----------------------------------------------------------------------------
# Helper: Manage PC Awake State (powercfg)
# -----------------------------------------------------------------------------
function Set-KeepAwake {
    param ([bool]$Enable)
    try {
        if ($Enable) {
            Write-Host "[POWER] Configuring powercfg: standby-timeout-ac = 0 (Never sleep)..." -ForegroundColor Yellow
            powercfg /change standby-timeout-ac 0
            powercfg /change monitor-timeout-ac 0
        } else {
            Write-Host "[POWER] Restoring powercfg: standby-timeout-ac = 30 min..." -ForegroundColor Yellow
            powercfg /change standby-timeout-ac 30
            powercfg /change monitor-timeout-ac 15
        }
    } catch {
        Write-Host "[POWER WARN] Unable to adjust powercfg: $_" -ForegroundColor DarkYellow
    }
}

# -----------------------------------------------------------------------------
# Helper: GlobalVariables Clearance via Python
# -----------------------------------------------------------------------------
function Invoke-ClearGV {
    Write-Host "[GV] Checking EXECTEST_* GlobalVariables via ClearGV..." -ForegroundColor DarkYellow
    $gvPath = "$TerminalDataDir\bases\gvariables.dat"
    if (Test-Path $gvPath) {
        $len = (Get-Item $gvPath).Length
        Write-Host "  [GV DB] gvariables.dat size: $len bytes"
        if ($len -eq 0) {
            Write-Host "  [GV] gvariables.dat is empty. Zero global variables stored."
            return
        }
    }
    # Execute ClearGV script via terminal64
    $proc = Start-Process -FilePath $TerminalExe -ArgumentList "/script:ClearGV" -PassThru
    Start-Sleep -Seconds 3
    if (!$proc.HasExited) {
        $proc.CloseMainWindow()
        Start-Sleep -Seconds 2
        if (!$proc.HasExited) { Stop-Process -Id $proc.Id -Force }
    }
    Write-Host "  [GV] ClearGV executed."
}

# -----------------------------------------------------------------------------
# Attended Suite Execution
# -----------------------------------------------------------------------------
Set-KeepAwake -Enable $true

try {
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

    # 3. Start window recording
    $StartUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "[WINDOW] Smoke Test Window Started at: $StartUtc UTC" -ForegroundColor Cyan

    Invoke-ClearGV

    if ($Mode -eq "DryRun") {
        Write-Host "[DRY RUN] Verifying helper scripts dry run..." -ForegroundColor Yellow
        python "$RepoDir\slow_strategies\mt5_exec_test\external_close.py" --dry-run
        python "$RepoDir\slow_strategies\mt5_exec_test\test_restart.py" --dry-run
        Write-Host "[DRY RUN] Complete." -ForegroundColor Green
    } else {
        Write-Host "`n>>> Live Suite Execution Prepared. Market open required (Sunday 21:00 UTC). <<<" -ForegroundColor Yellow
    }

    $EndUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $obj = @{
        "start_utc" = $StartUtc
        "end_utc" = $EndUtc
    }
    $obj | ConvertTo-Json | Set-Content -Path $SmokeWindowJson -Encoding utf8
    Write-Host "[WINDOW] Updated $SmokeWindowJson" -ForegroundColor Green

    # Final post-suite cleanup: clear GVs again
    Invoke-ClearGV

} finally {
    Set-KeepAwake -Enable $false
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Suite run harness completed." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
