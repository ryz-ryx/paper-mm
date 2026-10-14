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
    5A. Equity stop, deterministic: XTestSeedBaseline seeds the daily baseline above equity (smoke6a, DD 1.0 EUR,
        InpResetState=false) -> entry gate halts, zero entries
    5B. Equity stop, market-dependent: DD 0.001 EUR, up to 3 round trips; CONDITIONAL if never triggered
    6. Mid-hold crash restart (test_restart.py, taskkill /f)

    State hygiene: smoke1/2/3/5/6 set InpResetState=true, so the EA wipes EXECTEST_* globals at init and logs
    "[STATE RESET] Cleared ...". restart.set (T6, both instances) sets InpResetState=false: the relaunch must
    recover from the persisted state, so T6 asserts that no reset line appears at all. The old Python ClearGV
    call was a no-op: the MetaTrader5 package has no global-variable API, and its error was hidden by 2>$null.

    T5A and T6 each start from a clean EXECTEST_* state (ClearGV script-only launch): T5A's equity halt persists
    EXECTEST_CIRCUIT_BREAKER=1, and smoke6a.set / restart.set (InpResetState=false) would load it.

    -Mode SelfTest runs the offline checks for the harness bugs fixed in v2.10 (no MT5 contact, no orders).
    -OnlyTests T5A,T6 runs only the listed tests (suite order; "T" prefix optional). Default: all tests.
#>

param (
    [ValidateSet("Attended", "ScheduleTask", "DryRun", "SelfTest")]
    [string]$Mode = "Attended",
    [string[]]$OnlyTests = @()
)

$ErrorActionPreference = "Stop"

# Test ids in suite order (the test table itself is built in the attended section)
$SuiteTestIds = @("1", "2", "3A", "3B", "4", "5A", "5B", "6")

function Resolve-TestSelection {
    # "-OnlyTests T5A,T6" arrives as @("T5A","T6") from PowerShell, as @("T5A,T6") through powershell.exe -File.
    # Returns the selected ids in suite order; an empty request selects all; an unknown id is an error.
    param ([string[]]$Requested, [string[]]$Known)
    $ids = @($Requested | ForEach-Object { "$_" -split '[,\s]+' } | Where-Object { $_ -ne "" } |
             ForEach-Object { ($_.Trim() -replace '^(?i)(test|t)', '').ToUpperInvariant() })
    if ($ids.Count -eq 0) { return @($Known) }
    $unknown = @($ids | Where-Object { $Known -notcontains $_ })
    if ($unknown.Count -gt 0) { throw "Unknown -OnlyTests id(s): $($unknown -join ', '). Valid: $($Known -join ', ') (T prefix optional)." }
    return @($Known | Where-Object { $ids -contains $_ })
}

$SelectedTestIds = @(Resolve-TestSelection $OnlyTests $SuiteTestIds)

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
$SeedScriptSource = "$ScriptDir\XTestSeedBaseline.mq5"
$SeedScriptBinary = "$TerminalDataDir\MQL5\Scripts\XTestSeedBaseline.ex5"
$ClearGvSource = "$ScriptDir\ClearGV.mq5"
$ClearGvBinary = "$TerminalDataDir\MQL5\Scripts\ClearGV.ex5"
$InitTimeoutSec = 90

# Test table (script level so -Mode SelfTest can check it).
# Timeouts: ExecTest retries 120 s after every entry skip (ExecTest.mq5:2499), and on ICMarketsEU-Demo only ~20% of
# attempts pass the zero_spread / stale_tick (> 500 ms) gates (ExecTest.mq5:1502-1511; ~0.77 ticks/s per symbol,
# 41% of ticks with zero spread). 1500 s covers the helpers' 1300 s position wait (~10 attempts) + the 60 s hold
# + exit retries (T1: 12.75 s of backoff) + the T6 kill/relaunch + harness stop. Every test still ends on
# evidence (Test-RunComplete), so a fast entry costs nothing.
# ExpectEntries: entry dispatches the common checks require; $null = the test checks entries itself.
# NeedsEntry: the test is only meaningful after an entry; none at all with gate skips => INVALID (gate starved).
# Clean: start from no EXECTEST_* globals (Invoke-ClearExecTestState), so the test runs the same alone
# (-OnlyTests) as inside the suite.
$TestTimeoutSec = 1500
$HelperPollTimeoutSec = 1300   # external_close.py TIMEOUT_SEC, test_restart.py poll_timeout (SelfTest 13 reads both)
$AllTests = @(
    @{ Num = "1"; Name = "Close Reject 6"; Ini = "smoke1.ini"; Helper = $null; Timeout = $TestTimeoutSec; ExpectEntries = 1; NeedsEntry = $true },
    @{ Num = "2"; Name = "External Close"; Ini = "smoke2.ini"; Helper = $ExternalClosePy; Timeout = $TestTimeoutSec; ExpectEntries = 1; NeedsEntry = $true },
    @{ Num = "3A"; Name = "Timeout Filled"; Ini = "smoke3.ini"; Helper = $null; Timeout = $TestTimeoutSec; ExpectEntries = 1; NeedsEntry = $true },
    @{ Num = "3B"; Name = "Timeout Unfilled"; Ini = $null; Helper = $null; Timeout = 0; NeedsEntry = $false },
    @{ Num = "4"; Name = "Daily Cap 1"; Ini = "smoke5.ini"; Helper = $null; Timeout = $TestTimeoutSec; ExpectEntries = 1; NeedsEntry = $true },
    @{ Num = "5A"; Name = "Equity Stop (seeded baseline, entry gate)"; Ini = "smoke6a.ini"; Helper = $null; Timeout = $TestTimeoutSec; ExpectEntries = 0; NeedsEntry = $false; Seed = "seed_baseline.ini"; Clean = $true },
    @{ Num = "5B"; Name = "Equity Stop (drawdown after a close, market-dependent)"; Ini = "smoke6.ini"; Helper = $null; Timeout = $TestTimeoutSec; ExpectEntries = $null; NeedsEntry = $true },
    @{ Num = "6"; Name = "Mid-Hold Restart"; Ini = "restart.ini"; Helper = $TestRestartPy; Timeout = $TestTimeoutSec; ExpectEntries = $null; NeedsEntry = $true; Clean = $true }
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "           EXECTEST.MQ5 SMOKE TEST HARNESS                " -ForegroundColor Cyan
Write-Host " Script Dir: $ScriptDir" -ForegroundColor Cyan
Write-Host " Mode:       $Mode" -ForegroundColor Cyan
Write-Host " Tests:      $(if ($OnlyTests.Count -gt 0) { "$($SelectedTestIds -join ', ') (-OnlyTests)" } else { 'all' })" -ForegroundColor Cyan
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
    $action = "powershell.exe -ExecutionPolicy Bypass -File `"$ScriptDir\run_smoke_tests.ps1`" -Mode Attended" +
              $(if ($OnlyTests.Count -gt 0) { " -OnlyTests $($SelectedTestIds -join ',')" } else { "" })

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
$script:LogReadErrors = 0   # counted per test; a non-zero count fails the "no log/CSV read errors" check

function Get-Utf16LogLines {
    # Read errors are logged and counted, never swallowed: an unreadable log looks exactly like "tag absent".
    # The final CRLF must not yield a trailing "" element: Get-NewLines slices post[pre.Count..], so a pre-read
    # counted one line too many and hid the first new line of every launch. Each ExecTest launch starts with a
    # "=====" banner, so that went unnoticed until the one-line XTestSeedBaseline output was hidden (2026-10-14).
    param ([string]$Path)
    if (Test-Path $Path) {
        try {
            $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::Unicode)
            $text = $sr.ReadToEnd()
            $sr.Close()
            $fs.Close()
            $lines = @($text -split "`r?`n")
            if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq "") {
                if ($lines.Count -eq 1) { return @() }
                $lines = @($lines[0..($lines.Count - 2)])
            }
            return $lines
        } catch {
            $script:LogReadErrors++
            Write-Host "[LOG READ ERROR] ${Path}: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
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
            $script:LogReadErrors++
            Write-Host "[CSV READ ERROR] ${FilePath}: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
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
# Experts-log lines are "<code>\t0\t<time>\t<source>\t<message>": [CRITICAL] must be the message itself (an EA
# Print). Alert() echoes the same text as "Alert: [CRITICAL] ...", which the old pattern counted a second time.
$P_CRITICAL    = '(^|\t)\[CRITICAL\]'
$P_ALERT_CRIT  = '(^|\t)Alert: \[CRITICAL\]'
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
$P_EXIT_OK     = '\[EXIT CONFIRMED\]'
$P_CLOSE_IDLE  = 'Position liquidated; probe transitioned to IDLE'
$P_HALT_EQUITY = '-> STATE_HALTED \| Reason: Equity drop'
$P_BASE_LOADED = '\[PERSISTENCE\] Loaded daily baseline equity for \d{4}-\d{2}-\d{2}: ([0-9.]+) EUR'
$P_SEED        = '\[SEED BASELINE\] (OK|REFUSED|FAILED)'

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

$T5B_MAX_ATTEMPTS = 3

function Resolve-Verdict {
    # Failed checks always win. A test may be CONDITIONAL when its trigger is market-dependent and never
    # fired (T5B); that is reported, never upgraded to PASS. A timeout without a conditional note is a FAIL.
    param ([bool]$Completed, [int]$FailedCount, [string]$ConditionalNote, [int]$ElapsedSec)
    if ($FailedCount -gt 0) { return "FAIL" }
    if ($ConditionalNote) { return "CONDITIONAL ($ConditionalNote)" }
    if (-not $Completed) { return "FAIL (timeout after ${ElapsedSec}s)" }
    return "PASS"
}

# skips.csv rows that are not entry attempts (written by the IDLE reconciliation, not by ExecuteEntry)
$NON_ENTRY_SKIP_REASONS = @("orphan_external_close")

function Get-EntryStats {
    # Entry attempts of one run. ExecuteEntry either dispatches (one entry) or queues one skips.csv row
    # (market_closed / no_tick / zero_spread / stale_tick, ExecTest.mq5:1486-1511) and retries in 120 s, so
    # attempts = entry-gate skip rows + entries. Attempts until the first entry: gate skips stamped before the
    # first trades.csv BUY row + 1; without a BUY row, [CYCLE TRIGGER] lines up to the first [ORDER SENT] BUY.
    param ($SkipRows, $BuyRows, [int]$Entries, [string[]]$LogLines = @())
    $gate = @($SkipRows | Where-Object { $_ -and $NON_ENTRY_SKIP_REASONS -notcontains $_.reason })
    $zs = @($gate | Where-Object { $_.reason -eq "zero_spread" }).Count
    $st = @($gate | Where-Object { $_.reason -eq "stale_tick" }).Count
    $otherRows = @($gate | Where-Object { $_.reason -ne "zero_spread" -and $_.reason -ne "stale_tick" })
    $otherBy = @($otherRows | Group-Object reason | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Count)" })
    $first = $null
    $firstSource = "-"
    if ($Entries -gt 0) {
        $buyTs = @($BuyRows | ForEach-Object { Parse-CsvTs $_.timestamp_utc } | Where-Object { $_ } | Sort-Object)
        if ($buyTs.Count -gt 0) {
            $first = @($gate | Where-Object { $ts = Parse-CsvTs $_.timestamp_utc; $ts -and $ts -lt $buyTs[0] }).Count + 1
            $firstSource = "skips.csv vs first BUY row"
        } else {
            $idxBuy = First-Index $LogLines $P_BUY_SENT
            if ($idxBuy -ge 0) {
                $first = 0
                for ($i = 0; $i -lt $idxBuy; $i++) { if ($LogLines[$i] -match '\[CYCLE TRIGGER\]') { $first++ } }
                $firstSource = "log [CYCLE TRIGGER] lines before the first [ORDER SENT] BUY"
            }
        }
    }
    return [PSCustomObject]@{
        Attempts = $gate.Count + $Entries; Entries = $Entries; GateSkips = $gate.Count
        ZeroSpread = $zs; StaleTick = $st; Other = $otherRows.Count; OtherReasons = ($otherBy -join ", ")
        AttemptsToFirstEntry = $first; FirstEntrySource = $firstSource
    }
}

function Format-EntryStats {
    param ($S)
    $firstTxt = if ($null -ne $S.AttemptsToFirstEntry) { "$($S.AttemptsToFirstEntry) ($($S.FirstEntrySource))" } elseif ($S.Entries -gt 0) { "n/a (entry not in trades.csv or log)" } else { "- (no entry)" }
    return "attempts=$($S.Attempts) entries=$($S.Entries) attempts_to_first_entry=$firstTxt | skips: zero_spread=$($S.ZeroSpread) stale_tick=$($S.StaleTick) other=$($S.Other)$(if ($S.OtherReasons) { " ($($S.OtherReasons))" })"
}

function Resolve-EntryStarvation {
    # A test that needs an entry, saw none, and saw entry-gate skips was starved by the broker feed (zero spread,
    # stale ticks): its checks were never exercised, so it is INVALID, not a MISS of individual checks. With no
    # attempt at all (EA refused / halted / never cycled) it is a real failure and goes through the checks.
    # Returns the INVALID note, or $null when the normal verdict applies.
    param ([bool]$NeedsEntry, $Stats)
    if (-not $NeedsEntry -or $Stats.Entries -gt 0 -or $Stats.GateSkips -eq 0) { return $null }
    return "entry gate starved: $($Stats.GateSkips) attempt(s), 0 entries; skips zero_spread=$($Stats.ZeroSpread), stale_tick=$($Stats.StaleTick), other=$($Stats.Other)$(if ($Stats.OtherReasons) { " ($($Stats.OtherReasons))" })"
}

$SeedMarkerFile = "$CommonDir\xtest_seed_baseline.txt"   # written by XTestSeedBaseline with FileClose

function Invoke-SeedBaseline {
    # T5A pre-step: run MQL5\Scripts\XTestSeedBaseline from a startup config that loads no Expert, so it
    # can place no order. Completion is the script's marker file in Common\Files, not the Experts log: in the
    # 2026-10-13 run the script printed "[SEED BASELINE] OK" at 12:20:45.571 and the line was still not on disk
    # when the 90 s poll gave up at 12:22:13. The log line is cross-checked after the terminal has stopped.
    #
    # Ok is decided by the marker (status OK, baseline parses, readback == baseline and date == today's UTC
    # midnight), no ExecTest init, zero journal orders and a graceful stop. The post-stop Experts-log line is a
    # cross-check only: absent or different adds a warning, never flips Ok (run 3, 2026-10-14: the line was on
    # disk but hidden by the Get-Utf16LogLines off-by-one, and the seed was wrongly declared failed).
    param ([string]$IniPath, [int]$TimeoutSec = 90)
    $preLines = @(Get-Mql5LogLines)
    $preJournal = @(Get-JournalLines)
    Remove-Item $SeedMarkerFile -Force -ErrorAction SilentlyContinue
    Write-Host "[SEED] Launching terminal64.exe with $IniPath (script only, no Expert)..." -ForegroundColor Yellow
    Start-Process -FilePath $TerminalExe -ArgumentList "/config:`"$IniPath`"" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $marker = $null
    $markerAtUtc = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if (Test-Path $SeedMarkerFile) {
            $marker = @(Get-CsvLines $SeedMarkerFile) | Where-Object { $_ -match $P_SEED } | Select-Object -First 1
            if ($marker) { $markerAtUtc = (Get-Date).ToUniversalTime(); break }
        }
    }
    $stop = Stop-Terminal
    # Post-stop evidence (the terminal flushes its logs on a graceful exit)
    $newLog = @(Get-NewLines $preLines (Get-Mql5LogLines))
    $newJournal = @(Get-NewLines $preJournal (Get-JournalLines))
    $logLine = $newLog | Where-Object { $_ -match $P_SEED } | Select-Object -First 1
    $eaStarted = ((Count-Matches $newLog $P_INIT) -gt 0)
    $scriptLoaded = ((Count-Matches $newJournal "script XTestSeedBaseline \(.*\) loaded successfully") -gt 0)
    $orders = Count-Matches $newJournal "': market (buy|sell) "
    $expectedDate = Get-UtcMidnightUnix $(if ($markerAtUtc) { $markerAtUtc } else { (Get-Date).ToUniversalTime() })
    $eval = Test-SeedResult $marker $expectedDate $eaStarted $orders $stop
    $logCheck = Compare-SeedLogLine $logLine $marker
    return [PSCustomObject]@{
        Ok              = $eval.Ok
        Checks          = $eval.Checks
        Fields          = $eval.Fields
        Line            = $marker
        LogLine         = $logLine
        LogAgrees       = $logCheck.Agrees
        Warning         = $logCheck.Warning
        ScriptLoaded    = $scriptLoaded
        Baseline        = $eval.Fields.Baseline
        ExpectedDateUtc = $expectedDate
        EaStarted       = $eaStarted
        Orders          = $orders
        Stop            = $stop
    }
}

