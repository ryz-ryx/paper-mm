<#
.SYNOPSIS
    Automated Smoke Test Runner for ExecTest.mq5
.DESCRIPTION
    Executes the agreed smoke test suite with rigorous per-test log & CSV verification:
    - Attended Mode: Runs on command immediately.
    - Scheduled Mode: Configures a Windows Scheduled Task.
    - DryRun Mode: Validates helper scripts and preconditions without executing trades.

    Every verdict is a list of checks that cross-reference three independent sources:
      * Experts log  (MQL5\Logs\yyyymmdd.log)  - EA tags: [ORDER SENT], [FAULT INJECTION], [EXIT RETRY],
                                                [CRITICAL], [RESTART RECOVERY], [STATE RESET], [HOLD EXPIRED]
      * Terminal journal (logs\yyyymmdd.log)  - broker-side "market buy"/"market sell" requests
      * Common\Files CSVs                     - trades.csv / roundtrips.csv / skips.csv rows
    A test PASSes only when every check passes.

    Tests executed:
    1. Close reject injection (InpInjectCloseReject=6)
    2. External close mid-hold (external_close.py)
    3A. Injected timeout filled (InpInjectTimeout=true)
    3B. Injected timeout unfilled -> NOT TESTABLE under code freeze
    4. Daily order cap 1 (InpMaxOrdersPerDay=1)
    5. Equity stop (InpMaxDrawdownEUR=0.001)
    6. Mid-hold crash restart (test_restart.py, taskkill /f)

    State hygiene: smoke1/2/3/5/6 set InpResetState=true, so the EA wipes EXECTEST_* globals at init and logs
    "[STATE RESET] Cleared ...". restart.set (T6, both instances) sets InpResetState=false: the relaunch must
    recover from the persisted state, so T6 asserts that no reset line appears at all. The old Python ClearGV
    call was a no-op: the MetaTrader5 package has no global-variable API, and its error was hidden by 2>$null.

    -Mode SelfTest runs the offline checks for the harness bugs fixed in v2.10 (no MT5 contact, no orders).
#>

param (
    [ValidateSet("Attended", "ScheduleTask", "DryRun", "SelfTest")]
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
$EaSource = "$ScriptDir\ExecTest.mq5"
$GvFile = "$TerminalDataDir\bases\gvariables.dat"

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
# Helper: Terminal process control
# mt5.initialize() launches terminal64.exe when none is running (with no /config, i.e. from the last saved
# profile). Every Python helper below is therefore only called while a terminal is already running.
# -----------------------------------------------------------------------------
function Test-TerminalRunning {
    return [bool](Get-Process terminal64 -ErrorAction SilentlyContinue)
}

function Stop-Terminal {
    # Graceful first (WM_CLOSE): the terminal writes gvariables.dat, the profile and the buffered Experts log
    # on a normal exit. A forced kill loses all three. Force only after the grace period.
    param ([int]$GraceSec = 20)
    $procs = @(Get-Process terminal64 -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) { return "not-running" }
    foreach ($p in $procs) {
        try { $p.CloseMainWindow() | Out-Null } catch {}
    }
    $deadline = (Get-Date).AddSeconds($GraceSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-TerminalRunning)) { return "graceful" }
        Start-Sleep -Milliseconds 500
    }
    Stop-Process -Name terminal64 -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    return "forced"
}

function Check-OpenPositions {
    # Returns -1 when no terminal is running (unknown), never launches one.
    if (-not (Test-TerminalRunning)) { return -1 }
    $out = python -c "
import MetaTrader5 as mt5
if not mt5.initialize():
    print(-1)
    exit(0)
positions = mt5.positions_get()
mt5.shutdown()
print(len(positions) if positions else 0)
" 2>$null
    if ([string]::IsNullOrWhiteSpace($out)) { return -1 }
    return [int]($out.Trim())
}

function Close-AllPositionsImmediately {
    if (-not (Test-TerminalRunning)) {
        Write-Host "[EMERGENCY CLOSE] No terminal running; cannot close positions from here." -ForegroundColor Red
        return
    }
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
function Get-Utf16LogLines {
    param ([string]$Path)
    if (Test-Path $Path) {
        try {
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::Unicode)
            $text = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()
            return @($text -split "`r?`n")
        } catch {
            return @()
        }
    }
    return @()
}

function Get-Mql5LogLines {
    param ([string]$DateStr = (Get-Date).ToString("yyyyMMdd"))
    return Get-Utf16LogLines "$TerminalDataDir\MQL5\Logs\$DateStr.log"
}

function Get-JournalLines {
    param ([string]$DateStr = (Get-Date).ToString("yyyyMMdd"))
    return Get-Utf16LogLines "$TerminalDataDir\logs\$DateStr.log"
}

