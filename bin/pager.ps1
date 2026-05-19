# pager - persistent remote-session toolkit for Claude Code (Windows native)
# Mirror of bin/pager (bash) for Linux/macOS.
#
# Requires PowerShell 5.1+ (default on Windows 10+) or PowerShell 7+.

# Don't `set -euo pipefail`; PowerShell handles errors differently. We use
# explicit -ErrorAction Stop where it matters.
$ErrorActionPreference = "Continue"

# Resolve repo root from script location (works whether called directly or via
# the 'pager' function from $PROFILE).
if ($env:PAGER_ROOT) {
    $PagerRoot = $env:PAGER_ROOT
} else {
    $PagerRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$PagerLogsDir = Join-Path $PagerRoot "logs"

# Load .env (same shape bash bin/pager does at the top).
$envFile = Join-Path $PagerRoot ".env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$') {
            $val = $Matches[2].Trim().Trim('"').Trim("'")
            Set-Item -Path "Env:$($Matches[1])" -Value $val
        }
    }
}

# --- helpers ---------------------------------------------------------------

function Get-PagerVersion {
    $changelog = Join-Path $PagerRoot "CHANGELOG.md"
    if (-not (Test-Path $changelog)) { return "DEV" }
    $match = Select-String -Path $changelog -Pattern '^## \[(\d+\.\d+\.\d+[^\]]*)\]' | Select-Object -First 1
    if ($match) { return $match.Matches.Groups[1].Value }
    return "DEV"
}

function Get-PythonExe {
    foreach ($candidate in 'python', 'python3', 'py') {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Read trust state from ~/.claude.json via Python (which doesn't choke on the
# duplicate-key JSON shapes claude sometimes writes -- PS 5.1 ConvertFrom-Json
# does, and PS7's -AsHashtable isn't available on 5.1).
# Returns @{ ok = $true; paths = @(...); home = $bool } on success,
#         @{ ok = $false; error = "..." } on failure.
function Get-TrustState {
    $claudeJson = "$env:USERPROFILE\.claude.json"
    if (-not (Test-Path $claudeJson)) {
        return @{ ok = $false; error = "~/.claude.json not found" }
    }
    $py = Get-PythonExe
    if (-not $py) {
        return @{ ok = $false; error = "python not available to parse JSON" }
    }
    $script = @'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
try:
    with open(p) as f: d = json.load(f)
except Exception as e:
    print('__ERROR__:' + str(e))
    sys.exit(0)
home = os.path.expanduser('~')
projects = d.get('projects') or {}
home_ok = False
trusted = []
for path, entry in projects.items():
    if not isinstance(entry, dict): continue
    if entry.get('hasTrustDialogAccepted') and entry.get('hasCompletedProjectOnboarding'):
        trusted.append(path)
        if path == home:
            home_ok = True
print('__HOME__:' + ('1' if home_ok else '0'))
for t in sorted(trusted):
    print(t)
'@
    $captured = & $py -c $script 2>&1
    $lines = @($captured | ForEach-Object { "$_" })
    if ($lines.Count -gt 0 -and $lines[0] -match "^__ERROR__:") {
        return @{ ok = $false; error = ($lines[0] -replace "^__ERROR__:","") }
    }
    $homeOk = $false
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l -match "^__HOME__:1") { $homeOk = $true; continue }
        if ($l -match "^__HOME__:0") { $homeOk = $false; continue }
        if ($l) { $paths.Add($l) | Out-Null }
    }
    return @{ ok = $true; home = $homeOk; paths = $paths.ToArray() }
}

function Get-PagerProcesses {
    # Find pager-managed claude processes via tracked PID files in logs/.
    if (-not (Test-Path $PagerLogsDir)) { return @() }
    Get-ChildItem -Path $PagerLogsDir -Filter "*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
        $session = $_.BaseName
        $procId = (Get-Content -Path $_.FullName -ErrorAction SilentlyContinue) -join "" | ForEach-Object { $_.Trim() }
        if (-not $procId) { return }
        try {
            $proc = Get-Process -Id $procId -ErrorAction Stop
            [PSCustomObject]@{
                Session = $session
                PID     = [int]$procId
                Process = $proc
                Alive   = $true
                LogPath = Join-Path $PagerLogsDir "$session.log"
            }
        } catch {
            [PSCustomObject]@{
                Session = $session
                PID     = [int]$procId
                Process = $null
                Alive   = $false
                LogPath = Join-Path $PagerLogsDir "$session.log"
            }
        }
    }
}