function Get-UtcMidnightUnix {
    # Same rule as XTestSeedBaseline / ExecTest LoadPersistentState: TimeGMT() truncated to the UTC day
    param ([datetime]$UtcNow)
    return [DateTimeOffset]::new([datetime]::SpecifyKind($UtcNow.Date, [DateTimeKind]::Utc)).ToUnixTimeSeconds()
}

function ConvertFrom-SeedMarker {
    # "[SEED BASELINE] OK equity=1000.70 baseline=1005.70 offset=5.00 date_utc=1791936000 (2026.10.14) readback=1005.70/1791936000"
    param ([string]$Marker)
    $f = [ordered]@{ Status = $null; Equity = $null; Baseline = $null; Offset = $null; DateUtc = $null; ReadbackEquity = $null; ReadbackDate = $null }
    if (-not $Marker) { return [PSCustomObject]$f }
    if ($Marker -match '\[SEED BASELINE\] (OK|FAILED|REFUSED)') { $f.Status = $Matches[1] }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $num = [double]0; $int = [long]0
    if ($Marker -match '\bequity=(-?[0-9]+(?:\.[0-9]+)?)' -and [double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) { $f.Equity = $num }
    if ($Marker -match '\bbaseline=(-?[0-9]+(?:\.[0-9]+)?)' -and [double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) { $f.Baseline = $num }
    if ($Marker -match '\boffset=(-?[0-9]+(?:\.[0-9]+)?)' -and [double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) { $f.Offset = $num }
    if ($Marker -match '\bdate_utc=(\d+)' -and [long]::TryParse($Matches[1], [ref]$int)) { $f.DateUtc = $int }
    if ($Marker -match '\breadback=(-?[0-9]+(?:\.[0-9]+)?)/(\d+)') {
        $rbDate = $Matches[2]
        if ([double]::TryParse($Matches[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) { $f.ReadbackEquity = $num }
        if ([long]::TryParse($rbDate, [ref]$int)) { $f.ReadbackDate = $int }
    }
    return [PSCustomObject]$f
}

function Test-SeedResult {
    # Required seed checks; every one must pass for Ok. Pure function (SelfTest 10).
    param ([string]$Marker, [long]$ExpectedDateUtc, [bool]$EaStarted, [int]$Orders, [string]$Stop)
    $f = ConvertFrom-SeedMarker $Marker
    $checks = [System.Collections.ArrayList]::new()
    Add-Check $checks "Seed marker file written" "present" $(if ($Marker) { "present" } else { "absent" }) ([bool]$Marker)
    Add-Check $checks "Seed marker status" "OK" $(if ($f.Status) { $f.Status } else { "-" }) ($f.Status -eq "OK")
    Add-Check $checks "Seed baseline parses" "number" $(if ($null -ne $f.Baseline) { $f.Baseline } else { "-" }) ($null -ne $f.Baseline)
    Add-Check $checks "Seed readback equity == baseline" "$($f.Baseline)" "$($f.ReadbackEquity)" ($null -ne $f.Baseline -and $null -ne $f.ReadbackEquity -and [Math]::Abs($f.ReadbackEquity - $f.Baseline) -lt 0.005)
    Add-Check $checks "Seed date_utc == today's UTC midnight" $ExpectedDateUtc "$($f.DateUtc)" ($f.DateUtc -eq $ExpectedDateUtc)
    Add-Check $checks "Seed readback date == today's UTC midnight" $ExpectedDateUtc "$($f.ReadbackDate)" ($f.ReadbackDate -eq $ExpectedDateUtc)
    Add-Check $checks "No ExecTest init during the script-only seed launch" $false $EaStarted (-not $EaStarted)
    Add-Check $checks "Seed launch placed no orders (journal)" 0 $Orders ($Orders -eq 0)
    Add-Check $checks "Seed launch stopped gracefully (GVs written by the terminal)" "graceful" $Stop ($Stop -eq "graceful")
    return [PSCustomObject]@{ Ok = (@($checks | Where-Object { -not $_.Pass }).Count -eq 0); Checks = @($checks); Fields = $f }
}

function Compare-SeedLogLine {
    # Cross-check only. The Experts-log message field (after the 4th tab) must equal the marker text exactly.
    param ([string]$LogLine, [string]$Marker)
    if (-not $Marker) { return [PSCustomObject]@{ Agrees = $false; Warning = $null } }
    if (-not $LogLine) {
        return [PSCustomObject]@{ Agrees = $false; Warning = "WARN: no [SEED BASELINE] line in the post-stop Experts log (log not flushed?); marker is authoritative" }
    }
    $f = $LogLine -split "`t", 5
    $msg = if ($f.Count -ge 5) { $f[4] } else { $LogLine }
    if ([string]::Equals($msg.Trim(), $Marker.Trim(), [System.StringComparison]::Ordinal)) { return [PSCustomObject]@{ Agrees = $true; Warning = $null } }
    return [PSCustomObject]@{ Agrees = $false; Warning = "WARN: Experts-log line differs from the marker: log '$($msg.Trim())' vs marker '$($Marker.Trim())'" }
}

function Get-GvExecTestNames {
    # EXECTEST_* names present in gvariables.dat. Names are stored as UTF-16LE; decode at both byte
    # alignments so a name at an odd offset is not missed. $null = unreadable (counted as a read error).
    # The unary comma keeps an empty result an empty array (a bare "return @()" reaches the caller as $null).
    if (-not (Test-Path $GvFile)) { return ,@() }
    try {
        $fs = [System.IO.FileStream]::new($GvFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $ms = [System.IO.MemoryStream]::new(); $fs.CopyTo($ms); $fs.Close()
        $b = $ms.ToArray()
    } catch {
        $script:LogReadErrors++
        Write-Host "[GV READ ERROR] ${GvFile}: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    $text = [System.Text.Encoding]::Unicode.GetString($b)
    if ($b.Length -gt 1) { $text += "`n" + [System.Text.Encoding]::Unicode.GetString($b, 1, $b.Length - 1) }
    return ,@([regex]::Matches($text, 'EXECTEST_[A-Z0-9_]+') | ForEach-Object { $_.Value } | Sort-Object -Unique)
}

function Invoke-ClearExecTestState {
    # T5A / T6 pre-step: start from no EXECTEST_* globals. T5A's equity halt persists EXECTEST_CIRCUIT_BREAKER=1
    # (ExecTest.mq5:1137), and smoke6a.set / restart.set have InpResetState=false, so without this a T6 run after
    # T5A (-OnlyTests T5A,T6, or the full suite when T5B halts) loads a tripped breaker and never enters.
    # Script-only launch of MQL5\Scripts\ClearGV from a temporary startup config (no Expert -> no order).
    # Done = no EXECTEST_* name left in gvariables.dat (ClearGV calls GlobalVariablesFlush), re-checked after
    # the graceful stop. Nothing to clear (terminal stopped, no names on disk) -> no launch.
    param ([int]$TimeoutSec = 45)
    $before = Get-GvExecTestNames
    if ($null -ne $before -and @($before).Count -eq 0) {
        return [PSCustomObject]@{ Ok = $true; Launched = $false; Before = @(); After = @(); Stop = "not-launched"; Orders = 0; EaStarted = $false; Summary = $null; Warning = $null }
    }
    $ini = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_cleargv_" + [guid]::NewGuid().ToString("N") + ".ini")
    [System.IO.File]::WriteAllText($ini, "[StartUp]`r`nScript=ClearGV`r`nSymbol=EURUSD`r`nPeriod=M1`r`n")
    $preLines = @(Get-Mql5LogLines)
    $preJournal = @(Get-JournalLines)
    Write-Host "[CLEAN] EXECTEST_* on disk: $(@($before) -join ', '). Launching terminal64.exe with ClearGV (script only, no Expert)..." -ForegroundColor Yellow
    Start-Process -FilePath $TerminalExe -ArgumentList "/config:`"$ini`"" | Out-Null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $liveClean = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $now = Get-GvExecTestNames
        if ($null -ne $now -and @($now).Count -eq 0) { $liveClean = $true; break }
    }
    $stop = Stop-Terminal
    Remove-Item $ini -Force -ErrorAction SilentlyContinue
    $after = Get-GvExecTestNames
    $newLog = @(Get-NewLines $preLines (Get-Mql5LogLines))
    $newJournal = @(Get-NewLines $preJournal (Get-JournalLines))
    $summary = $newLog | Where-Object { $_ -match '\[ClearGV\] Summary:' } | Select-Object -First 1
    $eaStarted = ((Count-Matches $newLog $P_INIT) -gt 0)
    $orders = Count-Matches $newJournal "': market (buy|sell) "
    $ok = ($null -ne $after -and @($after).Count -eq 0 -and $orders -eq 0 -and -not $eaStarted -and $stop -eq "graceful")
    return [PSCustomObject]@{
        Ok = $ok; Launched = $true; LiveClean = $liveClean; Before = @($before); After = @($after); Stop = $stop
        Orders = $orders; EaStarted = $eaStarted; Summary = $summary
        Warning = $(if (-not $summary) { "WARN: no [ClearGV] Summary line in the post-stop Experts log; gvariables.dat is authoritative" } else { $null })
    }
}

# Completion signals (the Experts log and journal are NOT live signals: the terminal buffers them; T2's
# [EXTERNAL CLOSE DETECTED] of 12:06:12.173 was not readable on disk for at least 60 s on 2026-10-13):
#   * open positions via the MetaTrader5 API (Check-OpenPositions; -1 = terminal down)
#   * Common\Files CSV rows: the EA flushes its queues in every IDLE pass with FileClose, so a roundtrip
#     row appears within one poll interval of a close that returns to IDLE, and does NOT appear while the
#     FSM is HALTED (the queue is only written at OnDeinit then)
#   * helper exit code, elapsed time
# Every tag check is then evaluated on a post-stop read of the Experts log and journal.
$T4_GATE_GRACE_SEC   = 12   # [ENTRY GATED] is printed on the first pass after the cap and every 10 s
$T5A_OBSERVE_SEC     = 25   # init (~3 s) + first OnTimer pass, where the seeded baseline halts the gate
$T5B_HALT_INFER_SEC  = 10   # a close without a roundtrip row this long after it => FSM not IDLE => halted

function Get-GvFileSnapshot {
    if (Test-Path $GvFile) {
        $fi = Get-Item $GvFile
        return [PSCustomObject]@{ Size = $fi.Length; MTime = $fi.LastWriteTime.ToString("HH:mm:ss.fff"); At = (Get-Date).ToString("HH:mm:ss.fff") }
    }
    return [PSCustomObject]@{ Size = 0; MTime = "-"; At = (Get-Date).ToString("HH:mm:ss.fff") }
}

function Get-GvKillSnapshot {
    # gvariables.dat right after the given terminal process exited (T6 taskkill), plus how late the capture was
    # and whether any terminal64 was running at that instant (the relaunch follows ~3 s later).
    param ([System.Diagnostics.Process]$Proc)
    $snap = Get-GvFileSnapshot
    $exitAt = $null
    try { $exitAt = $Proc.ExitTime } catch {}
    $snap | Add-Member -NotePropertyName ExitAt -NotePropertyValue $(if ($exitAt) { $exitAt.ToString("HH:mm:ss.fff") } else { "-" })
    $snap | Add-Member -NotePropertyName LagMs -NotePropertyValue $(if ($exitAt) { [int]((Get-Date) - $exitAt).TotalMilliseconds } else { -1 })
    $snap | Add-Member -NotePropertyName TerminalDown -NotePropertyValue (-not (Test-TerminalRunning))
    return $snap
}

function Test-GvDownCheck {
    # T6 "gvariables.dat non-empty while the terminal was down": decided by the kill-time capture; the 3 s poll
    # capture is a secondary signal, used only when the kill-time capture is missing. Pure function (SelfTest 11).
    param ($AtKill, $AtPoll)
    if ($null -ne $AtKill) {
        return [PSCustomObject]@{ Pass = ([bool]$AtKill.TerminalDown -and $AtKill.Size -gt 0); Source = "kill-time capture" }
    }
    if ($null -ne $AtPoll) { return [PSCustomObject]@{ Pass = ($AtPoll.Size -gt 0); Source = "terminal-down poll (kill-time capture missing)" } }
    return [PSCustomObject]@{ Pass = $false; Source = "none (neither the kill nor a terminal-down poll was observed)" }
}

function New-RunMonitor {
    return [PSCustomObject]@{
        OpenPos = -1; PrevPos = 0; SawPosition = $false; Closes = 0; LastCloseAt = $null; SecSinceLastClose = -1
        HelperExited = $false; HelperExitCode = $null; ElapsedSec = 0.0; NewRoundtrips = 0; NewOrphanSkips = 0
    }
}

function Update-RunMonitor {
    # One poll: fold the API position count into position/close bookkeeping.
    param ($Mon, [int]$OpenPos, [datetime]$Now)
    $Mon.OpenPos = $OpenPos
    if ($OpenPos -gt 0) { $Mon.SawPosition = $true }
    if ($OpenPos -eq 0 -and $Mon.PrevPos -gt 0) { $Mon.Closes++; $Mon.LastCloseAt = $Now }
    if ($OpenPos -ge 0) { $Mon.PrevPos = $OpenPos }   # -1 (terminal down, T6) keeps the last known count
    $Mon.SecSinceLastClose = if ($Mon.LastCloseAt) { ($Now - $Mon.LastCloseAt).TotalSeconds } else { -1 }
}

function Test-RunComplete {
    # Completion predicate of the monitoring loop, per test, over the live signals in $Mon only.
    param ([string]$TestNum, $Mon)
    switch ($TestNum) {
        # The helper closed the position (exit 0), no position is open, and the EA flushed its
        # orphan_external_close skip row (written in the IDLE pass right after it detects the close)
        "2" { return ($Mon.HelperExited -and $Mon.HelperExitCode -eq 0 -and $Mon.OpenPos -eq 0 -and $Mon.NewOrphanSkips -ge 1) }
        # Entry, close and roundtrip row, then a grace period so the cap gate has been evaluated and printed
        "4" { return ($Mon.SawPosition -and $Mon.OpenPos -eq 0 -and $Mon.NewRoundtrips -ge 1 -and $Mon.SecSinceLastClose -ge $T4_GATE_GRACE_SEC) }
        # Expected: no position ever (gate halts first); if one appears anyway, wait for its roundtrip and stop
        "5A" { return ($Mon.OpenPos -eq 0 -and ((-not $Mon.SawPosition -and $Mon.ElapsedSec -ge $T5A_OBSERVE_SEC) -or ($Mon.SawPosition -and $Mon.NewRoundtrips -ge 1))) }
        # After each close: a roundtrip row => back in IDLE (not triggered); none for $T5B_HALT_INFER_SEC => halted
        "5B" { return ($Mon.OpenPos -eq 0 -and $Mon.Closes -ge 1 -and (($Mon.NewRoundtrips -lt $Mon.Closes -and $Mon.SecSinceLastClose -ge $T5B_HALT_INFER_SEC) -or $Mon.NewRoundtrips -ge $T5B_MAX_ATTEMPTS)) }
        # Helper killed + relaunched (exit 0), the recovered position was closed, its restart roundtrip flushed
        "6" { return ($Mon.HelperExited -and $Mon.HelperExitCode -eq 0 -and $Mon.SawPosition -and $Mon.OpenPos -eq 0 -and $Mon.NewRoundtrips -ge 1) }
        default { return ($Mon.SawPosition -and $Mon.OpenPos -eq 0 -and $Mon.NewRoundtrips -ge 1) }
    }
}

function Get-LogTime {
    # "<code>\t0\tHH:mm:ss.fff\t..." -> "HH:mm:ss.fff" (same-day string compare is chronological)
    param ([string]$Line)
    $f = $Line -split "`t"
    if ($f.Count -ge 3 -and $f[2] -match '^\d{2}:\d{2}:\d{2}\.\d{3}$') { return $f[2] }
    return $null
}

function Limit-ToFirstIdleAfter {
    # T2 evidence ends at the first "-> STATE_IDLE" after the external close; later cycles are ignored.
    # Returns the cut index (-1 = no cut) and the cut time, so the journal can be trimmed the same way.
    param ([string[]]$Lines, [string]$AnchorPattern)
    $idxA = First-Index $Lines $AnchorPattern
    if ($idxA -lt 0) { return [PSCustomObject]@{ Index = -1; Time = $null } }
    $idxI = First-Index $Lines $P_TO_IDLE ($idxA + 1)
    if ($idxI -lt 0) { return [PSCustomObject]@{ Index = -1; Time = $null } }
    return [PSCustomObject]@{ Index = $idxI; Time = (Get-LogTime $Lines[$idxI]) }
}

function Get-T6EntryTickets {
    # Independent sources for the T6 entry: the relaunch's [RESTART RECOVERY] ticket (the killed instance's
    # own log tail is lost), any surviving [ORDER SENT] BUY line, and the position the helper detected.
    param ([string[]]$LogLines, [string[]]$HelperOut)
    $t = [ordered]@{ recovery = @(); ea_buy = @(); helper = @() }
    foreach ($l in $LogLines) {
        if ($l -match '\[RESTART RECOVERY\] Recovered position (\d+)') { $t.recovery += $Matches[1] }
        if ($l -match '\[ORDER SENT\] \S+ BUY retcode=\d+ order=(\d+)') { $t.ea_buy += $Matches[1] }
    }
    foreach ($l in $HelperOut) { if ($l -match '\[TEST_RESTART\] Found position (\d+)') { $t.helper += $Matches[1] } }
    $all = @($t.recovery + $t.ea_buy + $t.helper | Select-Object -Unique)
    return [PSCustomObject]@{ Sources = $t; Distinct = $all }
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
    $new = @(Get-NewCsvObjects $pre $post)
    $rawPre = ([System.IO.File]::ReadAllText($tmp) -replace "2026-10-12 10:01:00.100,BUY,first_new`r`n2026-10-12 10:01:12.900,SELL,second_new`r`n", "") -split "`r?`n"
    $rawPost = [System.IO.File]::ReadAllText($tmp) -split "`r?`n"
    $oldSlice = $rawPost[$rawPre.Count..($rawPost.Count - 1)]
    Remove-Item $tmp -Force
    Assert-True "new rows found" ($new.Count -eq 2 -and $new[0].comment -eq "first_new" -and $new[1].comment -eq "second_new") "got $($new.Count): $(($new | ForEach-Object { $_.comment }) -join ',')"
    Assert-True "old slicing reproduced the bug" ($oldSlice.Count -eq 2 -and $oldSlice[0] -match "second_new" -and $oldSlice[1] -eq "") "old slice = [$($oldSlice -join ' | ')]"

    Write-Host "[SELFTEST 1b] Get-NewCsvObjects call sites wrapped in @(): exactly 1 row and 0 rows" -ForegroundColor Yellow
    $hdr = "timestamp_utc,side,comment"
    $pre1 = @($hdr, "2026-10-12 10:00:00.000,BUY,old")
    $post1 = @($hdr, "2026-10-12 10:00:00.000,BUY,old", "2026-10-12 10:01:00.100,SELL,only_new")
    $oneRaw = Get-NewCsvObjects $pre1 $post1           # function output is unrolled to a bare PSCustomObject
    $one = @(Get-NewCsvObjects $pre1 $post1)
    $zero = @(Get-NewCsvObjects $pre1 $pre1)
    $zeroHdr = @(Get-NewCsvObjects @() @($hdr))
    Write-Host "    info: unwrapped 1-row result type=$($oneRaw.GetType().Name), .Count='$($oneRaw.Count)' (PowerShell $($PSVersionTable.PSVersion))"
    Assert-True "1 new row -> Count 1" ($one.Count -eq 1 -and $one[0].comment -eq "only_new") "Count=$($one.Count) comment=$($one[0].comment)"
    Assert-True "0 new rows -> Count 0" ($zero.Count -eq 0) "Count=$($zero.Count)"
    Assert-True "header-only file -> Count 0" ($zeroHdr.Count -eq 0) "Count=$($zeroHdr.Count)"

    Write-Host "[SELFTEST 2] Completion uses live signals only (API positions, CSV rows, helper exit), never the Experts log" -ForegroundColor Yellow
    function New-TestMon { param ([hashtable]$H) $m = New-RunMonitor; foreach ($k in $H.Keys) { $m.$k = $H[$k] }; return $m }
    $m4 = New-TestMon @{ OpenPos = 0; SawPosition = $true; Closes = 1; NewRoundtrips = 1; SecSinceLastClose = 13 }
    Assert-True "T4 completes: position seen, closed, roundtrip row, gate grace elapsed" (Test-RunComplete "4" $m4) "grace $T4_GATE_GRACE_SEC s"
    Assert-True "T4 waits during the gate grace" (-not (Test-RunComplete "4" (New-TestMon @{ OpenPos = 0; SawPosition = $true; Closes = 1; NewRoundtrips = 1; SecSinceLastClose = 4 }))) "4 s after close"
    Assert-True "T4 not complete while position open" (-not (Test-RunComplete "4" (New-TestMon @{ OpenPos = 1; SawPosition = $true; NewRoundtrips = 0 }))) "open positions = 1"
    Assert-True "T4 not complete when terminal down" (-not (Test-RunComplete "4" (New-TestMon @{ OpenPos = -1; SawPosition = $true; NewRoundtrips = 1; SecSinceLastClose = 20 }))) "open positions = -1"
    $m2 = New-TestMon @{ OpenPos = 0; SawPosition = $true; HelperExited = $true; HelperExitCode = 0; NewOrphanSkips = 1 }
    Assert-True "T2 completes on helper exit 0 + 0 positions + orphan_external_close row" (Test-RunComplete "2" $m2) "no log line needed"
    Assert-True "T2 not complete without the orphan skip row" (-not (Test-RunComplete "2" (New-TestMon @{ OpenPos = 0; HelperExited = $true; HelperExitCode = 0; NewOrphanSkips = 0 }))) "row not flushed yet"
    Assert-True "T2 not complete when the helper failed" (-not (Test-RunComplete "2" (New-TestMon @{ OpenPos = 0; HelperExited = $true; HelperExitCode = 2; NewOrphanSkips = 1 }))) "exit code 2"
    $mm = New-RunMonitor
    $t0 = Get-Date
    foreach ($p in @(0, 1, 1, 0, 0, 1, -1, 1, 0)) { Update-RunMonitor $mm $p $t0 }
    Assert-True "monitor counts closes, ignores terminal-down polls" ($mm.Closes -eq 2 -and $mm.SawPosition) "closes=$($mm.Closes)"

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

    Write-Host "[SELFTEST 5] T5A / T5B completion and verdicts" -ForegroundColor Yellow
    $haltA = @("[FSM TRANSITION] STARTUP -> STATE_IDLE | Reason: Startup clean; ready in IDLE",
               "[ENTRY GATED] Equity drop 5.02 EUR >= 1.00 EUR stop (Baseline: 1005.90, Current: 1000.88)",
               "[FSM TRANSITION] STATE_IDLE -> STATE_HALTED | Reason: Equity drop 5.02 EUR >= 1.00 EUR stop")
    Assert-True "5A completes after the observation window with no position" (Test-RunComplete "5A" (New-TestMon @{ OpenPos = 0; ElapsedSec = $T5A_OBSERVE_SEC })) "$T5A_OBSERVE_SEC s"
    Assert-True "5A keeps observing before the window" (-not (Test-RunComplete "5A" (New-TestMon @{ OpenPos = 0; ElapsedSec = 10 }))) "10 s"
    Assert-True "5A halt reason is the equity drop (post-stop pattern)" ((Count-Matches $haltA $P_HALT_EQUITY) -eq 1) "pattern $P_HALT_EQUITY"
    Assert-True "5B not complete after 2 IDLE closes" (-not (Test-RunComplete "5B" (New-TestMon @{ OpenPos = 0; Closes = 2; NewRoundtrips = 2; SecSinceLastClose = 30 }))) "attempts 2/$T5B_MAX_ATTEMPTS"
    Assert-True "5B complete after $T5B_MAX_ATTEMPTS IDLE closes" (Test-RunComplete "5B" (New-TestMon @{ OpenPos = 0; Closes = 3; NewRoundtrips = 3; SecSinceLastClose = 1 })) "attempts 3/$T5B_MAX_ATTEMPTS"
    Assert-True "5B infers a halt: close without roundtrip row for $T5B_HALT_INFER_SEC s" (Test-RunComplete "5B" (New-TestMon @{ OpenPos = 0; Closes = 1; NewRoundtrips = 0; SecSinceLastClose = $T5B_HALT_INFER_SEC })) "HALTED queue not flushed"
    Assert-True "5B waits for the roundtrip row right after a close" (-not (Test-RunComplete "5B" (New-TestMon @{ OpenPos = 0; Closes = 1; NewRoundtrips = 0; SecSinceLastClose = 3 }))) "3 s after close"

    Write-Host "[SELFTEST 7] T1 [CRITICAL] Print lines vs Alert echo (2026-10-13 log lines)" -ForegroundColor Yellow
    $t1Lines = @("HK`t0`t12:03:03.734`tExecTest (EURUSD,M1)`t[CRITICAL] Exit failed 5 consecutive attempts for EURUSD (152757351239)! Retrying in 4000 ms...",
                 "DQ`t0`t12:03:03.734`tExecTest (EURUSD,M1)`tAlert: [CRITICAL] Exit failed 5 consecutive attempts for EURUSD (152757351239)! Retrying in 4000 ms...",
                 "IE`t0`t12:03:07.726`tExecTest (EURUSD,M1)`t[CRITICAL] Exit failed 6 consecutive attempts for EURUSD (152757351239)! Retrying in 5000 ms...")
    Assert-True "EA Print [CRITICAL] lines = 2" ((Count-Matches $t1Lines $P_CRITICAL) -eq 2) "got $(Count-Matches $t1Lines $P_CRITICAL) (old pattern: $(Count-Matches $t1Lines '\[CRITICAL\]'))"
    Assert-True "Alert echo lines = 1 = floor(6/5)" ((Count-Matches $t1Lines $P_ALERT_CRIT) -eq [Math]::Floor(6 / 5)) "got $(Count-Matches $t1Lines $P_ALERT_CRIT)"

    Write-Host "[SELFTEST 8] T2 evidence ends at the first IDLE after the external close" -ForegroundColor Yellow
    $t2Lines = @("a`t0`t12:06:11.189`tExecTest (EURUSD,M1)`t[ORDER SENT] USDJPY BUY retcode=10009 order=152757365343 deal=1",
                 "b`t0`t12:06:12.173`tExecTest (EURUSD,M1)`t[EXTERNAL CLOSE DETECTED] Position 152757365343 disappeared while in state 2!",
                 "c`t0`t12:06:12.173`tExecTest (EURUSD,M1)`t[FSM TRANSITION] STATE_IN_POSITION -> STATE_IDLE | Reason: External close reconciled",
                 "d`t0`t12:07:12.276`tExecTest (EURUSD,M1)`t[ORDER SENT] EURUSD BUY retcode=10009 order=152757367438 deal=2",
                 "e`t0`t12:08:15.304`tExecTest (EURUSD,M1)`t[ORDER SENT] EURUSD SELL retcode=10009 order=152757371344 deal=3")
    $cut = Limit-ToFirstIdleAfter $t2Lines $P_EXT_CLOSE
    $kept = @($t2Lines[0..$cut.Index])
    $j2 = @("x`t0`t12:06:11.165`tTrades`t'1': market buy 0.01 USDJPY", "y`t0`t12:06:12.143`tTrades`t'1': market sell 0.01 USDJPY, close #152757365343",
            "z`t0`t12:07:12.167`tTrades`t'1': market buy 0.01 EURUSD")
    $j2kept = @($j2 | Where-Object { $lt = Get-LogTime $_; (-not $lt) -or ($lt -le $cut.Time) })
    Assert-True "cut at the IDLE line" ($cut.Index -eq 2 -and $cut.Time -eq "12:06:12.173") "index=$($cut.Index) time=$($cut.Time)"
    Assert-True "second cycle excluded: 1 EA BUY, 0 EA SELL" ((Count-Matches $kept $P_BUY_SENT) -eq 1 -and (Count-Matches $kept $P_SELL_SENT) -eq 0) "BUY=$(Count-Matches $kept $P_BUY_SENT) SELL=$(Count-Matches $kept $P_SELL_SENT)"
    Assert-True "journal trimmed: 1 market buy, 1 market sell" ((Count-Matches $j2kept $P_J_BUY) -eq 1 -and (Count-Matches $j2kept $P_J_SELL) -eq 1) "buy=$(Count-Matches $j2kept $P_J_BUY) sell=$(Count-Matches $j2kept $P_J_SELL)"

    Write-Host "[SELFTEST 9] T6 entry = one distinct ticket across recovery / EA BUY / helper" -ForegroundColor Yellow
    $t6Log = @("q`t0`t12:29:01.458`tExecTest (EURUSD,M1)`t[RESTART RECOVERY] Recovered position 152757463860 (EURUSD). Open server time: 2026.10.13 13:28, Elapsed: 26 s")
    $t6Helper = @("[TEST_RESTART] Found position 152757463860 at 12:28:35. Waiting 20 seconds into 60s hold...")
    $e1 = Get-T6EntryTickets $t6Log $t6Helper
    $e2 = Get-T6EntryTickets $t6Log @()
    $e3 = Get-T6EntryTickets ($t6Log + @("r`t0`t12:29:40.000`tExecTest (EURUSD,M1)`t[ORDER SENT] EURUSD BUY retcode=10009 order=152757999999 deal=9")) $t6Helper
    Assert-True "recovery + helper agree -> 1 entry (2026-10-13 case: entry lines lost)" ($e1.Distinct.Count -eq 1) "distinct=$($e1.Distinct -join ',')"
    Assert-True "recovery ticket alone suffices" ($e2.Distinct.Count -eq 1) "distinct=$($e2.Distinct -join ',')"
    Assert-True "a second ticket is detected" ($e3.Distinct.Count -eq 2) "distinct=$($e3.Distinct -join ',')"
    $vCond = Resolve-Verdict $true 0 "drawdown never crossed in 3 attempts" 380
    $vFail = Resolve-Verdict $true 1 "drawdown never crossed in 3 attempts" 380
    $vTimeout = Resolve-Verdict $false 0 "" 600
    Assert-True "untriggered 5B is CONDITIONAL, not PASS" ($vCond -like "CONDITIONAL*") $vCond
    Assert-True "a failed check beats CONDITIONAL" ($vFail -eq "FAIL") $vFail
    Assert-True "timeout without note is FAIL" ($vTimeout -like "FAIL (timeout*") $vTimeout

    Write-Host "[SELFTEST 10] T5A seed: log off-by-one, marker-authoritative Ok, log line as cross-check only (run 3, 2026-10-14)" -ForegroundColor Yellow
    $r3Marker = "[SEED BASELINE] OK equity=1000.70 baseline=1005.70 offset=5.00 date_utc=1791936000 (2026.10.14) readback=1005.70/1791936000"
    $r3Pre = "FE`t0`t09:06:54.459`tExecTest (EURUSD,M1)`t[SHUTDOWN] ExecTest EA deinitialized (reason: 9)"
    $r3Seed = "RJ`t0`t09:07:03.937`tXTestSeedBaseline (EURUSD,M1)`t$r3Marker"
    $logTmp = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_selftest_" + [guid]::NewGuid().ToString("N") + ".log")
    [System.IO.File]::WriteAllText($logTmp, "$r3Pre`r`n", [System.Text.Encoding]::Unicode)
    $preL = @(Get-Utf16LogLines $logTmp)
    $oldPre = @([System.IO.File]::ReadAllText($logTmp, [System.Text.Encoding]::Unicode) -split "`r?`n")
    [System.IO.File]::AppendAllText($logTmp, "$r3Seed`r`n", [System.Text.Encoding]::Unicode)
    $postL = @(Get-Utf16LogLines $logTmp)
    $oldPost = @([System.IO.File]::ReadAllText($logTmp, [System.Text.Encoding]::Unicode) -split "`r?`n")
    Remove-Item $logTmp -Force
    $newL = @(Get-NewLines $preL $postL)
    $oldNew = @(Get-NewLines $oldPre $oldPost)
    $oldLogLine = $oldNew | Where-Object { $_ -match $P_SEED } | Select-Object -First 1
    Write-Host "    replay of the committed logic: pre.Count=$($oldPre.Count) post.Count=$($oldPost.Count) new=[$($oldNew -join ' | ')] logLine='$oldLogLine' marker='$r3Marker' eaStarted=$((Count-Matches $oldNew $P_INIT) -gt 0)"
    Assert-True "old split kept the trailing '' and hid the seed line (run-3 logAgrees=False)" ($oldPre.Count -eq 2 -and $oldNew.Count -eq 1 -and $oldNew[0] -eq "" -and -not $oldLogLine) "old new-lines = [$($oldNew -join ' | ')]"
    Assert-True "fixed reader returns the seed line as the one new line" ($preL.Count -eq 1 -and $newL.Count -eq 1 -and $newL[0] -eq $r3Seed) "new-lines = $($newL.Count)"
    Assert-True "empty file -> 0 lines" (@(Get-NewLines @() @()).Count -eq 0) "-"
    $expD = Get-UtcMidnightUnix ([datetime]::SpecifyKind([datetime]"2026-10-14 07:07:05", [DateTimeKind]::Utc))
    Assert-True "UTC midnight 2026-10-14 = 1791936000" ($expD -eq 1791936000) "$expD"
    $sOk = Test-SeedResult $r3Marker $expD $false 0 "graceful"
    Assert-True "run-3 seed is Ok without the log line" ($sOk.Ok) "$(@($sOk.Checks | Where-Object { -not $_.Pass } | ForEach-Object { $_.Check }) -join '; ')"
    Assert-True "fields parsed" ($sOk.Fields.Status -eq "OK" -and $sOk.Fields.Baseline -eq 1005.70 -and $sOk.Fields.Equity -eq 1000.70 -and $sOk.Fields.ReadbackDate -eq 1791936000) "baseline=$($sOk.Fields.Baseline) readback=$($sOk.Fields.ReadbackEquity)/$($sOk.Fields.ReadbackDate)"
    $lcAbsent = Compare-SeedLogLine $null $r3Marker
    $lcSame = Compare-SeedLogLine $r3Seed $r3Marker
    $lcDiff = Compare-SeedLogLine ($r3Seed -replace 'baseline=1005.70', 'baseline=1005.71') $r3Marker
    Assert-True "log line absent -> WARN only" (-not $lcAbsent.Agrees -and $lcAbsent.Warning -like "WARN:*") $lcAbsent.Warning
    Assert-True "log line equal -> agrees, no warning" ($lcSame.Agrees -and -not $lcSame.Warning) "agrees=$($lcSame.Agrees)"
    Assert-True "log line different -> WARN only" (-not $lcDiff.Agrees -and $lcDiff.Warning -like "WARN: Experts-log line differs*") "warning set"
    $neg = [ordered]@{
        "readback equity differs" = (Test-SeedResult ($r3Marker -replace 'readback=1005.70', 'readback=1004.70') $expD $false 0 "graceful")
        "readback date differs"   = (Test-SeedResult ($r3Marker -replace 'readback=1005.70/1791936000', 'readback=1005.70/1791849600') $expD $false 0 "graceful")
        "date_utc not today"      = (Test-SeedResult $r3Marker ($expD + 86400) $false 0 "graceful")
        "status FAILED"           = (Test-SeedResult ($r3Marker -replace '\] OK', '] FAILED') $expD $false 0 "graceful")
        "baseline unparsable"     = (Test-SeedResult ($r3Marker -replace 'baseline=1005.70', 'baseline=n/a') $expD $false 0 "graceful")
        "no marker"               = (Test-SeedResult $null $expD $false 0 "graceful")
        "ExecTest started"        = (Test-SeedResult $r3Marker $expD $true 0 "graceful")
        "journal order"           = (Test-SeedResult $r3Marker $expD $false 1 "graceful")
        "forced stop"             = (Test-SeedResult $r3Marker $expD $false 0 "forced")
    }
    foreach ($k in $neg.Keys) { Assert-True "seed not Ok: $k" (-not $neg[$k].Ok) "failed: $(@($neg[$k].Checks | Where-Object { -not $_.Pass } | ForEach-Object { $_.Check }) -join '; ')" }

    Write-Host "[SELFTEST 11] T6 gvariables.dat check: kill-time capture decides, poll is secondary (run 3, 2026-10-14)" -ForegroundColor Yellow
    $gK = [PSCustomObject]@{ Size = 1592; MTime = "09:18:40.100"; At = "09:18:41.302"; ExitAt = "09:18:41.290"; LagMs = 12; TerminalDown = $true }
    $gP = [PSCustomObject]@{ Size = 1592; MTime = "09:18:40.100"; At = "09:18:43.900" }
    $g1 = Test-GvDownCheck $gK $null
    $g2 = Test-GvDownCheck $null $gP
    $g3 = Test-GvDownCheck $null $null
    $g4 = Test-GvDownCheck ([PSCustomObject]@{ Size = 0; TerminalDown = $true }) $gP
    $g5 = Test-GvDownCheck ([PSCustomObject]@{ Size = 1592; TerminalDown = $false }) $null
    Assert-True "kill-time capture 1592 B, terminal down -> PASS" ($g1.Pass -and $g1.Source -eq "kill-time capture") $g1.Source
    Assert-True "no kill-time capture, poll 1592 B -> PASS via secondary" ($g2.Pass -and $g2.Source -like "terminal-down poll*") $g2.Source
    Assert-True "neither observed (run-3 case) -> FAIL" (-not $g3.Pass) $g3.Source
    Assert-True "kill-time capture 0 B -> FAIL (poll does not override)" (-not $g4.Pass) $g4.Source
    Assert-True "capture while a terminal64 runs is not terminal-down -> FAIL" (-not $g5.Pass) $g5.Source
    # The capture itself: WaitForExit wakes when a process is killed (stand-in process; no MT5)
    $victim = Start-Process -FilePath "$env:SystemRoot\System32\ping.exe" -ArgumentList "-n 30 127.0.0.1" -PassThru -WindowStyle Hidden
    $null = $victim.Handle
    $killAt = Get-Date
    Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList "/f /pid $($victim.Id)" -WindowStyle Hidden -Wait
    $woke = $victim.WaitForExit(3000)
    $wakeMs = [int]((Get-Date) - $killAt).TotalMilliseconds
    $vExit = $null; try { $vExit = $victim.ExitTime } catch {}
    Assert-True "WaitForExit returns right after taskkill /f, ExitTime readable" ($woke -and $wakeMs -lt 3000 -and $null -ne $vExit) "woke=$woke after ${wakeMs} ms from kill start; exit $(if ($vExit) { $vExit.ToString('HH:mm:ss.fff') } else { '-' })"

    Write-Host "[SELFTEST 12] -OnlyTests selection and EXECTEST_* detection in gvariables.dat" -ForegroundColor Yellow
    $selA = (Resolve-TestSelection @("T5A", "T6") $SuiteTestIds) -join ","
    $selB = (Resolve-TestSelection @("T5A,T6") $SuiteTestIds) -join ","
    $selC = (Resolve-TestSelection @("6", "t5a") $SuiteTestIds) -join ","
    $selD = (Resolve-TestSelection @() $SuiteTestIds) -join ","
    $selErr = $null; try { Resolve-TestSelection @("T7") $SuiteTestIds | Out-Null } catch { $selErr = $_.Exception.Message }
    Assert-True "-OnlyTests T5A,T6 (array) -> 5A,6" ($selA -eq "5A,6") $selA
    Assert-True "-OnlyTests 'T5A,T6' (one string via -File) -> 5A,6" ($selB -eq "5A,6") $selB
    Assert-True "suite order kept, prefix/case free" ($selC -eq "5A,6") $selC
    Assert-True "no -OnlyTests -> all tests" ($selD -eq ($SuiteTestIds -join ",")) $selD
    Assert-True "unknown id rejected" ($selErr -like "Unknown -OnlyTests id(s): 7*") $selErr
    $gvReal = $GvFile
    $GvFile = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_selftest_" + [guid]::NewGuid().ToString("N") + ".dat")
    $u = [System.Text.Encoding]::Unicode
    $bytes = @([byte]1, [byte]2) + $u.GetBytes("EXECTEST_CIRCUIT_BREAKER") + @([byte]0, [byte]0, [byte]7) + $u.GetBytes("EXECTEST_BASELINE_EQUITY") + @([byte]0, [byte]0)
    [System.IO.File]::WriteAllBytes($GvFile, [byte[]]$bytes)
    $names = Get-GvExecTestNames
    [System.IO.File]::WriteAllBytes($GvFile, [byte[]]($u.GetBytes("OTHER_GV") + @([byte]0, [byte]0)))
    $none = Get-GvExecTestNames
    Remove-Item $GvFile -Force
    $missing = Get-GvExecTestNames
    $GvFile = $gvReal
    Assert-True "names found at even and odd byte offsets" ((@($names) -join ",") -eq "EXECTEST_BASELINE_EQUITY,EXECTEST_CIRCUIT_BREAKER") "$(@($names) -join ',')"
    Assert-True "no EXECTEST_* -> empty array, not `$null" ($null -ne $none -and @($none).Count -eq 0) "null=$($null -eq $none)"
    Assert-True "missing file -> empty array" ($null -ne $missing -and @($missing).Count -eq 0) "null=$($null -eq $missing)"

    Write-Host "[SELFTEST 13] Entry-gate starvation is INVALID, entry stats, 1500 s / 1300 s timeouts (ICMarketsEU-Demo)" -ForegroundColor Yellow
    $skHdr = "timestamp_utc,session,symbol,reason,details,engine"
    $skStarved = @(@($skHdr,
        "2026-10-14 10:19:12.079,London,EURUSD,stale_tick,Tick age 8219.7 ms > 500 ms threshold,mql5",
        "2026-10-14 10:21:12.094,London,USDJPY,stale_tick,Tick age 2813.2 ms > 500 ms threshold,mql5",
        "2026-10-14 10:23:12.090,London,EURUSD,zero_spread,Reported spread is 0.00000 <= 0 (bid >= ask),mql5",
        "2026-10-14 10:25:12.088,London,USDJPY,stale_tick,Tick age 1548.6 ms > 500 ms threshold,mql5") | ConvertFrom-Csv)
    $sNone = Get-EntryStats $skStarved @() 0 @()
    $starvedNote = Resolve-EntryStarvation $true $sNone
    $vStarved = if ($starvedNote) { "INVALID ($starvedNote)" } else { Resolve-Verdict $false 5 "" 1500 }
    Write-Host "    starved T1: $(Format-EntryStats $sNone)"
    Write-Host "    verdict:    $vStarved"
    Assert-True "no entry + 4 gate skips -> INVALID (entry gate starved), not FAIL" ($vStarved -like "INVALID (entry gate starved: 4 attempt(s), 0 entries; skips zero_spread=1, stale_tick=3, other=0)") $vStarved
    Assert-True "starved stats: attempts 4, entries 0, first entry -" ($sNone.Attempts -eq 4 -and $sNone.Entries -eq 0 -and $null -eq $sNone.AttemptsToFirstEntry) "attempts=$($sNone.Attempts)"
    $buy = @(@("timestamp_utc,side,comment", "2026-10-14 10:27:12.301,BUY,") | ConvertFrom-Csv)
    $s1 = Get-EntryStats $skStarved $buy 1 @()
    Assert-True "entry after 4 skips -> attempts 5, first entry at attempt 5" ($s1.Attempts -eq 5 -and $s1.AttemptsToFirstEntry -eq 5 -and $s1.FirstEntrySource -like "skips.csv*") (Format-EntryStats $s1)
    Assert-True "an entry with missing evidence stays a normal verdict (FAIL)" ($null -eq (Resolve-EntryStarvation $true $s1) -and (Resolve-Verdict $true 2 "" 300) -eq "FAIL") "starvation=$(Resolve-EntryStarvation $true $s1)"
    $sZero = Get-EntryStats @() @() 0 @()
    Assert-True "no attempt at all (EA never cycled) is a real failure, not starvation" ($null -eq (Resolve-EntryStarvation $true $sZero)) "gate skips 0"
    Assert-True "T5A (NeedsEntry=false) with skips is never starved" ($null -eq (Resolve-EntryStarvation $false $sNone)) "5A expects 0 entries"
    $skMixed = @(@($skHdr,
        "2026-10-14 10:19:12.000,London,EURUSD,market_closed,Forex market is closed for weekend,mql5",
        "2026-10-14 10:21:12.000,London,USDJPY,no_tick,SymbolInfoTick returned invalid or zero quote,mql5",
        "2026-10-14 10:22:00.000,London,EURUSD,orphan_external_close,External close,mql5") | ConvertFrom-Csv)
    $sMix = Get-EntryStats $skMixed @() 0 @()
    Assert-True "other = market_closed + no_tick; orphan_external_close is not an attempt" ($sMix.Attempts -eq 2 -and $sMix.Other -eq 2 -and $sMix.OtherReasons -eq "market_closed=1, no_tick=1") (Format-EntryStats $sMix)
    $logT6 = @("a`t0`t10:19:12.000`tExecTest (EURUSD,M1)`t[CYCLE TRIGGER] Initiating round-trip probe on EURUSD...",
               "b`t0`t10:21:12.000`tExecTest (EURUSD,M1)`t[CYCLE TRIGGER] Initiating round-trip probe on USDJPY...",
               "c`t0`t10:21:12.050`tExecTest (EURUSD,M1)`t[ORDER SENT] USDJPY BUY retcode=10009 order=1 deal=1")
    $sLog = Get-EntryStats @($skStarved[0]) @() 1 $logT6
    Assert-True "no BUY row (T6 killed instance): first entry from the log, attempt 2" ($sLog.AttemptsToFirstEntry -eq 2 -and $sLog.FirstEntrySource -like "log*") (Format-EntryStats $sLog)
    $timed = @($AllTests | Where-Object { $_.Num -ne "3B" })
    Assert-True "T1, T2, T3A, T4, T5A, T5B, T6 timeout = 1500 s" (@($timed | Where-Object { $_.Timeout -ne 1500 }).Count -eq 0 -and $timed.Count -eq 7) (($timed | ForEach-Object { "T$($_.Num)=$($_.Timeout)" }) -join " ")
    $ecSrc = Get-Content $ExternalClosePy -Raw
    $trSrc = Get-Content $TestRestartPy -Raw
    $ecT = if ($ecSrc -match '(?m)^TIMEOUT_SEC\s*=\s*(\d+)') { [int]$Matches[1] } else { -1 }
    $ecDry = if ($ecSrc -match 'poll_timeout\s*=\s*(\d+)\s+if is_dry_run else TIMEOUT_SEC') { [int]$Matches[1] } else { -1 }
    $trT = if ($trSrc -match 'poll_timeout\s*=\s*(\d+)\s+if is_dry_run else\s+(\d+)') { @([int]$Matches[1], [int]$Matches[2]) } else { @(-1, -1) }
    Assert-True "external_close.py TIMEOUT_SEC = $HelperPollTimeoutSec, DryRun 2 s" ($ecT -eq $HelperPollTimeoutSec -and $ecDry -eq 2) "TIMEOUT_SEC=$ecT dry=$ecDry"
    Assert-True "test_restart.py poll_timeout = $HelperPollTimeoutSec, DryRun 2 s" ($trT[1] -eq $HelperPollTimeoutSec -and $trT[0] -eq 2) "poll_timeout=$($trT[1]) dry=$($trT[0])"
    # T6 worst case after the helper's last chance: 20 s into the hold + kill + 3 s + relaunch 10 s, ~40 s of
    # remaining hold, exit + roundtrip row (30 s); the helper starts after the EA init line (~5 s typical).
    $t6Budget = 5 + $HelperPollTimeoutSec + 20 + 3 + 10 + 40 + 30
    Assert-True "test timeout covers the helper wait + T6 restart tail" ($TestTimeoutSec -ge $t6Budget) "$TestTimeoutSec s >= $t6Budget s"
    $attemptsInHelper = [Math]::Floor(($HelperPollTimeoutSec - 5) / 120) + 1
    Assert-True "helper wait spans ~10 entry attempts (5 s + k x 120 s)" ($attemptsInHelper -ge 10) "$attemptsInHelper attempts"

    Write-Host "[SELFTEST 6] Get-Utf16LogLines logs read errors instead of swallowing them" -ForegroundColor Yellow
    $lockFile = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_selftest_" + [guid]::NewGuid().ToString("N") + ".log")
    [System.IO.File]::WriteAllText($lockFile, "line", [System.Text.Encoding]::Unicode)
    $holder = [System.IO.File]::Open($lockFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    $errsBefore = $script:LogReadErrors
    $locked = @(Get-Utf16LogLines $lockFile)
    $holder.Close()
    $unlocked = @(Get-Utf16LogLines $lockFile)
    Remove-Item $lockFile -Force
    Assert-True "locked log counted as a read error" ($script:LogReadErrors -eq $errsBefore + 1 -and $locked.Count -eq 0) "errors $errsBefore -> $($script:LogReadErrors)"
    Assert-True "readable log returns its lines" ($unlocked.Count -ge 1 -and $unlocked[0] -match "line") "lines=$($unlocked.Count)"

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
        "$PresetsDir\smoke6a.ini", "$PresetsDir\smoke6a.set",
        "$PresetsDir\seed_baseline.ini",
        "$PresetsDir\restart.ini", "$PresetsDir\restart.set",
        "$PresetsDir\default.ini", "$PresetsDir\default.set",
        $SeedScriptSource, $SeedScriptBinary,
        $ClearGvSource, $ClearGvBinary
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
    # restart.set: T6 recovers from persisted state. smoke6a.set: a reset would wipe the seeded T5A baseline.
    foreach ($s in @("restart.set", "default.set", "smoke6a.set")) {
        if ((Get-SetValue "$PresetsDir\$s" "InpResetState" "false") -ne "false") {
            throw "Hard Precondition Failed: $s must set InpResetState=false"
        }
    }
    if ((Get-Item $SeedScriptBinary).LastWriteTime -lt (Get-Item $SeedScriptSource).LastWriteTime) {
        throw "Hard Precondition Failed: $SeedScriptBinary is older than $SeedScriptSource. Recompile and deploy the script first."
    }
    if ((Get-Item $ClearGvBinary).LastWriteTime -lt (Get-Item $ClearGvSource).LastWriteTime) {
        throw "Hard Precondition Failed: $ClearGvBinary is older than $ClearGvSource. Recompile and deploy the script first."
    }
    # A saved chart profile that carries ExecTest would start a second, unconfigured instance on every plain
    # launch (the T5A seed launch loads no Expert of its own). Refuse to run rather than rely on the lock.
    $profileHits = @(Get-ChildItem "$TerminalDataDir\MQL5\Profiles\Charts" -Recurse -Filter "*.chr" -ErrorAction SilentlyContinue |
        Where-Object { (Get-Content $_.FullName -Encoding Unicode -ErrorAction SilentlyContinue) -match "^name=ExecTest" })
    if ($profileHits.Count -gt 0) {
        throw "Hard Precondition Failed: saved chart profile(s) carry ExecTest: $(($profileHits | ForEach-Object { $_.FullName }) -join ', '). Remove the EA from those charts first."
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

    $Tests = @($AllTests | Where-Object { $SelectedTestIds -contains $_.Num })

    # -------------------------------------------------------------------------
    # Dry Run Mode Handling
    # -------------------------------------------------------------------------
    if ($Mode -eq "DryRun") {
        Write-Host "[DRY RUN] Verifying helper scripts execution with --dry-run..." -ForegroundColor Yellow
        python "$ExternalClosePy" --dry-run
        if ($LASTEXITCODE -ne 0) { throw "external_close.py dry run failed" }
        python "$TestRestartPy" --dry-run
        if ($LASTEXITCODE -ne 0) { throw "test_restart.py dry run failed" }
        Write-Host "[DRY RUN] Test plan ($($Tests.Count) of $($AllTests.Count)):" -ForegroundColor Yellow
        foreach ($t in $Tests) {
            $steps = @()
            if ($t.Clean) { $steps += "ClearGV" }
            if ($t.Seed) { $steps += "seed $($t.Seed)" }
            if ($t.Ini) { $steps += "$($t.Ini) -> $(Split-Path -Leaf (Get-IniSetFile "$PresetsDir\$($t.Ini)"))" } else { $steps += "not testable" }
            if ($t.Helper) { $steps += "helper $(Split-Path -Leaf $t.Helper)" }
            Write-Host ("  T{0,-3} {1,-55} timeout {2,3}s | {3}" -f $t.Num, $t.Name, $t.Timeout, ($steps -join " | "))
        }
        Write-Host "[DRY RUN] Helper scripts verified cleanly. Pre-flight complete." -ForegroundColor Green
        return
    }

    # -------------------------------------------------------------------------
    # Attended Test Suite Execution
    # -------------------------------------------------------------------------
    $StartUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd HH:mm:ss")
    Write-Host "`n>>> Starting Attended Smoke Test Suite at $StartUtc UTC ($($Tests.Count) of $($AllTests.Count) tests: $(($Tests | ForEach-Object { "T$($_.Num)" }) -join ', ')) <<<`n" -ForegroundColor Yellow

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
        $script:LogReadErrors = 0

        $warnings = [System.Collections.ArrayList]::new()

        # 1a. T5A / T6: clean EXECTEST_* state (a tripped circuit breaker from an earlier halt would block entries)
        $clean = $null
        if ($t.Clean) {
            $clean = Invoke-ClearExecTestState
            Write-Host ("  [CLEAN] ok={0} launched={1} before=[{2}] after=[{3}] orders={4} ea_started={5} stop={6} | {7}" -f $clean.Ok, $clean.Launched,
                        ($clean.Before -join ','), ($clean.After -join ','), $clean.Orders, $clean.EaStarted, $clean.Stop, $(if ($clean.Summary) { (($clean.Summary -split "`t", 5)[-1]) } else { "-" })) `
                        -ForegroundColor $(if ($clean.Ok) { "Gray" } else { "Red" })
            if ($clean.Warning) { $warnings.Add($clean.Warning) | Out-Null; Write-Host "  [CLEAN] $($clean.Warning)" -ForegroundColor DarkYellow }
            if (-not $clean.Ok) {
                $Results.Add([PSCustomObject]@{
                    Test = "Test $tNum ($tName)"
                    Verdict = "INVALID"
                    Summary = "Clean-state step failed: EXECTEST_* left on disk [$($clean.After -join ',')], journal orders $($clean.Orders), ExecTest started $($clean.EaStarted), stop $($clean.Stop)"
                    StaleTickBackoffs = "N/A"
                    Checks = @()
                    Clean = $clean
                }) | Out-Null
                continue
            }
        }

        # 1b. T5A: seed the daily baseline above current equity with a script-only launch
        $seed = $null
        if ($t.Seed) {
            $seed = Invoke-SeedBaseline "$PresetsDir\$($t.Seed)"
            $sf = $seed.Fields
            Write-Host ("  [SEED] ok={0} status={1} equity={2} baseline={3} offset={4} date_utc={5} (expected {6}) readback={7}/{8} ea_started={9} orders={10} stop={11} script_loaded={12} log_agrees={13}" -f `
                        $seed.Ok, $sf.Status, $sf.Equity, $sf.Baseline, $sf.Offset, $sf.DateUtc, $seed.ExpectedDateUtc, $sf.ReadbackEquity, $sf.ReadbackDate,
                        $seed.EaStarted, $seed.Orders, $seed.Stop, $seed.ScriptLoaded, $seed.LogAgrees) -ForegroundColor $(if ($seed.Ok) { "Gray" } else { "Red" })
            Write-Host "  [SEED] marker: $(if ($seed.Line) { $seed.Line } else { '(none)' })" -ForegroundColor Gray
            Write-Host "  [SEED] log:    $(if ($seed.LogLine) { $seed.LogLine -replace "`t", ' | ' } else { '(none)' })" -ForegroundColor Gray
            foreach ($c in $seed.Checks) {
                Write-Host ("    [{0}] {1}: expected {2}, observed {3}" -f $(if ($c.Pass) { "ok  " } else { "FAIL" }), $c.Check, $c.Expected, $c.Observed) -ForegroundColor $(if ($c.Pass) { "Gray" } else { "Red" })
            }
            if ($seed.Warning) { $warnings.Add($seed.Warning) | Out-Null; Write-Host "  [SEED] $($seed.Warning)" -ForegroundColor DarkYellow }
            if (-not $seed.Ok) {
                $failedSeed = @($seed.Checks | Where-Object { -not $_.Pass } | ForEach-Object { "$($_.Check) (expected $($_.Expected), observed $($_.Observed))" })
                $Results.Add([PSCustomObject]@{
                    Test = "Test $tNum ($tName)"
                    Verdict = "INVALID"
                    Summary = "Baseline seed step failed: $($failedSeed -join '; ')"
                    StaleTickBackoffs = "N/A"
                    Checks = @($seed.Checks)
                    Warnings = @($warnings)
                    Seed = $seed
                }) | Out-Null
                continue
            }
        }

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
        $null = $proc.Handle   # cache the handle: WaitForExit / ExitTime after the T6 taskkill need it on PowerShell 5.1

        # 4. Hard Precondition: Verify EA Initialization Line in Log
        #    Each poll records the Experts-log size and mtime, so a timeout can tell "the EA never initialized"
        #    from "the terminal had not flushed its log yet".
        Write-Host "[CHECK] Polling MQL5 log for EA OnInit line (up to ${InitTimeoutSec}s)..." -ForegroundColor Yellow
        $mql5LogPath = "$TerminalDataDir\MQL5\Logs\$((Get-Date).ToString('yyyyMMdd')).log"
        $initTrace = [System.Collections.ArrayList]::new()
        $eaInitialized = $false
        $initDeadline = (Get-Date).AddSeconds($InitTimeoutSec)
        while ((Get-Date) -lt $initDeadline) {
            Start-Sleep -Milliseconds 500
            $fi = Get-Item $mql5LogPath -ErrorAction SilentlyContinue
            $initTrace.Add([PSCustomObject]@{
                At    = (Get-Date).ToString("HH:mm:ss.fff")
                Size  = $(if ($fi) { $fi.Length } else { -1 })
                MTime = $(if ($fi) { $fi.LastWriteTime.ToString("HH:mm:ss.fff") } else { "-" })
            }) | Out-Null
            $newLines = @(Get-NewLines $preLogLines (Get-Mql5LogLines))
            $initLine = $newLines | Where-Object { $_ -match $P_INIT -or $_ -match "\[SAFETY VERIFIED\]" } | Select-Object -First 1
            if ($initLine) {
                $eaInitialized = $true
                Write-Host "  [EA INIT CONFIRMED] $initLine ($($initTrace.Count) polls)" -ForegroundColor Green
                break
            }
        }

        if (-not $eaInitialized) {
            Write-Host "[ERROR] EA init line NOT FOUND within ${InitTimeoutSec}s. Stopping the terminal and re-reading the log from disk..." -ForegroundColor Red
            $stopAfterInit = Stop-Terminal
            $afterStop = @(Get-NewLines $preLogLines (Get-Mql5LogLines))
            $onDisk = $afterStop | Where-Object { $_ -match $P_INIT -or $_ -match "\[SAFETY VERIFIED\]" } | Select-Object -First 1
            $sizes = @($initTrace | ForEach-Object { $_.Size } | Select-Object -Unique)
            $first = $initTrace[0]; $last = $initTrace[$initTrace.Count - 1]
            $detail = "No EA init line in ${InitTimeoutSec}s of polling ($($initTrace.Count) polls). After Stop-Terminal ($stopAfterInit) " +
                      $(if ($onDisk) { "the init line IS on disk (log not flushed during the poll): $onDisk" } else { "the init line is NOT on disk (EA never initialized)" }) +
                      ". Log size/mtime first $($first.Size) B @ $($first.MTime), last $($last.Size) B @ $($last.MTime), $($sizes.Count) distinct size(s); log read errors: $($script:LogReadErrors)."
            Write-Host "  $detail" -ForegroundColor Red
            $Results.Add([PSCustomObject]@{
                Test = "Test $tNum ($tName)"
                Verdict = "INVALID"
                Summary = $detail
                StaleTickBackoffs = "N/A"
                Checks = @()
                InitTrace = @($initTrace)
            }) | Out-Null
            continue
        }

        # 5. Start Helper Script if applicable
        $helperProc = $null
        $helperOutFile = $null
        $gvBefore = $null
        $gvAtKill = $null       # primary: captured the moment the killed terminal64 process is signalled
        $gvAtPoll = $null       # secondary: first 3 s poll that saw no terminal (often misses the ~3 s gap)
        $gvAfter = $null
        if ($tNum -eq "6") { $gvBefore = Get-GvFileSnapshot }
        if ($t.Helper) {
            Write-Host "[HELPER] Launching helper script $($t.Helper)..." -ForegroundColor Yellow
            $helperOutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("xtest_helper_${tNum}_" + [guid]::NewGuid().ToString("N") + ".out")
            $helperProc = Start-Process python -ArgumentList "`"$($t.Helper)`"" -PassThru -NoNewWindow `
                              -RedirectStandardOutput $helperOutFile -RedirectStandardError "$helperOutFile.err"
            $null = $helperProc.Handle   # cache the handle: without it PowerShell 5.1 can report ExitCode as $null
        }

        # 6. Test Monitoring Loop: live signals only (API positions, CSV rows, helper exit, time); see Test-RunComplete
        $timeoutSec = $t.Timeout
        $deadline = $testStartTime.AddSeconds($timeoutSec)
        $completedCleanly = $false
        $mon = New-RunMonitor
        $monTrace = [System.Collections.ArrayList]::new()

        while ((Get-Date) -lt $deadline) {
            if ($tNum -eq "6" -and $null -eq $gvAtKill) {
                # test_restart.py runs taskkill /f and relaunches 3 s later; the 3 s poll below missed that gap in
                # run 3 (2026-10-14). The first instance's process handle is signalled when taskkill returns, so
                # WaitForExit wakes within milliseconds and the snapshot is taken before any other work.
                if ($proc.WaitForExit(3000)) { $gvAtKill = Get-GvKillSnapshot $proc }
            } else {
                Start-Sleep -Seconds 3
            }

            $now = Get-Date
            Update-RunMonitor $mon (Check-OpenPositions) $now
            $mon.HelperExited = [bool]($helperProc -and $helperProc.HasExited)
            $mon.HelperExitCode = if ($mon.HelperExited) { $helperProc.ExitCode } else { $null }
            $mon.ElapsedSec = ($now - $testStartTime).TotalSeconds
            $mon.NewRoundtrips = @(Get-NewCsvObjects $preRoundtripsLines (Get-CsvLines $roundtripsCsvPath)).Count
            $mon.NewOrphanSkips = @(Get-NewCsvObjects $preSkipsLines (Get-CsvLines $skipsCsvPath) | Where-Object { $_.reason -eq "orphan_external_close" }).Count
            if ($tNum -eq "6" -and $mon.OpenPos -eq -1 -and $null -eq $gvAtPoll) { $gvAtPoll = Get-GvFileSnapshot }

            $logFi = Get-Item $mql5LogPath -ErrorAction SilentlyContinue
            $monTrace.Add([PSCustomObject]@{
                At = $now.ToString("HH:mm:ss.fff"); OpenPos = $mon.OpenPos; Closes = $mon.Closes
                NewRoundtrips = $mon.NewRoundtrips; NewOrphanSkips = $mon.NewOrphanSkips
                Helper = $(if ($mon.HelperExited) { "exit $($mon.HelperExitCode)" } elseif ($helperProc) { "running" } else { "-" })
                LogSize = $(if ($logFi) { $logFi.Length } else { -1 }); LogMTime = $(if ($logFi) { $logFi.LastWriteTime.ToString("HH:mm:ss.fff") } else { "-" })
            }) | Out-Null

            # A failed helper (exit 2 = no position within $HelperPollTimeoutSec s) cannot complete the test: stop waiting
            if ($mon.HelperExited -and $mon.HelperExitCode -ne 0) { break }

            # Single predicate shared with -Mode SelfTest
            if (Test-RunComplete $tNum $mon) {
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
                # Post-stop entry statistics: exit 2 after $HelperPollTimeoutSec s with only gate skips = starved, not a harness fault
                $hfLog = @(Get-NewLines $preLogLines (Get-Mql5LogLines))
                $hfJournal = @(Get-NewLines $preJournalLines (Get-JournalLines))
                $hfSkips = @(Get-NewCsvObjects $preSkipsLines (Get-CsvLines $skipsCsvPath))
                $hfBuys = @(Get-NewCsvObjects $preTradesLines (Get-CsvLines $tradesCsvPath) | Where-Object { $_.side -eq "BUY" })
                $hfEntries = [Math]::Max([Math]::Max((Count-Matches $hfLog $P_BUY_SENT), (Count-Matches $hfJournal $P_J_BUY)), $hfBuys.Count)
                $hfStats = Get-EntryStats $hfSkips $hfBuys $hfEntries $hfLog
                $hfStarved = Resolve-EntryStarvation ([bool]$t.NeedsEntry) $hfStats
                Write-Host "    [ENTRY STATS] $(Format-EntryStats $hfStats)" -ForegroundColor $(if ($hfStarved) { "Yellow" } else { "Gray" })
                $hfSummary = "Helper exited with code $($helperProc.ExitCode) after ${elapsedSec}s" + $(if ($hfStarved) { "; $hfStarved" } else { "" })
                Write-Host ">>> TEST ${tNum} VERDICT: INVALID ($hfSummary) <<<" -ForegroundColor Red
                $Results.Add([PSCustomObject]@{
                    Test = "Test $tNum ($tName)"
                    Verdict = $(if ($hfStarved) { "INVALID ($hfStarved)" } else { "INVALID" })
                    Summary = $hfSummary
                    StaleTickBackoffs = "N/A"
                    Checks = @()
                    EntryStats = $hfStats
                    Warnings = @($warnings)
                    MonitorTrace = @($monTrace)
                }) | Out-Null
                continue
            }
        }

        if ($tNum -eq "6") { $gvAfter = Get-GvFileSnapshot }
        $helperOut = @()
        if ($helperOutFile -and (Test-Path $helperOutFile)) { $helperOut = @(Get-Content $helperOutFile -ErrorAction SilentlyContinue) }

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

        $newTradesObjs = @(Get-NewCsvObjects $preTradesLines $postTradesLines)
        $newRoundtripsObjs = @(Get-NewCsvObjects $preRoundtripsLines $postRoundtripsLines)
        $newSkipsObjs = @(Get-NewCsvObjects $preSkipsLines $postSkipsLines)

        Write-Host "  Evidence collected: $($testLogLines.Count) EA log lines, $($testJournal.Count) journal lines, $($newTradesObjs.Count) trade rows, $($newRoundtripsObjs.Count) roundtrips, $($newSkipsObjs.Count) skips." -ForegroundColor Cyan

        # T2: the evidence window ends at the first "-> STATE_IDLE" after the external close; later cycles (the
        # 2026-10-13 run opened and closed a second position at 12:07:12-12:08:15) are not part of the test.
        $t2Cut = $null
        if ($tNum -eq "2") {
            $t2Cut = Limit-ToFirstIdleAfter $testLogLines $P_EXT_CLOSE
            if ($t2Cut.Index -ge 0) {
                $testLogLines = @($testLogLines[0..$t2Cut.Index])
                if ($t2Cut.Time) { $testJournal = @($testJournal | Where-Object { $lt = Get-LogTime $_; (-not $lt) -or ($lt -le $t2Cut.Time) }) }
                Write-Host "  [T2] Evidence window ends at the first IDLE after the external close: $($t2Cut.Time)" -ForegroundColor Gray
            }
        }

        # Tag counts shared by all tests
        $eaBuy       = Count-Matches $testLogLines $P_BUY_SENT
        $eaSell      = Count-Matches $testLogLines $P_SELL_SENT
        $jBuy        = Count-Matches $testJournal $P_J_BUY
        $jSell       = Count-Matches $testJournal $P_J_SELL
        $injRejects  = Count-Matches $testLogLines $P_INJ_REJECT
        $injTimeouts = Count-Matches $testLogLines $P_INJ_TIMEOUT
        $exitRetry   = Count-Matches $testLogLines $P_EXIT_RETRY
        $critical    = Count-Matches $testLogLines $P_CRITICAL
        $alertCrit   = Count-Matches $testLogLines $P_ALERT_CRIT
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
        $expectReset = [int]((Get-SetValue $setPath "InpResetState" "false") -eq "true")
        $conditionalNote = ""
        Add-Check $checks "No duplicate EA instance refused" 0 $dupRefused ($dupRefused -eq 0)
        Add-Check $checks "No OnTimer stall > 1 s" 0 $stalls ($stalls -eq 0)
        Add-Check $checks "No log/CSV read errors" 0 $script:LogReadErrors ($script:LogReadErrors -eq 0)
        Add-Check $checks "Final open positions" 0 $finalOpenPos ($finalOpenPos -eq 0)
        Add-Check $checks "[STATE RESET] Cleared lines == preset InpResetState" $expectReset $resetOk ($resetOk -eq $expectReset)
        Add-Check $checks "Injected close rejects == preset InpInjectCloseReject" $expectedRejects $injRejects ($injRejects -eq $expectedRejects)
        Add-Check $checks "Injected timeouts == preset InpInjectTimeout" ([int]$expectedTimeout) $injTimeouts ($injTimeouts -eq [int]$expectedTimeout)
        if ($null -ne $t.ExpectEntries) {
            Add-Check $checks "Entry dispatches (EA [ORDER SENT] BUY)" $t.ExpectEntries $eaBuy ($eaBuy -eq $t.ExpectEntries)
            Add-Check $checks "Entry dispatches (journal market buy)" $t.ExpectEntries $jBuy ($jBuy -eq $t.ExpectEntries)
        }

        switch ($tNum) {
            "1" {
                $expRetry = [Math]::Min($expectedRejects, 4)
                $expCrit = [Math]::Max(0, $expectedRejects - 4)
                Add-Check $checks "close_failure rows tagged fault_injection" $expectedRejects $injectedRows.Count ($injectedRows.Count -eq $expectedRejects)
                Add-Check $checks "[EXIT RETRY] lines (attempts 1-4)" $expRetry $exitRetry ($exitRetry -eq $expRetry)
                Add-Check $checks "[CRITICAL] EA Print lines (attempts >= 5)" $expCrit $critical ($critical -eq $expCrit)
                # The EA raises Alert() on every 5th consecutive failure (attempts 5, 10, ...): N=6 -> exactly 1 echo
                $expAlert = [int][Math]::Floor($expectedRejects / 5)
                Add-Check $checks "Alert: [CRITICAL] echoes (every 5th failure)" $expAlert $alertCrit ($alertCrit -eq $expAlert)
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

            "5A" {
                # Deterministic: the seeded baseline (equity + offset) is loaded at init, so the first entry-gate
                # pass sees an equity drop >= InpMaxDrawdownEUR and halts before any order (zero entries is a
                # common check via ExpectEntries = 0).
                $baseLine = $testLogLines | Where-Object { $_ -match $P_BASE_LOADED } | Select-Object -First 1
                $baseLoaded = $null
                if ($baseLine -and $baseLine -match $P_BASE_LOADED) { $baseLoaded = [double]$Matches[1] }
                $idxHalt = First-Index $testLogLines $P_HALT
                foreach ($c in $seed.Checks) { $checks.Add($c) | Out-Null }
                Add-Check $checks "EA loaded the seeded baseline" "$($seed.Baseline) EUR" $(if ($null -ne $baseLoaded) { "$baseLoaded EUR" } else { "not loaded" }) ($null -ne $baseLoaded -and [Math]::Abs($baseLoaded - $seed.Baseline) -lt 0.01)
                Add-Check $checks "STATE_HALTED with reason 'Equity drop'" ">=1" (Count-Matches $testLogLines $P_HALT_EQUITY) ((Count-Matches $testLogLines $P_HALT_EQUITY) -ge 1)
                Add-Check $checks "No entry dispatch after the halt" 0 (Count-MatchesAfter $testLogLines $P_BUY_SENT $idxHalt) ($idxHalt -ge 0 -and (Count-MatchesAfter $testLogLines $P_BUY_SENT $idxHalt) -eq 0)
                Add-Check $checks "No BUY rows in trades.csv" 0 $buyRows.Count ($buyRows.Count -eq 0)
            }

            "5B" {
                # Market-dependent: the baseline is the equity at init (InpResetState=true) and InpMaxDrawdownEUR is
                # 0.001, so a halt needs a losing round trip. The exit path is never gated: the position is held to
                # expiry, closed, and only then does the post-close check halt. Up to $T5B_MAX_ATTEMPTS attempts.
                $idxHalt = First-Index $testLogLines $P_HALT
                $closes = Count-Matches $testLogLines $P_EXIT_OK
                $idleCloses = Count-Matches $testLogLines $P_CLOSE_IDLE
                Add-Check $checks "Entry dispatches agree (EA tag vs journal)" $eaBuy $jBuy ($eaBuy -eq $jBuy)
                Add-Check $checks "Entries <= $T5B_MAX_ATTEMPTS attempts" "<= $T5B_MAX_ATTEMPTS" $eaBuy ($eaBuy -le $T5B_MAX_ATTEMPTS)
                Add-Check $checks "Every entry was closed ([EXIT CONFIRMED] == entries)" $eaBuy $closes ($closes -eq $eaBuy)
                if ($idxHalt -ge 0) {
                    # Only meaningful when a halt occurred (the old unconditional SELL-vs-HALT check was vacuous otherwise)
                    $idxLastSellBeforeHalt = -1
                    for ($i = $idxHalt - 1; $i -ge 0; $i--) { if ($testLogLines[$i] -match $P_SELL_SENT) { $idxLastSellBeforeHalt = $i; break } }
                    $buyAfterHalt = Count-MatchesAfter $testLogLines $P_BUY_SENT $idxHalt
                    Add-Check $checks "Position liquidated before the halt (a SELL precedes the HALT line)" "< $idxHalt" $idxLastSellBeforeHalt ($idxLastSellBeforeHalt -ge 0)
                    Add-Check $checks "Halt raised by the post-close check" ">=1" (Count-Matches $testLogLines '\[TRADING HALTED AFTER CLOSE\]') ((Count-Matches $testLogLines '\[TRADING HALTED AFTER CLOSE\]') -ge 1)
                    Add-Check $checks "No entry dispatch after the halt" 0 $buyAfterHalt ($buyAfterHalt -eq 0)
                } else {
                    $conditionalNote = "drawdown stop never triggered: $idleCloses of $T5B_MAX_ATTEMPTS attempts closed without crossing InpMaxDrawdownEUR" +
                                       $(if (-not $completedCleanly) { "; timed out after ${elapsedSec}s" } else { "" })
                }
            }

            "6" {
                # Two instances: the initial one is killed with taskkill /f (its Experts-log and journal tail can
                # be lost), the relaunch is stopped gracefully. Entry evidence is the max over the independent sources.
                $idxRecovery = First-Index $testLogLines $P_RESTART
                $buyAfterRecovery = Count-MatchesAfter $testLogLines $P_BUY_SENT $idxRecovery
                $sellAfterRecovery = Count-MatchesAfter $testLogLines $P_SELL_SENT $idxRecovery
                $entryTickets = Get-T6EntryTickets $testLogLines $helperOut
                $priorInPos = Count-Matches $testLogLines "\[RESTART RECOVERY\].*prior state: STATE_IN_POSITION"
                $rtRestart = @($newRoundtripsObjs | Where-Object { $_.restart -eq "True" })
                # restart.set has InpResetState=false for both instances: no reset may run at all
                Add-Check $checks "No [STATE RESET] line (restart.set InpResetState=false)" 0 ($resetOk + $resetSkip) (($resetOk + $resetSkip) -eq 0)
                Add-Check $checks "[RESTART RECOVERY] emitted" ">=1" $restartRec ($restartRec -ge 1)
                Add-Check $checks "Zero [ORPHAN DETECTED]" 0 $orphanDet ($orphanDet -eq 0)
                Add-Check $checks "Recovery saw prior state STATE_IN_POSITION" ">=1" $priorInPos ($priorInPos -ge 1)
                # One distinct ticket across: recovered ticket OR surviving entry line OR helper-detected position.
                # (2026-10-13: the killed instance lost its entry lines and journal tail; the recovery ticket survived.)
                $srcText = ($entryTickets.Sources.Keys | ForEach-Object { "${_}=[$($entryTickets.Sources[$_] -join ',')]" }) -join " "
                Add-Check $checks "Exactly one entry (distinct ticket: recovery / EA BUY / helper)" 1 "$($entryTickets.Distinct.Count) ($srcText)" ($entryTickets.Distinct.Count -eq 1)
                Add-Check $checks "Journal shows at most one entry" "<= 1" $jBuy ($jBuy -le 1)
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
                $gvKillText = if ($gvAtKill) { "kill-time $($gvAtKill.Size) B mtime $($gvAtKill.MTime) @ $($gvAtKill.At) (exit $($gvAtKill.ExitAt), lag $($gvAtKill.LagMs) ms, terminal down: $($gvAtKill.TerminalDown))" } else { "kill-time capture missing" }
                $gvPollText = if ($gvAtPoll) { "poll $($gvAtPoll.Size) B mtime $($gvAtPoll.MTime) @ $($gvAtPoll.At)" } else { "poll: terminal-down not observed" }
                $gvDown = Test-GvDownCheck $gvAtKill $gvAtPoll
                Add-Check $checks "gvariables.dat non-empty while the terminal was down (GlobalVariablesFlush)" ">0 B ($($gvDown.Source))" "$gvKillText; $gvPollText; before $($gvBefore.Size) B mtime $($gvBefore.MTime); end $($gvAfter.Size) B mtime $($gvAfter.MTime)" $gvDown.Pass
            }
        }

        $failed = @($checks | Where-Object { -not $_.Pass })

        # Entry statistics over the whole run (CSV rows are not trimmed by the T2 cut). Entries = max over the
        # independent sources; T6 adds the distinct-ticket count (the killed instance can lose its BUY row/line).
        $entriesSeen = [Math]::Max([Math]::Max($eaBuy, $jBuy), $buyRows.Count)
        if ($tNum -eq "6") { $entriesSeen = [Math]::Max($entriesSeen, (Get-T6EntryTickets $testLogLines $helperOut).Distinct.Count) }
        $entryStats = Get-EntryStats $newSkipsObjs $buyRows $entriesSeen $testLogLines
        # No entry at all, only gate skips: the checks were never exercised -> INVALID (gate starved), not a FAIL
        $starved = Resolve-EntryStarvation ([bool]$t.NeedsEntry) $entryStats
        $verdict = if ($starved) { "INVALID ($starved)" } else { Resolve-Verdict $completedCleanly $failed.Count $conditionalNote $elapsedSec }

        # Capture stale_tick backoffs as a distinct note (does NOT alter verdict)
        $staleCount = [Math]::Max(@($newSkipsObjs | Where-Object { $_.reason -eq "stale_tick" }).Count, (Count-Matches $testLogLines "stale_tick"))
        $staleNote = if ($staleCount -gt 0) { "$staleCount backoff(s) encountered (120s retry each)" } else { "None (0 backoffs)" }

        Write-Host ">>> TEST ${tNum} VERDICT: $verdict ($($checks.Count - $failed.Count)/$($checks.Count) checks$(if ($starved) { ', not evaluated: no entry' })) <<<" -ForegroundColor $(if ($verdict -eq "PASS") { "Green" } elseif ($verdict -like "CONDITIONAL*") { "Yellow" } else { "Red" })
        Write-Host "    [ENTRY STATS] $(Format-EntryStats $entryStats)" -ForegroundColor $(if ($starved) { "Yellow" } else { "Gray" })
        foreach ($c in $checks) {
            $mark = if ($c.Pass) { "ok  " } else { "FAIL" }
            Write-Host ("    [{0}] {1}: expected {2}, observed {3}" -f $mark, $c.Check, $c.Expected, $c.Observed) -ForegroundColor $(if ($c.Pass) { "Gray" } else { "Red" })
        }
        if ($staleCount -gt 0) {
            Write-Host "    [STALE TICK NOTE] $staleNote" -ForegroundColor Yellow
        }
        foreach ($w in $warnings) { Write-Host "    [WARN NOTE] $w" -ForegroundColor DarkYellow }   # never alters the verdict

        $Results.Add([PSCustomObject]@{
            Test = "Test $tNum ($tName)"
            Verdict = $verdict
            Summary = $(if ($starved) { "No entry in ${elapsedSec}s: $starved; checks not evaluated ($($checks.Count - $failed.Count)/$($checks.Count) would pass)" }
                        else { "$($checks.Count - $failed.Count)/$($checks.Count) checks passed in ${elapsedSec}s" + $(if ($failed.Count -gt 0) { "; failed: " + (($failed | ForEach-Object { $_.Check }) -join "; ") } else { "" }) })
            StaleTickBackoffs = $staleNote
            EntryStats = $entryStats
            Checks = @($checks)
            Warnings = @($warnings)
            Seed = $seed
            Clean = $clean
            Gv = $(if ($tNum -eq "6") { [PSCustomObject]@{ Before = $gvBefore; AtKill = $gvAtKill; AtPoll = $gvAtPoll; After = $gvAfter } } else { $null })
            MonitorTrace = @($monTrace)
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