function Get-CsvLines {
    # Non-empty lines only. The previous version kept the trailing "" produced by the final CRLF, so slicing
    # post[preCount..] skipped the first new row of every test and counted an empty string as a row.
    param ([string]$FilePath)
    if (Test-Path $FilePath) {
        try {
            $fs = [System.IO.FileStream]::new($FilePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
            $text = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()
            return @($text -split "`r?`n" | Where-Object { $_.Trim() -ne "" })
        } catch {
            return @()
        }
    }
    return @()
}

function Get-NewCsvObjects {
    # Rows appended during the test window, as objects keyed by the current header. If the header changed
    # (ExecTest rotates a file whose schema differs) every data row of the new file is new.
    param ([string[]]$PreLines, [string[]]$PostLines)
    if ($PostLines.Count -le 1) { return @() }
    $start = $PreLines.Count
    if ($PreLines.Count -eq 0 -or $PreLines[0] -ne $PostLines[0]) { $start = 1 }
    if ($start -ge $PostLines.Count) { return @() }
    $rows = $PostLines[$start..($PostLines.Count - 1)]
    return @(@($PostLines[0]) + $rows | ConvertFrom-Csv)
}

function Get-NewLines {
    param ([string[]]$PreLines, [string[]]$PostLines)
    if ($PostLines.Count -gt $PreLines.Count) { return @($PostLines[$PreLines.Count..($PostLines.Count - 1)]) }
    return @()
}

function Get-SetValue {
    param ([string]$SetFile, [string]$Key, [string]$Default = "")
    if (-not (Test-Path $SetFile)) { return $Default }
    $line = Get-Content $SetFile | Where-Object { $_ -match "^$Key=" } | Select-Object -First 1
    if ($line) { return ($line -split "=", 2)[1].Trim() }
    return $Default
}

function Get-IniSetFile {
    param ([string]$IniFile)
    $line = Get-Content $IniFile | Where-Object { $_ -match "^ExpertParameters=" } | Select-Object -First 1
    if ($line) { return "$PresetsDir\$(($line -split '=', 2)[1].Trim())" }
    return $null
}

function Count-Matches {
    param ([string[]]$Lines, [string]$Pattern)
    return @($Lines | Where-Object { $_ -match $Pattern }).Count
}

function First-Index {
    param ([string[]]$Lines, [string]$Pattern, [int]$Start = 0)
    for ($i = [Math]::Max(0, $Start); $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $Pattern) { return $i }
    }
    return -1
}

function Count-MatchesAfter {
    param ([string[]]$Lines, [string]$Pattern, [int]$AfterIndex)
    if ($AfterIndex -lt 0) { return 0 }
    $n = 0
    for ($i = $AfterIndex + 1; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match $Pattern) { $n++ }
    }
    return $n
}

function Add-Check {
    param ($List, [string]$Name, $Expected, $Observed, [bool]$Pass)
    $List.Add([PSCustomObject]@{ Check = $Name; Expected = "$Expected"; Observed = "$Observed"; Pass = $Pass }) | Out-Null
}