# --- commands --------------------------------------------------------------

function Show-Help {
    $version = Get-PagerVersion
    Write-Host ""
    Write-Host "pager v$version" -ForegroundColor White -NoNewline
    Write-Host "  -  persistent remote-session toolkit for Claude Code (Windows)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Usage:  pager <command> [args]"
    Write-Host ""
    Write-Host "Session commands"
    Write-Host "  start [name] [--cwd DIR]  spawn claude in background (default session: claude)"
    Write-Host "  stop  [name]              stop the session"
    Write-Host "  kill  [name]              alias for stop on Windows (no watchdog yet)"
    Write-Host "  status                    list active sessions"
    Write-Host "  url   [name]              print claude.ai/code URL from the session log"
    Write-Host "  logs  [name]              tail the session log (read-only `"attach`")"
    Write-Host ""
    Write-Host "Autostart"
    Write-Host "  autostart status          show current state"
    Write-Host "  autostart enable          register Scheduled Task"
    Write-Host "  autostart disable         remove Scheduled Task"
    Write-Host ""
    Write-Host "Trust"
    Write-Host "  trust [--check|--reset] [PATH ...]   pre-accept claude's Trust dialog"
    Write-Host ""
    Write-Host "Other"
    Write-Host "  info                      full state summary"
    Write-Host "  doctor                    health check"
    Write-Host "  uninstall [-y]            tear down pager (keeps repo + .env)"
    Write-Host "  help                      this message"
    Write-Host ""
    Write-Host "Note: Windows attach is read-only via 'pager logs'. For interactive PTY"
    Write-Host "attach, use WSL2 + the Linux installer."
    Write-Host ""
}

function Invoke-PagerStart {
    param([string]$Session = "claude", [string]$Cwd = $env:USERPROFILE)

    if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
        Write-Host "ERROR: claude (Claude Code CLI) not found on PATH." -ForegroundColor Red
        Write-Host "  Install: https://claude.com/code   (or: npm install -g @anthropic-ai/claude-code)"
        Write-Host "  Then re-run: pager start"
        exit 1
    }
    if (-not (Test-Path $Cwd)) {
        Write-Host "ERROR: --cwd directory does not exist: $Cwd" -ForegroundColor Red
        exit 1
    }
    $Cwd = (Resolve-Path -Path $Cwd).Path

    # Auto-trust the launch dir.
    Invoke-PagerTrust -Argv @($Cwd) | Out-Null

    # Check if session already running.
    $existing = Get-PagerProcesses | Where-Object { $_.Session -eq $Session -and $_.Alive }
    if ($existing) {
        Write-Host "Session '$Session' already running (PID $($existing.PID)). Tail with: pager logs $Session"
        return
    }

    if (-not (Test-Path $PagerLogsDir)) { New-Item -ItemType Directory -Force -Path $PagerLogsDir | Out-Null }
    $logPath = Join-Path $PagerLogsDir "$Session.log"
    $errPath = Join-Path $PagerLogsDir "$Session.err"
    $pidPath = Join-Path $PagerLogsDir "$Session.pid"

    # Build claude argv.
    $claudeArgs = New-Object System.Collections.Generic.List[string]
    if (-not $env:PAGER_NO_DANGEROUS) {
        $claudeArgs.Add("--dangerously-skip-permissions")
    }
    if (-not $env:PAGER_NO_REMOTE) {
        $claudeArgs.Add("--remote-control")
        $claudeArgs.Add($Session)
    }

    $startArgs = @{
        FilePath               = "claude"
        ArgumentList           = $claudeArgs.ToArray()
        WorkingDirectory       = $Cwd
        RedirectStandardOutput = $logPath
        RedirectStandardError  = $errPath
        WindowStyle            = "Hidden"
        PassThru               = $true
    }
    $proc = Start-Process @startArgs
    if (-not $proc) {
        Write-Host "ERROR: failed to start claude" -ForegroundColor Red
        exit 1
    }
    $proc.Id | Out-File -FilePath $pidPath -Encoding ascii -Force

    # Sanity check: claude often dies within 2s on Windows because Start-Process
    # doesn't give it a TTY and our stdout/stderr redirection makes claude
    # think it's in pipe/--print mode. Surface that immediately instead of
    # leaving a stale PID file for the user to discover via 'pager status'.
    Start-Sleep -Milliseconds 2500
    $alive = $true
    try { Get-Process -Id $proc.Id -ErrorAction Stop | Out-Null } catch { $alive = $false }

    if (-not $alive) {
        Write-Host ""
        Write-Host "WARNING: claude exited within 2.5 seconds." -ForegroundColor Yellow
        $errContent = ""
        if (Test-Path $errPath) {
            try { $errContent = (Get-Content -Path $errPath -Raw -ErrorAction SilentlyContinue) } catch {}
        }
        if ($errContent) {
            Write-Host ""
            Write-Host "--- claude stderr ($errPath) ---" -ForegroundColor DarkGray
            Write-Host $errContent.TrimEnd() -ForegroundColor DarkGray
            Write-Host "--------------------------------" -ForegroundColor DarkGray
            Write-Host ""
        }
        if ($errContent -match "Input must be provided" -or $errContent -match "--print") {
            Write-Host "This is a known v0.7.0-alpha Windows limitation:" -ForegroundColor Yellow
            Write-Host "  claude detects no TTY and switches to --print mode, then bails because"
            Write-Host "  no piped input is available. pager doesn't yet ship a Windows ConPTY"
            Write-Host "  shim to give claude a real terminal in the background."
            Write-Host ""
            Write-Host "Workarounds:" -ForegroundColor Yellow
            Write-Host "  1. Use WSL2 + the Linux installer (full PTY via tmux) -- this works today"
            Write-Host "  2. Run claude in a visible terminal yourself; pager will track it later"
            Write-Host "  3. Watch issue tracker for v0.8 (ConPTY-backed Windows sessions)"
            Write-Host ""
            Write-Host "Details: windows/README.md#known-limitations"
        }
        Remove-Item -Path $pidPath -ErrorAction SilentlyContinue
        exit 1
    }

    Write-Host "Started session '$Session'."
    Write-Host "  PID:    $($proc.Id)"
    Write-Host "  cwd:    $Cwd  (pre-trusted)"
    Write-Host "  Log:    $logPath"
    Write-Host "  Tail:   pager logs $Session"
    Write-Host "  URL:    pager url $Session"
}

function Invoke-PagerStop {
    param([string]$Session = "claude")
    $matches = Get-PagerProcesses | Where-Object { $_.Session -eq $Session }
    if (-not $matches) {
        Write-Host "No session '$Session' (no PID file in logs/)."
        return
    }
    $stopped = 0
    foreach ($p in $matches) {
        if ($p.Alive) {
            try {
                Stop-Process -Id $p.PID -Force -ErrorAction Stop
                Write-Host "Stopped session '$($p.Session)' (PID $($p.PID))."
                $stopped++
            } catch {
                Write-Host "  Couldn't kill PID $($p.PID): $_"
            }
        }
        # Remove stale PID file in either case.
        Remove-Item -Path "$PagerLogsDir\$($p.Session).pid" -ErrorAction SilentlyContinue
    }
    if ($stopped -eq 0) {
        Write-Host "Session '$Session' was already dead. PID file cleaned up."
    }
}

function Invoke-PagerStatus {
    $procs = Get-PagerProcesses
    if (-not $procs) {
        Write-Host "No pager sessions."
        Write-Host "Start one with: pager start"
        return
    }
    "{0,-16} {1,-8} {2,-12} {3}" -f "NAME","CLAUDE","AGE","PID" | Write-Host
    "{0,-16} {1,-8} {2,-12} {3}" -f "----","------","---","---" | Write-Host
    foreach ($p in $procs) {
        $state = if ($p.Alive) { "alive" } else { "DEAD" }
        $age   = "-"
        if ($p.Alive -and $p.Process.StartTime) {
            $span = (Get-Date) - $p.Process.StartTime
            $age = "{0:hh\:mm\:ss}" -f $span
        }
        "{0,-16} {1,-8} {2,-12} {3}" -f $p.Session, $state, $age, $p.PID | Write-Host
    }
    Write-Host ""
    Write-Host "Tail log: pager logs <name>   URL: pager url <name>"
}

function Invoke-PagerUrl {
    param([string]$Session = "claude")
    $logPath = Join-Path $PagerLogsDir "$Session.log"
    if (-not (Test-Path $logPath)) {
        Write-Host "[$Session] no log: $logPath  (start with: pager start $Session)"
        return
    }
    $match = Select-String -Path $logPath -Pattern 'https://claude\.ai/code/session_[A-Za-z0-9]+' -ErrorAction SilentlyContinue | Select-Object -Last 1
    if ($match) {
        Write-Host ("{0,-20} {1}" -f "[$Session]", $match.Matches.Value)
    } else {
        Write-Host ("{0,-20} {1}" -f "[$Session]", "(no Remote Control URL yet -- check 'pager logs $Session')")
    }
}

function Invoke-PagerLogs {
    param([string]$Session = "claude")
    $logPath = Join-Path $PagerLogsDir "$Session.log"
    $errPath = Join-Path $PagerLogsDir "$Session.err"
    $haveLog = Test-Path $logPath
    $haveErr = Test-Path $errPath
    if (-not $haveLog -and -not $haveErr) {
        Write-Host "No log files for session '$Session' at $PagerLogsDir" -ForegroundColor Yellow
        Write-Host "Start a session: pager start $Session"
        exit 1
    }

    # If stderr has content, show it first -- it's almost always the reason
    # claude isn't producing the expected stdout.
    if ($haveErr) {
        try { $errSize = (Get-Item $errPath -ErrorAction Stop).Length } catch { $errSize = 0 }
        if ($errSize -gt 0) {
            Write-Host "--- stderr: $errPath ---" -ForegroundColor Yellow
            Get-Content -Path $errPath
            Write-Host "--- end stderr ---" -ForegroundColor Yellow
            Write-Host ""
        }
    }

    if ($haveLog) {
        Write-Host "Tailing $logPath  (Ctrl-C to detach; the session keeps running)" -ForegroundColor DarkGray
        Write-Host ""
        Get-Content -Path $logPath -Tail 50 -Wait
    } else {
        Write-Host "(no stdout log yet -- $logPath)" -ForegroundColor DarkGray
    }
}

function Invoke-PagerTrust {
    param([string[]]$Argv)
    $mode = "set"
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Argv) {
        if ($a -eq "--check") { $mode = "check"; continue }
        if ($a -eq "--reset") { $mode = "reset"; continue }
        if ($a -eq "-h" -or $a -eq "--help") {
            Write-Host "Usage: pager trust [--check|--reset] [PATH ...]"
            Write-Host "  Pre-accept Claude Code's `"Trust this folder?`" dialog for PATH(s)."
            Write-Host "  Default PATH is `$env:USERPROFILE."
            return
        }
        $paths.Add($a) | Out-Null
    }
    if ($paths.Count -eq 0) { $paths.Add($env:USERPROFILE) | Out-Null }
    # Normalize to absolute where possible.
    $normalized = $paths | ForEach-Object {
        if (Test-Path $_) { (Resolve-Path -Path $_).Path } else { $_ }
    }

    $py = Get-PythonExe
    if (-not $py) {
        Write-Host "ERROR: python required for pager trust" -ForegroundColor Red
        exit 1
    }
    $script = @'
