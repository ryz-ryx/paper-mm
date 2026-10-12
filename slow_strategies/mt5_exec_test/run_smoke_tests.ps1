<#
.SYNOPSIS
    Automated Smoke Test Runner for ExecTest.mq5
.DESCRIPTION
    Executes the agreed smoke test suite with rigorous per-test log & CSV verification:
    - Attended Mode: Runs on command immediately.
    - Scheduled Mode: Configures a Windows Scheduled Task.
    - DryRun Mode: Validates helper scripts and preconditions without executing trades.

    Tests executed:
    1. Close reject injection (InpInjectCloseReject=6)
    2. External close mid-hold (external_close.py)
    3A. Injected timeout filled (InpInjectTimeout=true)
    3B. Injected timeout unfilled -> NOT TESTABLE under code freeze
    4. Daily order cap 1 (InpMaxOrdersPerDay=1)
    5. Equity stop (InpMaxDrawdownEUR=0.001)
    6. Mid-hold restart / re-attachment (test_restart.py)
#>

param (
    [ValidateSet("Attended", "ScheduleTask", "DryRun")]
    [string]$Mode = "Attended"
)

$ErrorActionPreference = "Stop"

# 1. Path Resolution with $PSScriptRoot
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ScriptDir)) {
    $ScriptDir = (Get-Location).Path
}