function Parse-CsvTs {
    param ([string]$Ts)
    try { return [datetime]::ParseExact($Ts, "yyyy-MM-dd HH:mm:ss.fff", [System.Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
}

# Tag patterns (single source of truth for every check)
$P_BUY_SENT    = '\[ORDER SENT\] \S+ BUY '
$P_SELL_SENT   = '\[ORDER SENT\] \S+ SELL '
$P_J_BUY       = "': market buy "
$P_J_SELL      = "': market sell "
$P_INJ_REJECT  = '\[FAULT INJECTION\] Simulated rejected close attempt'
$P_INJ_TIMEOUT = '\[FAULT INJECTION\] Simulating TRADE_RETCODE_TIMEOUT'
$P_EXIT_RETRY  = '\[EXIT RETRY\]'
$P_CRITICAL    = '\[CRITICAL\]'
$P_RESTART     = '\[RESTART RECOVERY\]'
$P_ORPHAN      = '\[ORPHAN DETECTED\]'
$P_RESET_OK    = '\[STATE RESET\] Cleared'
$P_RESET_SKIP  = '\[STATE RESET\] SKIPPED'
$P_INIT        = 'INITIALIZING MT5 EXECUTION QUALITY EA'
$P_DUP         = '\[INSTANCE LOCK\] Duplicate ExecTest instance refused'
$P_LOCK_OK     = '\[INSTANCE LOCK\] acquired'
$P_HOLD_EXP    = '\[HOLD EXPIRED\]'
$P_TO_IDLE     = '-> STATE_IDLE'
$P_HALT        = '-> STATE_HALTED|\[TRADING HALTED'
$P_EXT_CLOSE   = '\[EXTERNAL CLOSE DETECTED\]'
$P_STALL       = '\[TIMER STALL\]'

# -----------------------------------------------------------------------------
# T1 timing model, derived from ExecTest.mq5 OnTimer:
#   after failed attempt k the next attempt is due at  now + b(k),  b(k) = min(5000, 250 * 2^min(k-1, 5)) ms
#   k : 1    2    3     4     5     6     7+
#   b : 250  500  1000  2000  4000  5000  5000
# With N injected rejects (attempts 1..N rejected, attempt N+1 is the real close), the first close_failure row
# and the successful SELL row are separated by  sum(b(1..N)) + broker RTT + timing error.
# Error terms (per wait): GetTickCount64 ticks in ~15.6 ms steps, so a wait can end up to $TIMER_EARLY_MS early
# in real time, or up to $TIMER_LATE_MS late (detection quantum + 15 ms timer period on a 15.6 ms Windows
# clock). The difference of two CSV labels is off by at most $LABEL_DIFF_MS (each label trails real time by
# 0..1 poll interval). RTT of the single real close is budgeted at <= $RTT_MAX_MS.
# -----------------------------------------------------------------------------
$TIMER_EARLY_MS = 16
$TIMER_LATE_MS  = 32
$LABEL_DIFF_MS  = 16
$RTT_MAX_MS     = 500

function Get-BackoffMs {
    param ([int]$Attempt)
    return [Math]::Min(5000, 250 * [Math]::Pow(2, [Math]::Min($Attempt - 1, 5)))
}

function Get-RejectToCloseWindow {
    param ([int]$Rejects)
    $nominal = 0
    for ($k = 1; $k -le $Rejects; $k++) { $nominal += Get-BackoffMs $k }
    return [PSCustomObject]@{
        NominalMs = $nominal
        LowerS    = [Math]::Round(($nominal - $Rejects * $TIMER_EARLY_MS - $LABEL_DIFF_MS) / 1000.0, 3)
        UpperS    = [Math]::Round(($nominal + $Rejects * $TIMER_LATE_MS + $LABEL_DIFF_MS + $RTT_MAX_MS) / 1000.0, 3)
    }
}

function Test-BackoffGaps {
    # Gap k between consecutive close_failure labels must match b(k) within the per-wait error terms.
    param ([string[]]$FailureTimestamps)
    $bad = @()
    for ($k = 1; $k -lt $FailureTimestamps.Count; $k++) {
        $gapMs = ((Parse-CsvTs $FailureTimestamps[$k]) - (Parse-CsvTs $FailureTimestamps[$k - 1])).TotalMilliseconds
        $b = Get-BackoffMs $k
        if ($gapMs -lt ($b - $TIMER_EARLY_MS - $LABEL_DIFF_MS) -or $gapMs -gt ($b + $TIMER_LATE_MS + $LABEL_DIFF_MS)) {
            $bad += "gap $k = $gapMs ms (b=$b)"
        }
    }
    return $bad
}

function Test-RunComplete {
    # Completion predicate of the monitoring loop, per test. $OpenPos is -1 when no terminal is running.
    param ([string]$TestNum, [string[]]$LiveLines, [int]$OpenPos, [bool]$HelperExited, [double]$ElapsedSec)
    switch ($TestNum) {
        "2" { return ($HelperExited -and $OpenPos -eq 0 -and (Count-Matches $LiveLines $P_EXT_CLOSE) -ge 1) }
        "5" { return ((Count-Matches $LiveLines $P_HALT) -ge 1 -and $OpenPos -eq 0) }
        # The EA only logs the cap ([ENTRY GATED] Daily limit reached ...); it never writes a skips.csv row for
        # it, so the old wait on a 'daily_limit' skip row could never complete and T4 always ran to its timeout.
        "4" { return ((Count-Matches $LiveLines "Daily limit reached") -ge 1 -and $OpenPos -eq 0 -and (Count-Matches $LiveLines $P_SELL_SENT) -ge 1) }
        "6" { return ($HelperExited -and $OpenPos -eq 0 -and $ElapsedSec -gt 45) }
        default { return ($OpenPos -eq 0 -and $ElapsedSec -gt 20 -and (Count-Matches $LiveLines $P_SELL_SENT) -ge 1) }
    }
}

# -----------------------------------------------------------------------------
# Mode: SelfTest - offline checks, one per harness bug fixed in v2.10 (no MT5, no orders)
# -----------------------------------------------------------------------------
if ($Mode -eq "SelfTest") {
    $fails = 0
    function Assert-True { param ([string]$Name, [bool]$Cond, [string]$Detail)
        if ($Cond) { Write-Host "  PASS  $Name  ($Detail)" -ForegroundColor Green } else { Write-Host "  FAIL  $Name  ($Detail)" -ForegroundColor Red; $script:fails++ } }

    Write-Host "[SELFTEST 1] CSV off-by-one (trailing CRLF must not hide the first new row)" -ForegroundColor Yellow
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_selftest_" + [guid]::NewGuid().ToString("N") + ".csv")
    [System.IO.File]::WriteAllText($tmp, "timestamp_utc,side,comment`r`n2026-10-12 10:00:00.000,BUY,old`r`n")
    $pre = Get-CsvLines $tmp
    [System.IO.File]::AppendAllText($tmp, "2026-10-12 10:01:00.100,BUY,first_new`r`n2026-10-12 10:01:12.900,SELL,second_new`r`n")
    $post = Get-CsvLines $tmp
    $new = Get-NewCsvObjects $pre $post
    $rawPre = ([System.IO.File]::ReadAllText($tmp) -replace "2026-10-12 10:01:00.100,BUY,first_new`r`n2026-10-12 10:01:12.900,SELL,second_new`r`n", "") -split "`r?`n"
    $rawPost = [System.IO.File]::ReadAllText($tmp) -split "`r?`n"
    $oldSlice = $rawPost[$rawPre.Count..($rawPost.Count - 1)]
    Remove-Item $tmp -Force
    Assert-True "new rows found" ($new.Count -eq 2 -and $new[0].comment -eq "first_new" -and $new[1].comment -eq "second_new") "got $($new.Count): $(($new | ForEach-Object { $_.comment }) -join ',')"
    Assert-True "old slicing reproduced the bug" ($oldSlice.Count -eq 2 -and $oldSlice[0] -match "second_new" -and $oldSlice[1] -eq "") "old slice = [$($oldSlice -join ' | ')]"

    Write-Host "[SELFTEST 2] T4 completion waits on the EA log, not on a skips.csv row" -ForegroundColor Yellow
    $t4Log = @("[ORDER SENT] EURUSD BUY retcode=10009 order=1 deal=1 price=1.1 dispatch_us=800 rtt_us=40000",
               "[ORDER SENT] EURUSD SELL retcode=10009 order=2 deal=2 price=1.1 dispatch_us=900 rtt_us=41000",
               "[ENTRY GATED] Daily limit reached: 2/1 orders today")
    Assert-True "completes on log evidence" (Test-RunComplete "4" $t4Log 0 $false 70) "log cap + SELL sent + 0 positions"
    Assert-True "not complete while position open" (-not (Test-RunComplete "4" $t4Log 1 $false 70)) "open positions = 1"
    Assert-True "not complete when terminal down" (-not (Test-RunComplete "4" $t4Log -1 $false 70)) "open positions = -1"
    Assert-True "skips-row-only evidence does not complete" (-not (Test-RunComplete "4" @("daily_limit") 0 $false 70)) "no EA log line"

    Write-Host "[SELFTEST 3] T1 window derived from the backoff schedule" -ForegroundColor Yellow
    $sched = (1..6 | ForEach-Object { Get-BackoffMs $_ }) -join ","
    $w6 = Get-RejectToCloseWindow 6
    $w5 = Get-RejectToCloseWindow 5
    Assert-True "schedule k=1..6" ($sched -eq "250,500,1000,2000,4000,5000") $sched
    Assert-True "N=6 nominal 12750 ms" ($w6.NominalMs -eq 12750) "window $($w6.LowerS)-$($w6.UpperS) s"
    Assert-True "N=5 nominal 7750 ms (reference)" ($w5.NominalMs -eq 7750) "window $($w5.LowerS)-$($w5.UpperS) s"
    $okGaps = Test-BackoffGaps @("2026-10-12 10:00:00.000", "2026-10-12 10:00:00.262", "2026-10-12 10:00:00.770", "2026-10-12 10:00:01.785", "2026-10-12 10:00:03.800", "2026-10-12 10:00:07.815")
    $badGaps = Test-BackoffGaps @("2026-10-12 10:00:00.000", "2026-10-12 10:00:00.250", "2026-10-12 10:00:00.750", "2026-10-12 10:00:01.750", "2026-10-12 10:00:03.750", "2026-10-12 10:00:07.000")
    Assert-True "jittered schedule accepted" ($okGaps.Count -eq 0) "violations: $($okGaps -join '; ')"
    Assert-True "short 5th wait rejected" ($badGaps.Count -eq 1) "violations: $($badGaps -join '; ')"

    Write-Host "[SELFTEST 4] smoke_test_window.json BOM (written by PowerShell 5.1, read by report.py)" -ForegroundColor Yellow
    $py = python "$ScriptDir\report.py" --self-test 2>&1
    $py | ForEach-Object { Write-Host "    $_" }
    Assert-True "report.py --self-test" ($LASTEXITCODE -eq 0) "exit code $LASTEXITCODE"

    Write-Host "SELFTEST: $(if ($fails -eq 0) { 'ALL PASS' } else { "$fails FAILED" })" -ForegroundColor $(if ($fails -eq 0) { "Green" } else { "Red" })
    exit $fails
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

    # The deployed binary must be built from the current source (the harness asserts on tags that only
    # ExecTest 2.10+ emits: [ORDER SENT], [STATE RESET], [HOLD EXPIRED]).
    if ((Get-Item $EaBinary).LastWriteTime -lt (Get-Item $EaSource).LastWriteTime) {
        throw "Hard Precondition Failed: $EaBinary is older than $EaSource. Recompile and deploy the EA first."
    }
    foreach ($s in @("smoke1.set", "smoke2.set", "smoke3.set", "smoke5.set", "smoke6.set")) {
        if ((Get-SetValue "$PresetsDir\$s" "InpResetState" "false") -ne "true") {
            throw "Hard Precondition Failed: $s must set InpResetState=true"
        }
    }
    foreach ($s in @("restart.set", "default.set")) {
        if ((Get-SetValue "$PresetsDir\$s" "InpResetState" "false") -ne "false") {
            throw "Hard Precondition Failed: $s must set InpResetState=false"
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
spread = -1
tick = None
for _ in range(10):
    tick = mt5.symbol_info_tick('EURUSD')
    if tick:
        spread = tick.ask - tick.bid
        if spread >= 0:
            break
    time.sleep(0.5)

if not tick:
    print('FAIL: Unable to fetch tick for EURUSD.', file=sys.stderr)
    sys.exit(4)

if spread < 0:
    print(f'FAIL: EURUSD spread negative (crossed market): {spread}', file=sys.stderr)
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
                Verdict = "NOT TESTABLE"
                Summary = "OrderSend executes; unfilled variant not testable under code freeze"
                StaleTickBackoffs = "N/A"
                Checks = @()
            }) | Out-Null
            continue
        }

        Write-Host "==========================================================" -ForegroundColor DarkCyan
        Write-Host "--- Running Test ${tNum}: $tName ---" -ForegroundColor DarkCyan
        Write-Host "==========================================================" -ForegroundColor DarkCyan

        $iniPath = "$PresetsDir\$($t.Ini)"
        $setPath = Get-IniSetFile $iniPath
        $expectedRejects = [int](Get-SetValue $setPath "InpInjectCloseReject" "0")
        $expectedTimeout = ((Get-SetValue $setPath "InpInjectTimeout" "false") -eq "true")

        # 1. Clean slate: no open positions, then a graceful stop of any running terminal
        if (Test-TerminalRunning) {
            $prePos = Check-OpenPositions
            if ($prePos -gt 0) {
                Write-Host "[PRE-TEST] $prePos position(s) open before the test; emergency close." -ForegroundColor Red
                Close-AllPositionsImmediately
                Start-Sleep -Seconds 2
            }
        }
        $stopMode = Stop-Terminal
        Write-Host "  [PRE-TEST] Terminal stop: $stopMode" -ForegroundColor Gray

        # 2. Record pre-test offsets
        $preLogLines = Get-Mql5LogLines
        $preJournalLines = Get-JournalLines

        $tradesCsvPath = "$CommonDir\trades.csv"
        $roundtripsCsvPath = "$CommonDir\roundtrips.csv"
        $skipsCsvPath = "$CommonDir\skips.csv"

        $preTradesLines = Get-CsvLines $tradesCsvPath
        $preRoundtripsLines = Get-CsvLines $roundtripsCsvPath
        $preSkipsLines = Get-CsvLines $skipsCsvPath

        $testStartTime = Get-Date

        # 3. Launch Terminal with test ini
        Write-Host "[LAUNCH] Starting terminal64.exe with config $iniPath..." -ForegroundColor Yellow
        $proc = Start-Process -FilePath $TerminalExe -ArgumentList "/config:`"$iniPath`"" -PassThru

        # 4. Hard Precondition: Verify EA Initialization Line in Log
        Write-Host "[CHECK] Polling MQL5 log for EA OnInit line..." -ForegroundColor Yellow
        $eaInitialized = $false
        $initDeadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $initDeadline) {
            Start-Sleep -Milliseconds 500
            $newLines = Get-NewLines $preLogLines (Get-Mql5LogLines)
            $initLine = $newLines | Where-Object { $_ -match $P_INIT -or $_ -match "\[SAFETY VERIFIED\]" } | Select-Object -First 1
            if ($initLine) {
                $eaInitialized = $true
                Write-Host "  [EA INIT CONFIRMED] $initLine" -ForegroundColor Green
                break
            }
        }

        if (-not $eaInitialized) {
            Write-Host "[ERROR] EA init line NOT FOUND within 30s! Aborting test." -ForegroundColor Red
            Stop-Terminal | Out-Null
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Verdict = "INVALID"
                Summary = "No EA init line observed within 30s (EA failed to initialize/attach)"
                StaleTickBackoffs = "N/A"
                Checks = @()
            }) | Out-Null
            continue
        }

        # 5. Start Helper Script if applicable
        $helperProc = $null
        $gvSizeBeforeKill = -1
        $gvSizeAfterKill = -1
        if ($tNum -eq "6") {
            if (Test-Path $GvFile) { $gvSizeBeforeKill = (Get-Item $GvFile).Length } else { $gvSizeBeforeKill = 0 }
        }
        if ($t.Helper) {
            Write-Host "[HELPER] Launching helper script $($t.Helper)..." -ForegroundColor Yellow
            $helperProc = Start-Process python -ArgumentList "`"$($t.Helper)`"" -PassThru
        }

        # 6. Test Monitoring Loop (completion is detected from EA tags, not from lagging CSV flushes)
        $timeoutSec = $t.Timeout
        $deadline = $testStartTime.AddSeconds($timeoutSec)
        $completedCleanly = $false

        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 3

            $openPos = Check-OpenPositions
            $liveLines = Get-NewLines $preLogLines (Get-Mql5LogLines)
            $helperExited = [bool]($helperProc -and $helperProc.HasExited)
            $elapsedNow = ((Get-Date) - $testStartTime).TotalSeconds

            # Single predicate shared with -Mode SelfTest ($openPos is -1 while the terminal is down in T6)
            if (Test-RunComplete $tNum $liveLines $openPos $helperExited $elapsedNow) {
                $completedCleanly = $true; break
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
                if ((Check-OpenPositions) -gt 0) { Close-AllPositionsImmediately; Start-Sleep -Seconds 2 }
                Stop-Terminal | Out-Null
                $Results.Add([PSCustomObject]@{
                    Test = "Test $tNum ($tName)"
                    Verdict = "INVALID"
                    Summary = "Helper exited with code $($helperProc.ExitCode)"
                    StaleTickBackoffs = "N/A"
                    Checks = @()
                }) | Out-Null
                continue
            }
        }

        if ($tNum -eq "6") {
            if (Test-Path $GvFile) { $gvSizeAfterKill = (Get-Item $GvFile).Length } else { $gvSizeAfterKill = 0 }
        }

        # 7. Final position state, checked while the terminal still runs (Rule: 0 open positions required)
        Start-Sleep -Seconds 3   # let the EA flush its IDLE queues
        $finalOpenPos = Check-OpenPositions
        if ($finalOpenPos -gt 0) {
            Write-Host "[CRITICAL] $finalOpenPos positions left open after ${elapsedSec}s! Performing emergency close." -ForegroundColor Red
            Close-AllPositionsImmediately
            Start-Sleep -Seconds 2
            Stop-Terminal | Out-Null
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Verdict = "MISS - CRITICAL"
                Summary = "$finalOpenPos positions open after ${elapsedSec}s"
                StaleTickBackoffs = "N/A"
                Checks = @()
            }) | Out-Null
            break
        }

        # 8. Graceful terminal stop: OnDeinit flushes CSV queues and GVs, the terminal flushes its logs
        $stopMode = Stop-Terminal
        Write-Host "  [POST-TEST] Terminal stop: $stopMode" -ForegroundColor Gray

        # 9. Evidence Extraction: Experts log, terminal journal, CSVs
        $testLogLines = Get-NewLines $preLogLines (Get-Mql5LogLines)
        $testJournal = Get-NewLines $preJournalLines (Get-JournalLines)
        $postTradesLines = Get-CsvLines $tradesCsvPath
        $postRoundtripsLines = Get-CsvLines $roundtripsCsvPath
        $postSkipsLines = Get-CsvLines $skipsCsvPath

        $newTradesObjs = Get-NewCsvObjects $preTradesLines $postTradesLines
        $newRoundtripsObjs = Get-NewCsvObjects $preRoundtripsLines $postRoundtripsLines
        $newSkipsObjs = Get-NewCsvObjects $preSkipsLines $postSkipsLines

        Write-Host "  Evidence collected: $($testLogLines.Count) EA log lines, $($testJournal.Count) journal lines, $($newTradesObjs.Count) trade rows, $($newRoundtripsObjs.Count) roundtrips, $($newSkipsObjs.Count) skips." -ForegroundColor Cyan

        # Tag counts shared by all tests
        $eaBuy       = Count-Matches $testLogLines $P_BUY_SENT
        $eaSell      = Count-Matches $testLogLines $P_SELL_SENT
        $jBuy        = Count-Matches $testJournal $P_J_BUY
        $jSell       = Count-Matches $testJournal $P_J_SELL
        $injRejects  = Count-Matches $testLogLines $P_INJ_REJECT
        $injTimeouts = Count-Matches $testLogLines $P_INJ_TIMEOUT
        $exitRetry   = Count-Matches $testLogLines $P_EXIT_RETRY
        $critical    = Count-Matches $testLogLines $P_CRITICAL
        $restartRec  = Count-Matches $testLogLines $P_RESTART
        $orphanDet   = Count-Matches $testLogLines $P_ORPHAN
        $resetOk     = Count-Matches $testLogLines $P_RESET_OK
        $resetSkip   = Count-Matches $testLogLines $P_RESET_SKIP
        $dupRefused  = Count-Matches $testLogLines $P_DUP
        $holdExpired = Count-Matches $testLogLines $P_HOLD_EXP
        $stalls      = Count-Matches $testLogLines $P_STALL

        $buyRows        = @($newTradesObjs | Where-Object { $_.side -eq "BUY" })
        $sellRows       = @($newTradesObjs | Where-Object { $_.side -eq "SELL" -and $_.event_type -ne "close_failure" })
        $closeFailRows  = @($newTradesObjs | Where-Object { $_.event_type -eq "close_failure" })
        $injectedRows   = @($closeFailRows | Where-Object { $_.comment -eq "fault_injection" })

        $checks = [System.Collections.ArrayList]::new()

        # Common checks
        Add-Check $checks "No duplicate EA instance refused" 0 $dupRefused ($dupRefused -eq 0)
        Add-Check $checks "No OnTimer stall > 1 s" 0 $stalls ($stalls -eq 0)
        Add-Check $checks "Final open positions" 0 $finalOpenPos ($finalOpenPos -eq 0)
        if ($tNum -ne "6") {
            Add-Check $checks "[STATE RESET] Cleared at init" 1 $resetOk ($resetOk -eq 1)
            Add-Check $checks "Exactly one entry dispatch (EA [ORDER SENT] BUY)" 1 $eaBuy ($eaBuy -eq 1)
            Add-Check $checks "Exactly one entry dispatch (journal market buy)" 1 $jBuy ($jBuy -eq 1)
            Add-Check $checks "Injected close rejects == preset InpInjectCloseReject" $expectedRejects $injRejects ($injRejects -eq $expectedRejects)
            Add-Check $checks "Injected timeouts == preset InpInjectTimeout" ([int]$expectedTimeout) $injTimeouts ($injTimeouts -eq [int]$expectedTimeout)
        }

        switch ($tNum) {
            "1" {
                $expRetry = [Math]::Min($expectedRejects, 4)
                $expCrit = [Math]::Max(0, $expectedRejects - 4)
                Add-Check $checks "close_failure rows tagged fault_injection" $expectedRejects $injectedRows.Count ($injectedRows.Count -eq $expectedRejects)
                Add-Check $checks "[EXIT RETRY] lines (attempts 1-4)" $expRetry $exitRetry ($exitRetry -eq $expRetry)
                Add-Check $checks "[CRITICAL] lines (attempts >= 5)" $expCrit $critical ($critical -eq $expCrit)
                Add-Check $checks "Exactly one exit dispatch (EA [ORDER SENT] SELL)" 1 $eaSell ($eaSell -eq 1)
                Add-Check $checks "Exactly one exit dispatch (journal market sell)" 1 $jSell ($jSell -eq 1)
                Add-Check $checks "[HOLD EXPIRED] logged" 1 $holdExpired ($holdExpired -eq 1)
                Add-Check $checks "Zero [ORPHAN DETECTED]" 0 $orphanDet ($orphanDet -eq 0)
                $rtRestartFalse = ($newRoundtripsObjs.Count -eq 1) -and ($newRoundtripsObjs[0].restart -eq "False")
                Add-Check $checks "Exactly one roundtrip row with restart=False" "1, False" "$($newRoundtripsObjs.Count), $(if ($newRoundtripsObjs.Count -gt 0) { $newRoundtripsObjs[0].restart } else { '-' })" $rtRestartFalse

                # First-reject-to-success from the (now monotonic) CSV timestamp labels, bounded by the schedule
                $elapsedRejectToSuccess = -1.0
                if ($closeFailRows.Count -ge 1 -and $sellRows.Count -ge 1) {
                    $tFirst = Parse-CsvTs $closeFailRows[0].timestamp_utc
                    $tOk = Parse-CsvTs $sellRows[-1].timestamp_utc
                    if ($tFirst -and $tOk) { $elapsedRejectToSuccess = [Math]::Round(($tOk - $tFirst).TotalSeconds, 3) }
                }
                $win = Get-RejectToCloseWindow $expectedRejects
                Add-Check $checks "First reject -> successful close (s), nominal $($win.NominalMs) ms" "$($win.LowerS)-$($win.UpperS)" $elapsedRejectToSuccess ($elapsedRejectToSuccess -ge $win.LowerS -and $elapsedRejectToSuccess -le $win.UpperS)
                $gapViolations = Test-BackoffGaps @($closeFailRows | ForEach-Object { $_.timestamp_utc })
                Add-Check $checks "Reject-to-reject gaps match b(1..N-1)" "0 violations" ($(if ($gapViolations.Count) { $gapViolations -join "; " } else { "0 violations" })) ($gapViolations.Count -eq 0 -and $closeFailRows.Count -eq $expectedRejects)
            }

            "2" {
                $idxExt = First-Index $testLogLines $P_EXT_CLOSE
                $idxIdle = if ($idxExt -ge 0) { First-Index $testLogLines $P_TO_IDLE ($idxExt + 1) } else { -1 }
                $extSkips = @($newSkipsObjs | Where-Object { $_.reason -eq "orphan_external_close" })
                Add-Check $checks "[EXTERNAL CLOSE DETECTED] logged" ">=0 index" $idxExt ($idxExt -ge 0)
                Add-Check $checks "Strict transition to STATE_IDLE after the external close" "index > $idxExt" $idxIdle ($idxIdle -gt $idxExt -and $idxExt -ge 0)
                Add-Check $checks "orphan_external_close rows in skips.csv" 1 $extSkips.Count ($extSkips.Count -eq 1)
                Add-Check $checks "EA sent no close of its own ([ORDER SENT] SELL)" 0 $eaSell ($eaSell -eq 0)
                Add-Check $checks "External close visible in journal (market sell)" ">=1" $jSell ($jSell -ge 1)
            }

            "3A" {
                $reconcileFilled = Count-Matches $testLogLines "RECONCILIATION RESULT.*Entry confirmed filled"
                $reconBuyRows = @($buyRows | Where-Object { $_.comment -eq "reconcile_entry_fill" })
                Add-Check $checks "Reconciliation confirmed the fill" 1 $reconcileFilled ($reconcileFilled -eq 1)
                Add-Check $checks "Exactly one BUY row (reconcile_entry_fill)" "1, 1" "$($buyRows.Count), $($reconBuyRows.Count)" ($buyRows.Count -eq 1 -and $reconBuyRows.Count -eq 1)
                Add-Check $checks "Exactly one exit dispatch (EA [ORDER SENT] SELL)" 1 $eaSell ($eaSell -eq 1)
                Add-Check $checks "Exactly one roundtrip row" 1 $newRoundtripsObjs.Count ($newRoundtripsObjs.Count -eq 1)
            }

            "4" {
                $capLogs = Count-Matches $testLogLines "Daily limit reached"
                Add-Check $checks "Daily limit gate logged" ">=1" $capLogs ($capLogs -ge 1)
                Add-Check $checks "Exactly one exit dispatch (EA [ORDER SENT] SELL)" 1 $eaSell ($eaSell -eq 1)
                Add-Check $checks "Exactly one roundtrip row" 1 $newRoundtripsObjs.Count ($newRoundtripsObjs.Count -eq 1)
            }

            "5" {
                $idxHalt = First-Index $testLogLines $P_HALT
                $idxSell = First-Index $testLogLines $P_SELL_SENT
                $buyAfterHalt = Count-MatchesAfter $testLogLines $P_BUY_SENT $idxHalt
                Add-Check $checks "STATE_HALTED reached" ">=0 index" $idxHalt ($idxHalt -ge 0)
                Add-Check $checks "Position liquidated before the halt (SELL index < HALT index)" "< $idxHalt" $idxSell ($idxSell -ge 0 -and $idxHalt -ge 0 -and $idxSell -lt $idxHalt)
                Add-Check $checks "No entry dispatch after the halt" 0 $buyAfterHalt ($buyAfterHalt -eq 0)
            }

            "6" {
                # Two instances: the initial one is killed with taskkill /f (its Experts-log and journal tail can
                # be lost), the relaunch is stopped gracefully. Entry evidence is the max over the independent sources.
                $idxRecovery = First-Index $testLogLines $P_RESTART
                $buyAfterRecovery = Count-MatchesAfter $testLogLines $P_BUY_SENT $idxRecovery
                $sellAfterRecovery = Count-MatchesAfter $testLogLines $P_SELL_SENT $idxRecovery
                $entryEvidence = [Math]::Max($eaBuy, $jBuy)
                $priorInPos = Count-Matches $testLogLines "\[RESTART RECOVERY\].*prior state: STATE_IN_POSITION"
                $rtRestart = @($newRoundtripsObjs | Where-Object { $_.restart -eq "True" })
                # restart.set has InpResetState=false for both instances: no reset may run at all
                Add-Check $checks "No [STATE RESET] line (restart.set InpResetState=false)" 0 ($resetOk + $resetSkip) (($resetOk + $resetSkip) -eq 0)
                Add-Check $checks "[RESTART RECOVERY] emitted" ">=1" $restartRec ($restartRec -ge 1)
                Add-Check $checks "Zero [ORPHAN DETECTED]" 0 $orphanDet ($orphanDet -eq 0)
                Add-Check $checks "Recovery saw prior state STATE_IN_POSITION" ">=1" $priorInPos ($priorInPos -ge 1)
                Add-Check $checks "Exactly one entry (max of EA tag / journal)" 1 $entryEvidence ($entryEvidence -eq 1)
                Add-Check $checks "No entry dispatch after recovery" 0 $buyAfterRecovery ($buyAfterRecovery -eq 0)
                Add-Check $checks "Exactly one exit dispatch after recovery" 1 $sellAfterRecovery ($sellAfterRecovery -eq 1)
                # After taskkill /f the temporary lock GV is gone with the process: the relaunch must log a
                # fresh acquisition ("previous: none") after its INIT line, and no refusal anywhere.
                $lockBlocked = Count-Matches $testLogLines $P_DUP
                $idxLastInit = -1
                for ($i = $testLogLines.Count - 1; $i -ge 0; $i--) { if ($testLogLines[$i] -match $P_INIT) { $idxLastInit = $i; break } }
                $relaunchAcquired = Count-MatchesAfter $testLogLines "$P_LOCK_OK.*previous: none" $idxLastInit
                Add-Check $checks "Relaunch not blocked by stale instance lock" 0 $lockBlocked ($lockBlocked -eq 0)
                Add-Check $checks "Relaunch acquired the lock fresh (previous: none)" 1 $relaunchAcquired ($relaunchAcquired -eq 1)
                Add-Check $checks "gvariables.dat non-empty after the kill (GlobalVariablesFlush)" ">0 B" "${gvSizeAfterKill} B (before: ${gvSizeBeforeKill} B)" ($gvSizeAfterKill -gt 0)
            }
        }

        $failed = @($checks | Where-Object { -not $_.Pass })
        $verdict = if (-not $completedCleanly) { "FAIL (timeout after ${elapsedSec}s)" } elseif ($failed.Count -eq 0) { "PASS" } else { "FAIL" }

        # Capture stale_tick backoffs as a distinct note (does NOT alter verdict)
        $staleCount = [Math]::Max(@($newSkipsObjs | Where-Object { $_.reason -eq "stale_tick" }).Count, (Count-Matches $testLogLines "stale_tick"))
        $staleNote = if ($staleCount -gt 0) { "$staleCount backoff(s) encountered (120s retry each)" } else { "None (0 backoffs)" }

        Write-Host ">>> TEST ${tNum} VERDICT: $verdict ($($checks.Count - $failed.Count)/$($checks.Count) checks) <<<" -ForegroundColor $(if ($verdict -eq "PASS") { "Green" } else { "Red" })
        foreach ($c in $checks) {
            $mark = if ($c.Pass) { "ok  " } else { "FAIL" }
            Write-Host ("    [{0}] {1}: expected {2}, observed {3}" -f $mark, $c.Check, $c.Expected, $c.Observed) -ForegroundColor $(if ($c.Pass) { "Gray" } else { "Red" })
        }
        if ($staleCount -gt 0) {
            Write-Host "    [STALE TICK NOTE] $staleNote" -ForegroundColor Yellow
        }

        $Results.Add([PSCustomObject]@{
            Test = "Test $tNum ($tName)"
            Verdict = $verdict
            Summary = "$($checks.Count - $failed.Count)/$($checks.Count) checks passed in ${elapsedSec}s" + $(if ($failed.Count -gt 0) { "; failed: " + (($failed | ForEach-Object { $_.Check }) -join "; ") } else { "" })
            StaleTickBackoffs = $staleNote
            Checks = @($checks)
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

    $ResultsJson = "$ScriptDir\smoke_results_$ts.json"
    $Results | ConvertTo-Json -Depth 5 | Set-Content -Path $ResultsJson -Encoding utf8
    Write-Host "[RESULTS] Per-check evidence written to $ResultsJson" -ForegroundColor Green

    # Restore default preset in Terminal
    Copy-Item "$PresetsDir\default.set" "$TerminalDataDir\MQL5\Profiles\Tester\default.set" -Force -ErrorAction SilentlyContinue
    Copy-Item "$PresetsDir\default.set" "$TerminalDataDir\MQL5\Presets\default.set" -Force -ErrorAction SilentlyContinue

    Write-Host "`n==========================================================" -ForegroundColor Cyan
    Write-Host "           SMOKE TEST EXECUTION MATRIX                    " -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    $Results | Select-Object Test, Verdict, Summary, StaleTickBackoffs | Format-Table -AutoSize -Wrap

    Write-Host "[RESTORED-DEFAULTS CONFIRMATION]" -ForegroundColor Green
    Write-Host "  - Presets restored to default.set (InpCycleIntervalMin=36, InpMaxOrdersPerDay=40, InpMaxDrawdownEUR=50.0, InpResetState=false)"
    Write-Host "  - EXECTEST_* globals are NOT cleared here: each smoke test resets them at EA init. A production launch"
    Write-Host "    today inherits the smoke run's daily order count and daily equity baseline (both conservative)."
    Write-Host "  - Terminal processes stopped (graceful close, forced only after a 20 s grace period)."
    Write-Host "  - smoke_test_window.json and $ResultsJson saved."

} finally {
    Set-KeepAwake -Enable $false
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Smoke test suite execution completed." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