import json, os, sys
mode = sys.argv[1]
targets = sys.argv[2:]
p = os.path.expanduser('~/.claude.json')
d = {}
if os.path.exists(p):
    try:
        with open(p) as f: d = json.load(f)
    except Exception:
        d = {}
projects = d.setdefault('projects', {})
any_failed = False
dirty = False
for target in targets:
    e = projects.get(target, {})
    trusted = bool(e.get('hasTrustDialogAccepted'))
    onboard = bool(e.get('hasCompletedProjectOnboarding'))
    if mode == 'check':
        if trusted and onboard:
            print(f'TRUSTED:     {target}')
        else:
            print(f'NOT TRUSTED: {target}')
            any_failed = True
    elif mode == 'reset':
        if target in projects:
            del projects[target]
            dirty = True
            print(f'RESET:       {target}')
        else:
            print(f'NOOP:        {target}')
    else:
        if trusted and onboard:
            print(f'ALREADY:     {target}')
        else:
            e['hasTrustDialogAccepted'] = True
            e['hasCompletedProjectOnboarding'] = True
            projects[target] = e
            dirty = True
            print(f'TRUSTED:     {target}')
if dirty:
    with open(p, 'w') as f: json.dump(d, f, indent=2)
sys.exit(1 if any_failed else 0)
'@
    & $py -c $script $mode @normalized
}