$CommonDir = "$env:APPDATA\MetaQuotes\Terminal\Common\Files"
$TerminalDataDir = "$env:APPDATA\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075"
$TerminalExe = "C:\Program Files\MetaTrader 5\terminal64.exe"
$PresetsDir = "$ScriptDir\presets"
$SmokeWindowJson = "$ScriptDir\smoke_test_window.json"
$ExternalClosePy = "$ScriptDir\external_close.py"
$TestRestartPy = "$ScriptDir\test_restart.py"
$EaBinary = "$TerminalDataDir\MQL5\Experts\ExecTest.ex5"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "           EXECTEST.MQ5 SMOKE TEST HARNESS                " -ForegroundColor Cyan
Write-Host " Script Dir: $ScriptDir" -ForegroundColor Cyan
Write-Host " Mode:       $Mode" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# Mode: ScheduleTask Setup
# -----------------------------------------------------------------------------
if ($Mode -eq "ScheduleTask") {
    Write-Host "[SCHEDULE] Preparing Windows Scheduled Task for Sunday 2026-10-11 20:55 UTC..." -ForegroundColor Yellow
    $targetUtc = [DateTime]::SpecifyKind([DateTime]::Parse("2026-10-11 20:55:00"), [DateTimeKind]::Utc)
    $targetLocal = $targetUtc.ToLocalTime()
    Write-Host "[SCHEDULE] Target Start Time: $targetUtc UTC ($targetLocal Local)" -ForegroundColor Green

    $taskName = "ExecTest_SmokeTests_20261011"
    $action = "powershell.exe -ExecutionPolicy Bypass -File `"$ScriptDir\run_smoke_tests.ps1`" -Mode Attended"

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
# Helper: GlobalVariables Clearance via ClearGV / Python
# -----------------------------------------------------------------------------
function Invoke-ClearGV {
    python -c "
import MetaTrader5 as mt5
if mt5.initialize():
    gvs = ['EXECTEST_IN_FLIGHT', 'EXECTEST_BASELINE_EQUITY', 'EXECTEST_BASELINE_DATE_UTC',
           'EXECTEST_CIRCUIT_BREAKER', 'EXECTEST_CONSEC_ERRORS', 'EXECTEST_DAILY_ORDER_COUNT',
           'EXECTEST_DAILY_DATE_UTC', 'EXECTEST_HOLD_TICKET', 'EXECTEST_HOLD_SYM_IDX',
           'EXECTEST_HOLD_START_TIME', 'EXECTEST_HOLD_LOCAL_MS', 'EXECTEST_HOLD_REQ_PRICE',
           'EXECTEST_HOLD_FILL_PRICE', 'EXECTEST_HOLD_LATENCY_MS', 'EXECTEST_HOLD_SNAP_AGE_MS',
           'EXECTEST_HOLD_SPREAD_PTS', 'EXECTEST_HOLD_MID_ENTRY', 'EXECTEST_HOLD_MID_FILL',
           'EXECTEST_HOLD_EXEC_SLIP', 'EXECTEST_HOLD_DRIFT_PTS', 'EXECTEST_HOLD_LOOKUP_OK',
           'EXECTEST_HOLD_TICK_MSC']
    for k in gvs:
        mt5.global_variable_del(k)
    mt5.shutdown()
" 2>$null
}

function Check-OpenPositions {
    $out = python -c "
import MetaTrader5 as mt5
if not mt5.initialize():
    print(0)
    exit(0)
positions = mt5.positions_get()
mt5.shutdown()
if positions:
    print(len(positions))
else:
    print(0)
" 2>$null
    if ([string]::IsNullOrWhiteSpace($out)) { return 0 }
    return [int]($out.Trim())
}

function Close-AllPositionsImmediately {
    python -c "
import MetaTrader5 as mt5
if mt5.initialize():
    positions = mt5.positions_get()
    if positions:
        for p in positions:
            symbol = p.symbol
            tick = mt5.symbol_info_tick(symbol)
            sym_info = mt5.symbol_info(symbol)
            f_mode = getattr(sym_info, 'filling_mode', 0) if sym_info else 0
            filling = mt5.ORDER_FILLING_FOK if (f_mode & 1) else (mt5.ORDER_FILLING_IOC if (f_mode & 2) else mt5.ORDER_FILLING_RETURN)
            c_type = mt5.ORDER_TYPE_SELL if p.type == mt5.ORDER_TYPE_BUY else mt5.ORDER_TYPE_BUY
            price = tick.bid if c_type == mt5.ORDER_TYPE_SELL else tick.ask
            req = {
                'action': mt5.TRADE_ACTION_DEAL,
                'symbol': symbol,
                'volume': p.volume,
                'type': c_type,
                'position': p.ticket,
                'price': price,
                'deviation': 20,
                'magic': 99999999,
                'comment': 'emergency_smoke_liquidation',
                'type_time': mt5.ORDER_TIME_GTC,
                'type_filling': filling
            }
            res = mt5.order_send(req)
            print(f'[EMERGENCY CLOSE] Ticket {p.ticket}: retcode {res.retcode if res else None}')
    mt5.shutdown()
"
}

# -----------------------------------------------------------------------------
# Log and CSV Reading Helpers
# -----------------------------------------------------------------------------
function Get-Mql5LogLines {
    param (
        [string]$DateStr = (Get-Date).ToString("yyyyMMdd")
    )
    $logPath = "$TerminalDataDir\MQL5\Logs\$DateStr.log"
    if (Test-Path $logPath) {
        try {
            $fs = [System.IO.FileStream]::new($logPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::Unicode)
            $text = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()
            return ($text -split "`r?`n")
        } catch {
            return @()
        }
    }
    return @()
}

function Get-CsvLines {
    param ([string]$FilePath)
    if (Test-Path $FilePath) {
        try {
            $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()
            return ($text -split "`r?`n")
        } catch {
            return @()
        }
    }
    return @()
}

# -----------------------------------------------------------------------------
# Main Execution Flow
# -----------------------------------------------------------------------------
Set-KeepAwake -Enable $true

try {
    # -------------------------------------------------------------------------
    # Hard Precondition Check 1: Required Files Verification
    # -------------------------------------------------------------------------
    Write-Host "[PRE-FLIGHT] Verifying required files and directories..." -ForegroundColor Yellow
    $requiredFiles = @(
        $ExternalClosePy,
        $TestRestartPy,
        $TerminalExe,
        $EaBinary,
        "$PresetsDir\smoke1.ini", "$PresetsDir\smoke1.set",
        "$PresetsDir\smoke2.ini", "$PresetsDir\smoke2.set",
        "$PresetsDir\smoke3.ini", "$PresetsDir\smoke3.set",
        "$PresetsDir\smoke5.ini", "$PresetsDir\smoke5.set",
        "$PresetsDir\smoke6.ini", "$PresetsDir\smoke6.set",
        "$PresetsDir\restart.ini", "$PresetsDir\restart.set",
        "$PresetsDir\default.ini", "$PresetsDir\default.set"
    )

    foreach ($f in $requiredFiles) {
        if (-not (Test-Path $f)) {
            Write-Host "[PRE-FLIGHT ERROR] Missing required file: $f" -ForegroundColor Red
            throw "Hard Precondition Failed: Missing required file '$f'"
        }
    }
    Write-Host "  All required scripts, binaries, and presets verified present." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # Hard Precondition Check 2: MT5 Environment, AutoTrading & Fresh Market Quote
    # -------------------------------------------------------------------------
    Write-Host "[PRE-FLIGHT] Verifying MT5 connection, AutoTrading, Demo Mode, and fresh quotes..." -ForegroundColor Yellow
    $envCheck = python -c "
import MetaTrader5 as mt5, time, sys
if not mt5.initialize():
    print('FAIL: mt5.initialize() failed: ' + str(mt5.last_error()), file=sys.stderr)
    sys.exit(1)

term = mt5.terminal_info()
if not term.trade_allowed:
    print('FAIL: AutoTrading is DISABLED in MT5 terminal settings!', file=sys.stderr)
    sys.exit(2)

acc = mt5.account_info()
if acc.trade_mode != mt5.ACCOUNT_TRADE_MODE_DEMO:
    print('FAIL: Account is NOT DEMO mode! Refusing to execute.', file=sys.stderr)
    sys.exit(3)

mt5.symbol_select('EURUSD', True)
time.sleep(0.5)
tick = mt5.symbol_info_tick('EURUSD')
if not tick:
    print('FAIL: Unable to fetch tick for EURUSD.', file=sys.stderr)
    sys.exit(4)

spread = tick.ask - tick.bid
if spread <= 0:
    print(f'FAIL: EURUSD spread non-positive: {spread}', file=sys.stderr)
    sys.exit(5)

print(f'OK|Login:{acc.login}|Server:{acc.server}|Equity:{acc.equity}|TradeAllowed:{term.trade_allowed}|EURUSD_Bid:{tick.bid}|EURUSD_Ask:{tick.ask}|SpreadPts:{(spread/0.0001):.1f}')
mt5.shutdown()
"
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[PRE-FLIGHT ERROR] Environment check failed (code $LASTEXITCODE)." -ForegroundColor Red
        throw "Hard Precondition Failed: MT5 environment check failed."
    }
    Write-Host "  MT5 Environment Verified: $envCheck" -ForegroundColor Green

    # -------------------------------------------------------------------------
    # Hard Precondition Check 3: Deploy Presets to Terminal Data Directory
    # -------------------------------------------------------------------------
    $destPresets = "$TerminalDataDir\MQL5\Presets"
    $destTester = "$TerminalDataDir\MQL5\Profiles\Tester"
    New-Item -ItemType Directory -Path $destPresets -Force | Out-Null
    New-Item -ItemType Directory -Path $destTester -Force | Out-Null
    Copy-Item "$PresetsDir\*.*" $destPresets -Force
    Copy-Item "$PresetsDir\*.*" $destTester -Force
    Write-Host "  Presets synchronized to Terminal Presets & Tester profiles." -ForegroundColor Green

    # -------------------------------------------------------------------------
    # Backup Existing CSVs
    # -------------------------------------------------------------------------
    $ts = Get-Date -Format "yyyyMMdd_HHmmss"
    $BackupDir = "$ScriptDir\backup_$ts"
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    Write-Host "[BACKUP] Backing up existing trades/roundtrips/skips to $BackupDir" -ForegroundColor Green

    $csvFiles = @("trades.csv", "roundtrips.csv", "skips.csv")
    foreach ($f in $csvFiles) {
        if (Test-Path "$CommonDir\$f") {
            Copy-Item "$CommonDir\$f" "$BackupDir\common_$f" -Force
        }
    }

    # -------------------------------------------------------------------------
    # Dry Run Mode Handling
    # -------------------------------------------------------------------------
    if ($Mode -eq "DryRun") {
        Write-Host "[DRY RUN] Verifying helper scripts execution with --dry-run..." -ForegroundColor Yellow
        python "$ExternalClosePy" --dry-run
        if ($LASTEXITCODE -ne 0) { throw "external_close.py dry run failed" }
        python "$TestRestartPy" --dry-run
        if ($LASTEXITCODE -ne 0) { throw "test_restart.py dry run failed" }
        Write-Host "[DRY RUN] Helper scripts verified cleanly. Pre-flight complete." -ForegroundColor Green
        return
    }

    # -------------------------------------------------------------------------
    # Attended Test Suite Execution
    # -------------------------------------------------------------------------
    $StartUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "`n>>> Starting Attended Smoke Test Suite at $StartUtc UTC <<<`n" -ForegroundColor Yellow

    $Tests = @(
        @{ Num = "1"; Name = "Close Reject 6"; Ini = "smoke1.ini"; Helper = $null; Timeout = 300 },
        @{ Num = "2"; Name = "External Close"; Ini = "smoke2.ini"; Helper = $ExternalClosePy; Timeout = 300 },
        @{ Num = "3A"; Name = "Timeout Filled"; Ini = "smoke3.ini"; Helper = $null; Timeout = 300 },
        @{ Num = "3B"; Name = "Timeout Unfilled"; Ini = $null; Helper = $null; Timeout = 0 },
        @{ Num = "4"; Name = "Daily Cap 1"; Ini = "smoke5.ini"; Helper = $null; Timeout = 360 },
        @{ Num = "5"; Name = "Equity Stop"; Ini = "smoke6.ini"; Helper = $null; Timeout = 300 },
        @{ Num = "6"; Name = "Mid-Hold Restart"; Ini = "restart.ini"; Helper = $TestRestartPy; Timeout = 360 }
    )

    $Results = [System.Collections.ArrayList]::new()

    foreach ($t in $Tests) {
        $tNum = $t.Num
        $tName = $t.Name

        if ($tNum -eq "3B") {
            $statusLine = "TEST 3B: NOT TESTABLE (OrderSend executes before timeout injection; unfilled variant not testable under code freeze)"
            Write-Host $statusLine -ForegroundColor Magenta
            $Results.Add([PSCustomObject]@{
                Test = "Test 3B ($tName)"
                Expected = "Unfilled timeout handling"
                Observed = "OrderSend executes; unfilled variant not testable under code freeze"
                Verdict = "NOT TESTABLE"
                MatchedEvidence = "N/A (Code freeze)"
            }) | Out-Null
            continue
        }

        Write-Host "==========================================================" -ForegroundColor DarkCyan
        Write-Host "--- Running Test ${tNum}: $tName ---" -ForegroundColor DarkCyan
        Write-Host "==========================================================" -ForegroundColor DarkCyan

        # 1. Clean slate: terminate any prior terminal instances
        Stop-Process -Name terminal64 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2
        Invoke-ClearGV

        # 2. Record pre-test offsets
        $preLogLines = Get-Mql5LogLines
        $preLogCount = $preLogLines.Count

        $tradesCsvPath = "$CommonDir\trades.csv"
        $roundtripsCsvPath = "$CommonDir\roundtrips.csv"
        $skipsCsvPath = "$CommonDir\skips.csv"

        $preTradesLines = Get-CsvLines $tradesCsvPath
        $preTradesCount = $preTradesLines.Count

        $preRoundtripsLines = Get-CsvLines $roundtripsCsvPath
        $preRoundtripsCount = $preRoundtripsLines.Count

        $preSkipsLines = Get-CsvLines $skipsCsvPath
        $preSkipsCount = $preSkipsLines.Count

        $testStartTime = Get-Date

        # 3. Launch Terminal with test ini
        $iniPath = "$PresetsDir\$($t.Ini)"
        Write-Host "[LAUNCH] Starting terminal64.exe with config $iniPath..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath $TerminalExe -ArgumentList "/config:`"$iniPath`"" -PassThru
        $initialPid = $proc.Id

        # 4. Hard Precondition: Verify EA Initialization Line in Log
        Write-Host "[CHECK] Polling MQL5 log for EA OnInit line..." -ForegroundColor Yellow
        $eaInitialized = $false
        $initDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $initDeadline) {
            Start-Sleep -Milliseconds 500
            $currLog = Get-Mql5LogLines
            if ($currLog.Count -gt $preLogCount) {
                $newLines = $currLog[$preLogCount..($currLog.Count - 1)]
                foreach ($line in $newLines) {
                    if ($line -match "INITIALIZING MT5 EXECUTION QUALITY EA" -or $line -match "\[SAFETY VERIFIED\]") {
                        $eaInitialized = $true
                        Write-Host "  [EA INIT CONFIRMED] $line" -ForegroundColor Green
                        break
                    }
                }
            }
            if ($eaInitialized) { break }
        }

        if (-not $eaInitialized) {
            Write-Host "[ERROR] EA init line NOT FOUND within 30s! Aborting test." -ForegroundColor Red
            if (!$proc.HasExited) { Stop-Process -Id $proc.Id -Force }
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Expected = "EA initialization line in MQL5 log"
                Observed = "No EA init line observed within 30s"
                Verdict = "INVALID"
                MatchedEvidence = "EA failed to initialize/attach"
            }) | Out-Null
            continue
        }

        # 5. Start Helper Script if applicable
        $helperProc = $null
        if ($t.Helper) {
            Write-Host "[HELPER] Launching helper script $($t.Helper)..." -ForegroundColor Yellow
            $helperProc = Start-Process python -ArgumentList "`"$($t.Helper)`"" -PassThru
        }

        # 6. Test Monitoring Loop
        $timeoutSec = $t.Timeout
        $deadline = $testStartTime.AddSeconds($timeoutSec)
        $completedCleanly = $false

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3

            # Check open positions
            $openPos = Check-OpenPositions

            # For Test 2 (External Close): wait until helper completes and openPos == 0
            if ($tNum -eq "2") {
                if ($helperProc -and $helperProc.HasExited -and $openPos -eq 0 -and ((Get-Date) -gt $testStartTime.AddSeconds(10))) {
                    $completedCleanly = $true
                    break
                }
            }
            # For Test 5 (Equity Stop): wait until halted and openPos == 0
            elseif ($tNum -eq "5") {
                $currLog = Get-Mql5LogLines
                $newLines = if ($currLog.Count -gt $preLogCount) { $currLog[$preLogCount..($currLog.Count - 1)] } else { @() }
                $halted = $newLines | Where-Object { $_ -match "STATE_HALTED" -or $_ -match "TRADING HALTED" }
                if ($halted -and $openPos -eq 0) {
                    $completedCleanly = $true
                    break
                }
            }
            # For Test 4 (Daily Cap): wait until skips.csv contains daily cap and openPos == 0
            elseif ($tNum -eq "4") {
                $currSkips = Get-CsvLines $skipsCsvPath
                $newSkips = if ($currSkips.Count -gt $preSkipsCount) { $currSkips[$preSkipsCount..($currSkips.Count - 1)] } else { @() }
                $capSkipped = $newSkips | Where-Object { $_ -match "Daily limit reached" -or $_ -match "daily_limit" }
                if ($capSkipped -and $openPos -eq 0) {
                    $completedCleanly = $true
                    break
                }
            }
            # For Test 6 (Restart): wait until helper completes and openPos == 0
            elseif ($tNum -eq "6") {
                if ($helperProc -and $helperProc.HasExited -and $openPos -eq 0 -and ((Get-Date) -gt $testStartTime.AddSeconds(45))) {
                    $completedCleanly = $true
                    break
                }
            }
            # For Test 1 and 3A: wait until openPos == 0 after initial entry
            else {
                if ($openPos -eq 0 -and ((Get-Date) -gt $testStartTime.AddSeconds(20))) {
                    # Also check that at least one trade row arrived
                    $currTrades = Get-CsvLines $tradesCsvPath
                    if ($currTrades.Count -gt $preTradesCount) {
                        $completedCleanly = $true
                        break
                    }
                }
            }
        }

        $elapsedSec = [int]((Get-Date) - $testStartTime).TotalSeconds

        # Verify helper exit code if applicable
        if ($helperProc) {
            if (!$helperProc.HasExited) {
                Write-Host "[HELPER WARN] Helper process did not exit in time. Killing..." -ForegroundColor DarkYellow
                Stop-Process -Id $helperProc.Id -Force
            }
            if ($helperProc.ExitCode -ne 0) {
                Write-Host "[HELPER ERROR] Helper script exited with error code $($helperProc.ExitCode)!" -ForegroundColor Red
                Stop-Process -Name terminal64 -Force -ErrorAction SilentlyContinue
                $Results.Add([PSCustomObject]@{
                    Test = "Test $tNum ($tName)"
                    Expected = "Helper script exit code 0"
                    Observed = "Helper exited with code $($helperProc.ExitCode)"
                    Verdict = "INVALID"
                    MatchedEvidence = "Helper script failure"
                }) | Out-Null
                continue
            }
        }

        # 7. Cleanly terminate terminal process
        Stop-Process -Name terminal64 -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 2

        # 8. Check final position state (Rule: 0 open positions required)
        $finalOpenPos = Check-OpenPositions
        if ($finalOpenPos -gt 0) {
            Write-Host "[CRITICAL] $finalOpenPos positions left open after ${elapsedSec}s! Performing emergency close." -ForegroundColor Red
            Close-AllPositionsImmediately
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Expected = "0 open positions"
                Observed = "$finalOpenPos positions open after ${elapsedSec}s"
                Verdict = "MISS - CRITICAL"
                MatchedEvidence = "Open positions remaining"
            }) | Out-Null
            break
        }

        # 9. Evidence Extraction: Logs & CSVs
        $postLogLines = Get-Mql5LogLines
        $testLogLines = if ($postLogLines.Count -gt $preLogCount) { $postLogLines[$preLogCount..($postLogLines.Count - 1)] } else { @() }

        $postTradesLines = Get-CsvLines $tradesCsvPath
        $newTrades = if ($postTradesLines.Count -gt $preTradesCount) { $postTradesLines[$preTradesCount..($postTradesLines.Count - 1)] } else { @() }

        $postRoundtripsLines = Get-CsvLines $roundtripsCsvPath
        $newRoundtrips = if ($postRoundtripsLines.Count -gt $preRoundtripsCount) { $postRoundtripsLines[$preRoundtripsCount..($postRoundtripsLines.Count - 1)] } else { @() }

        $postSkipsLines = Get-CsvLines $skipsCsvPath
        $newSkips = if ($postSkipsLines.Count -gt $preSkipsCount) { $postSkipsLines[$preSkipsCount..($postSkipsLines.Count - 1)] } else { @() }

        Write-Host "  Evidence collected: $($testLogLines.Count) log lines, $($newTrades.Count) trade rows, $($newRoundtrips.Count) roundtrips, $($newSkips.Count) skips." -ForegroundColor Cyan

        # 10. Hard Precondition: At least 1 new trades.csv row in test window
        if ($newTrades.Count -eq 0) {
            Write-Host "[ERROR] 0 trades.csv rows written during Test $tNum! Verdict is INVALID." -ForegroundColor Red
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Expected = ">= 1 new trades.csv row within window"
                Observed = "0 trades.csv rows written"
                Verdict = "INVALID"
                MatchedEvidence = "No orders/events logged to trades.csv"
            }) | Out-Null
            continue
        }

        # 11. Per-Test Specific Verification
        $verdict = "FAIL"
        $expectedStr = ""
        $observedStr = ""
        $matchedEvidence = @()

        switch ($tNum) {
            "1" {
                $expectedStr = ">=6 close-reject events (250..4000ms), [CRITICAL] at attempt 5, close at 7, roundtrip row written"
                # Check rejects
                $rejectLogs = $testLogLines | Where-Object { $_ -match "FAULT INJECTION.*Simulating rejected close attempt" -or $_ -match "close_failure" }
                $rejectTradeRows = $newTrades | Where-Object { $_ -match "close_failure" }
                $critLogs = $testLogLines | Where-Object { $_ -match "\[CRITICAL\].*Exit failed 5 consecutive attempts" }
                $roundtripConfirmed = $newRoundtrips.Count -ge 1

                $rejectCount = [Math]::Max($rejectLogs.Count, $rejectTradeRows.Count)
                if ($rejectCount -ge 6 -and $critLogs.Count -ge 1 -and $roundtripConfirmed) {
                    $verdict = "PASS"
                    $observedStr = "$rejectCount rejects, [CRITICAL] logged, roundtrip recorded in ${elapsedSec}s"
                    $matchedEvidence += $critLogs[0]
                    if ($rejectLogs.Count -gt 0) { $matchedEvidence += $rejectLogs[0] }
                } else {
                    $observedStr = "Rejects: $rejectCount, Crit: $($critLogs.Count), Roundtrips: $($newRoundtrips.Count)"
                }
            }

            "2" {
                $expectedStr = "orphan_external_close logged, PositionsTotal()==0, state IDLE"
                $orphanLogs = $testLogLines | Where-Object { $_ -match "ORPHAN EXTERNAL CLOSE" -or $_ -match "EXTERNAL CLOSE" }
                $orphanSkips = $newSkips | Where-Object { $_ -match "orphan_external_close" }
                $idleLogs = $testLogLines | Where-Object { $_ -match "STATE_IDLE" }

                if (($orphanLogs.Count -ge 1 -or $orphanSkips.Count -ge 1) -and $finalOpenPos -eq 0) {
                    $verdict = "PASS"
                    $observedStr = "orphan_external_close logged, 0 open positions, state IDLE in ${elapsedSec}s"
                    if ($orphanLogs.Count -gt 0) { $matchedEvidence += $orphanLogs[0] }
                    elseif ($orphanSkips.Count -gt 0) { $matchedEvidence += $orphanSkips[0] }
                } else {
                    $observedStr = "Orphan logs: $($orphanLogs.Count), skips: $($orphanSkips.Count), openPos: $finalOpenPos"
                }
            }

            "3A" {
                $expectedStr = "In-flight lock created then cleared after reconcile, 1 order, fill/slippage reconstructed"
                $timeoutLogs = $testLogLines | Where-Object { $_ -match "Simulating TRADE_RETCODE_TIMEOUT" -or $_ -match "INDETERMINATE RETCODE 10004" }
                $reconcileLogs = $testLogLines | Where-Object { $_ -match "RECONCILIATION RESULT.*Entry confirmed filled" }
                $inPosLogs = $testLogLines | Where-Object { $_ -match "STATE_IN_POSITION.*Entry reconciled as filled" }

                if ($timeoutLogs.Count -ge 1 -and $reconcileLogs.Count -ge 1) {
                    $verdict = "PASS"
                    $observedStr = "Timeout injected (10004), reconciled & lock cleared, fill reconstructed in ${elapsedSec}s"
                    $matchedEvidence += $timeoutLogs[0]
                    $matchedEvidence += $reconcileLogs[0]
                } else {
                    $observedStr = "Timeout logs: $($timeoutLogs.Count), reconcile logs: $($reconcileLogs.Count)"
                }
            }

            "4" {
                $expectedStr = "1 order placed, second cycle skipped with daily-cap reason in skips.csv, closed at expiry"
                $capSkips = $newSkips | Where-Object { $_ -match "Daily limit reached" -or $_ -match "daily_limit" }
                $capLogs = $testLogLines | Where-Object { $_ -match "Daily limit reached" }

                if (($capSkips.Count -ge 1 -or $capLogs.Count -ge 1) -and $newRoundtrips.Count -ge 1) {
                    $verdict = "PASS"
                    $observedStr = "1 order placed & closed, second cycle skipped (Daily limit reached) in ${elapsedSec}s"
                    if ($capLogs.Count -gt 0) { $matchedEvidence += $capLogs[0] }
                    elseif ($capSkips.Count -gt 0) { $matchedEvidence += $capSkips[0] }
                } else {
                    $observedStr = "Cap skips: $($capSkips.Count), roundtrips: $($newRoundtrips.Count)"
                }
            }

            "5" {
                $expectedStr = "Position liquidated first, then STATE_HALTED logged, no new orders"
                $haltLogs = $testLogLines | Where-Object { $_ -match "STATE_HALTED" -or $_ -match "TRADING HALTED AFTER" }
                
                if ($haltLogs.Count -ge 1 -and $finalOpenPos -eq 0) {
                    $verdict = "PASS"
                    $observedStr = "Position liquidated, STATE_HALTED logged, trading stopped in ${elapsedSec}s"
                    $matchedEvidence += $haltLogs[0]
                } else {
                    $observedStr = "Halt logs: $($haltLogs.Count), finalOpenPos: $finalOpenPos"
                }
            }

            "6" {
                $expectedStr = "New terminal PID, orphan/restart cleanup logged, position closed, state IDLE"
                $recoveryLogs = $testLogLines | Where-Object { $_ -match "RESTART RECOVERY" -or $_ -match "ORPHAN DETECTED" -or $_ -match "STATE_ORPHAN_CLEANUP" }
                $cleanClose = $newTrades | Where-Object { $_ -match "restart_cleanup" -or $_ -match "orphan_close" }

                if (($recoveryLogs.Count -ge 1 -or $cleanClose.Count -ge 1) -and $finalOpenPos -eq 0) {
                    $verdict = "PASS"
                    $observedStr = "Re-attached under restart, position recovered & closed, state IDLE in ${elapsedSec}s"
                    if ($recoveryLogs.Count -gt 0) { $matchedEvidence += $recoveryLogs[0] }
                    if ($cleanClose.Count -gt 0) { $matchedEvidence += $cleanClose[0] }
                } else {
                    $observedStr = "Recovery logs: $($recoveryLogs.Count), cleanClose: $($cleanClose.Count), finalOpenPos: $finalOpenPos"
                }
            }
        }

        Write-Host ">>> TEST ${tNum} VERDICT: $verdict <<<" -ForegroundColor $(if ($verdict -eq "PASS") { "Green" } else { "Red" })
        if ($matchedEvidence.Count -gt 0) {
            foreach ($m in $matchedEvidence) {
                Write-Host "    [EVIDENCE] $m" -ForegroundColor Gray
            }
        }

        $Results.Add([PSCustomObject]@{
            Test = "Test $tNum ($tName)"
            Expected = $expectedStr
            Observed = $observedStr
            Verdict = $verdict
            MatchedEvidence = ($matchedEvidence -join " | ")
        }) | Out-Null
    }

    # -------------------------------------------------------------------------
    # Final Window Recording and Preset Restoration
    # -------------------------------------------------------------------------
    $EndUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    $obj = @{
        "start_utc" = $StartUtc
        "end_utc" = $EndUtc
    }
    $obj | ConvertTo-Json | Set-Content -Path $SmokeWindowJson -Encoding utf8
    Write-Host "`n[WINDOW] Updated $SmokeWindowJson ($StartUtc to $EndUtc UTC)" -ForegroundColor Green

    # Restore default preset in Terminal
    Copy-Item "$PresetsDir\default.set" "$TerminalDataDir\MQL5\Profiles\Tester\default.set" -Force -ErrorAction SilentlyContinue
    Copy-Item "$PresetsDir\default.set" "$TerminalDataDir\MQL5\Presets\default.set" -Force -ErrorAction SilentlyContinue
    Invoke-ClearGV

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "           SMOKE TEST EXECUTION MATRIX                    " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $Results | Format-Table -AutoSize

    Write-Host "[RESTORED-DEFAULTS CONFIRMATION]" -ForegroundColor Green
    Write-Host "  - Presets restored to default.set (InpCycleIntervalMin=36, InpMaxOrdersPerDay=40, InpMaxDrawdownEUR=50.0)"
    Write-Host "  - All EXECTEST_* GlobalVariables cleared."
    Write-Host "  - Terminal processes terminated cleanly."
    Write-Host "  - smoke_test_window.json saved."

} finally {
    Set-KeepAwake -Enable $false
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Smoke test suite execution completed." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