function Invoke-PagerAutostart {
    param([string]$Subcommand = "status")
    $taskName = "pager"
    switch ($Subcommand) {
        "status" {
            try {
                $task = Get-ScheduledTask -TaskName $taskName -ErrorAction Stop
                Write-Host "autostart: ENABLED  (state: $($task.State))" -ForegroundColor Green
                exit 0
            } catch {
                Write-Host "autostart: disabled (no Scheduled Task '$taskName')" -ForegroundColor Yellow
                exit 1
            }
        }
        { $_ -in "enable", "on" } {
            $pwshExe = $null
            $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
            if ($cmd) { $pwshExe = $cmd.Source }
            if (-not $pwshExe) {
                $cmd = Get-Command powershell -ErrorAction SilentlyContinue
                if ($cmd) { $pwshExe = $cmd.Source }
            }
            if (-not $pwshExe) { Write-Host "No PowerShell on PATH (unexpected)" -ForegroundColor Red; exit 1 }
            $action = New-ScheduledTaskAction -Execute $pwshExe `
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" start claude"
            $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $settings = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -ExecutionTimeLimit ([TimeSpan]::Zero) `
                -RestartInterval ([TimeSpan]::FromMinutes(2)) `
                -RestartCount 3
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
            try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop } catch {}
            Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "pager - persistent Claude Code session" | Out-Null
            Write-Host "Scheduled Task '$taskName' registered (runs at user login)" -ForegroundColor Green
        }
        { $_ -in "disable", "off" } {
            try {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                Write-Host "Scheduled Task '$taskName' removed" -ForegroundColor Green
            } catch {
                Write-Host "No Scheduled Task '$taskName' to remove" -ForegroundColor Yellow
            }
        }
        "help" {
            Write-Host "Usage: pager autostart [enable|disable|status]"
            Write-Host "  enable   register Scheduled Task to start pager at login"
            Write-Host "  disable  remove the Scheduled Task"
            Write-Host "  status   report current state (exit 0 if enabled)"
        }
        default {
            Write-Host "Unknown subcommand: $Subcommand" -ForegroundColor Red
            Write-Host "Try: pager autostart status / enable / disable"
            exit 1
        }
    }
}

function Invoke-PagerUninstall {
    param([string[]]$Argv)
    $yes = $false
    foreach ($a in $Argv) {
        if ($a -eq "-y" -or $a -eq "--yes") { $yes = $true }
    }

    Write-Host "pager uninstall  -  $PagerRoot" -ForegroundColor White
    Write-Host ""
    Write-Host "This will:"
    Write-Host "  * Remove the Scheduled Task 'pager'"
    Write-Host "  * Stop any running pager sessions"
    Write-Host "  * Clean the pager block from your PowerShell `$PROFILE"
    Write-Host "  * Leave $PagerRoot and your .env in place"
    Write-Host ""

    if (-not $yes) {
        $confirm = Read-Host "Proceed? [y/N]"
        if ($confirm -notmatch '^[yY]') { Write-Host "Aborted."; return }
    }
    Write-Host ""

    # 1. Stop running sessions.
    $procs = Get-PagerProcesses
    foreach ($p in $procs) {
        if ($p.Alive) {
            try { Stop-Process -Id $p.PID -Force -ErrorAction Stop } catch {}
            Write-Host "  Stopped session '$($p.Session)' (PID $($p.PID))" -ForegroundColor Green
        }
        Remove-Item -Path "$PagerLogsDir\$($p.Session).pid" -ErrorAction SilentlyContinue
    }

    # 2. Remove Scheduled Task.
    try {
        Unregister-ScheduledTask -TaskName "pager" -Confirm:$false -ErrorAction Stop
        Write-Host "  Removed Scheduled Task 'pager'" -ForegroundColor Green
    } catch {}

    # 3. Strip pager block from $PROFILE (idempotent).
    if (Test-Path $PROFILE) {
        $content = Get-Content -Raw $PROFILE -ErrorAction SilentlyContinue
        if ($content) {
            # Match the block: blank line(s) + "# pager: auto-load" comment + the body up to (and including)
            # the closing 'function pager { ... }' line.
            $cleaned = $content -replace '(?ms)\r?\n\s*# pager: auto-load[\s\S]*?function pager \{[^\}]*\}', ''
            if ($content -ne $cleaned) {
                $backup = "$PROFILE.pager.bak.$([DateTime]::Now.ToString('yyyyMMddHHmmss'))"
                Copy-Item $PROFILE $backup
                Set-Content -Path $PROFILE -Value $cleaned -NoNewline
                Write-Host "  Cleaned pager block from `$PROFILE  (backup: $(Split-Path -Leaf $backup))" -ForegroundColor Green
            }
        }
    }

    Write-Host ""
    Write-Host "Uninstall complete." -ForegroundColor Green
    Write-Host ""
    Write-Host "Repo + .env are still at: $PagerRoot"
    Write-Host "To finish a full wipe:"
    Write-Host "  Remove-Item -Recurse -Force `"$PagerRoot`""
    Write-Host ""
    Write-Host "Note: claude.json trust entries are NOT removed. Use 'pager trust --reset <path>'"
    Write-Host "post-uninstall if you want a fully clean ~/.claude.json."
}

function Invoke-PagerInfo {
    $version = Get-PagerVersion
    Write-Host ""
    Write-Host "pager v$version" -ForegroundColor White -NoNewline
    Write-Host "   $PagerRoot" -ForegroundColor DarkGray
    Write-Host ""

    Write-Host "Quick start" -ForegroundColor White
    Write-Host "  pager start             spawn claude in background"
    Write-Host "  pager url               print the phone-accessible URL"
    Write-Host "  pager logs              tail the session log (read-only attach)"
    Write-Host "  pager status            list active sessions"
    Write-Host "  pager doctor            basic health check"
    Write-Host ""

    Write-Host "Stop / restart" -ForegroundColor White
    Write-Host "  pager stop              kill the session"
    Write-Host ""

    # Autostart state
    Write-Host "Autostart" -ForegroundColor White -NoNewline
    try {
        $task = Get-ScheduledTask -TaskName "pager" -ErrorAction Stop
        Write-Host "   ENABLED ($($task.State))" -ForegroundColor Green
    } catch {
        Write-Host "   disabled" -ForegroundColor Yellow
    }
    Write-Host "  pager autostart status  check"
    Write-Host "  pager autostart enable  register Scheduled Task"
    Write-Host "  pager autostart disable remove Scheduled Task"
    Write-Host ""

    # Trusted folders
    Write-Host "Trusted folders   " -ForegroundColor White -NoNewline
    Write-Host "(Claude Code's `"Trust this folder?`" dialog won't fire)" -ForegroundColor DarkGray
    $trust = Get-TrustState
    if ($trust.ok) {
        if ($trust.paths -and $trust.paths.Count -gt 0) {
            foreach ($t in $trust.paths) { Write-Host "    $t" -ForegroundColor Green }
        } else {
            Write-Host "    (none -- bootstrap normally trusts `$env:USERPROFILE)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    ($($trust.error))" -ForegroundColor Yellow
    }
    Write-Host ""
    Write-Host "  pager trust C:\code\myproject         ad-hoc"
    Write-Host "  pager start --cwd C:\code\myproject   auto-trust + start"
    Write-Host ""

    # Files
    Write-Host "Files" -ForegroundColor White
    Write-Host "  repo:      $PagerRoot"
    Write-Host "  .env:      $PagerRoot\.env"
    Write-Host "  logs:      $PagerLogsDir"
    Write-Host ""

    # Docs
    Write-Host "Docs" -ForegroundColor White
    Write-Host "  pager help"
    Write-Host "  $PagerRoot\README.md"
    Write-Host "  https://github.com/jawwadzafar/pager"
    Write-Host ""
}

function Invoke-PagerDoctor {
    Write-Host ""
    Write-Host "pager doctor" -ForegroundColor White -NoNewline
    Write-Host "   $PagerRoot" -ForegroundColor DarkGray
    Write-Host ""

    # Use a hashtable so nested helper functions can mutate counters without
    # running into PowerShell's $script: vs local scope gotcha (the previous
    # impl always reported "all checks passed" because $script:warns and the
    # local $warns were two different variables).
    $c = @{ fails = 0; warns = 0 }
    $Pass = { param($msg) Write-Host "  OK $msg" -ForegroundColor Green }
    $Warn = {
        param($msg, $hint)
        Write-Host "  !  $msg" -ForegroundColor Yellow
        if ($hint) { Write-Host "     -> $hint" -ForegroundColor DarkGray }
        $c.warns += 1
    }
    $Fail = {
        param($msg, $hint)
        Write-Host "  X  $msg" -ForegroundColor Red
        if ($hint) { Write-Host "     -> $hint" -ForegroundColor DarkGray }
        $c.fails += 1
    }

    Write-Host "Dependencies"
    if (Get-Command git    -ErrorAction SilentlyContinue) { & $Pass "git" }    else { & $Fail "git missing" "winget install Git.Git" }
    if (Get-Command claude -ErrorAction SilentlyContinue) { & $Pass "claude" } else { & $Warn "claude not on PATH" "Install: https://claude.com/code" }
    if (Get-PythonExe) { & $Pass "python" } else { & $Warn "python missing" "winget install Python.Python.3.12" }

    Write-Host ""
    Write-Host "Trust"
    $trust = Get-TrustState
    if ($trust.ok) {
        if ($trust.home) { & $Pass "`$env:USERPROFILE pre-trusted" }
        else { & $Warn "`$env:USERPROFILE not trusted" "pager trust" }
    } else {
        & $Warn "trust state: $($trust.error)" "pager trust"
    }

    Write-Host ""
    Write-Host "Autostart"
    try {
        $task = Get-ScheduledTask -TaskName "pager" -ErrorAction Stop
        & $Pass "Scheduled Task 'pager' present (state: $($task.State))"
    } catch {
        & $Warn "no Scheduled Task 'pager'" "pager autostart enable"
    }

    Write-Host ""
    Write-Host "Sessions"
    $procs = Get-PagerProcesses
    if ($procs) {
        foreach ($p in $procs) {
            if ($p.Alive) { & $Pass "session '$($p.Session)' alive (PID $($p.PID))" }
            else          { & $Warn "session '$($p.Session)' DEAD (stale PID file)" "pager stop $($p.Session)" }
        }
    } else {
        & $Warn "no active sessions" "pager start"
    }

    Write-Host ""
    if ($c.fails -eq 0 -and $c.warns -eq 0) {
        Write-Host "OK all checks passed" -ForegroundColor Green
        exit 0
    } elseif ($c.fails -eq 0) {
        Write-Host "!  warnings: $($c.warns) (non-fatal)" -ForegroundColor Yellow
        exit 0
    } else {
        Write-Host "X  failures: $($c.fails)   warnings: $($c.warns)" -ForegroundColor Red
        exit 1
    }
}

# --- dispatch -------------------------------------------------------------

# Parse start's flags out of $args (since the dispatch is a switch).
$cmd = $args[0]
$rest = @()
if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }

switch ($cmd) {
    { $_ -in "start", "bg" } {
        $session = "claude"
        $cwd = $env:USERPROFILE
        $i = 0
        while ($i -lt $rest.Count) {
            $a = $rest[$i]
            if ($a -eq "--cwd") { $cwd = $rest[$i+1]; $i += 2; continue }
            if ($a -like "--cwd=*") { $cwd = $a.Substring(6); $i += 1; continue }
            if ($a -like "-*") { Write-Host "Unknown option: $a" -ForegroundColor Red; exit 1 }
            if (-not $session -or $session -eq "claude") { $session = $a; $i += 1; continue }
            $i += 1
        }
        Invoke-PagerStart -Session $session -Cwd $cwd
    }
    { $_ -in "stop", "kill" } {
        $session = if ($rest.Count -gt 0) { $rest[0] } else { "claude" }
        Invoke-PagerStop -Session $session
    }
    { $_ -in "status", "ls" } { Invoke-PagerStatus }
    "url" {
        $session = if ($rest.Count -gt 0) { $rest[0] } else { "claude" }
        Invoke-PagerUrl -Session $session
    }
    "logs" {
        $session = if ($rest.Count -gt 0) { $rest[0] } else { "claude" }
        Invoke-PagerLogs -Session $session
    }
    "trust"     { Invoke-PagerTrust -Argv $rest }
    "autostart" {
        $sub = if ($rest.Count -gt 0) { $rest[0] } else { "status" }
        Invoke-PagerAutostart -Subcommand $sub
    }
    "uninstall" { Invoke-PagerUninstall -Argv $rest }
    "info"      { Invoke-PagerInfo }
    { $_ -in "doctor", "check" } { Invoke-PagerDoctor }
    { $_ -in "help", "--help", "-h", $null, "" } { Show-Help }
    default {
        Write-Host "Unknown subcommand: $cmd" -ForegroundColor Red
        Write-Host ""
        Show-Help
        exit 1
    }
}
