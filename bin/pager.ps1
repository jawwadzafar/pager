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

# Read trust state from ~/.claude.json via Python.
#
# Returns @{ ok = $true; paths = @(...); home = $bool; dupes = $int;
#            short_keys = $int }                                  on success,
#         @{ ok = $false; error = "..." }                         on failure.
#
# Path matching is forward-slash + lowercase normalized: claude writes its own
# project keys with forward slashes (e.g. "C:/Users/Foo"), while a naive
# `os.path.expanduser('~')` on Windows returns backslashes. We compare
# normalized so the home check works either way.
#
# `dupes` is the count of duplicate `hasTrustDialogAccepted` keys inside the
# same JSON object (claude appends one during init, beating our pre-set value
# in the duplicate-key race per JSON spec).
#
# `short_keys` is the count of `projects` keys shorter than a real path -- the
# fingerprint of the legacy splat-as-chars bug that wrote one entry per
# character of the path.
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
dupes = [0]
def hook(pairs):
    seen = set()
    for k, _ in pairs:
        if k in seen and k == 'hasTrustDialogAccepted':
            dupes[0] += 1
        seen.add(k)
    return dict(pairs)
try:
    with open(p) as f:
        d = json.load(f, object_pairs_hook=hook)
except Exception as e:
    print('__ERROR__:' + str(e))
    sys.exit(0)
home = os.environ.get('USERPROFILE') or os.path.expanduser('~')
home_norm = home.replace('\\', '/').lower()
projects = d.get('projects') or {}
home_ok = False
trusted = []
short_keys = 0
for path, entry in projects.items():
    if len(path) < 4:
        short_keys += 1
        continue
    if not isinstance(entry, dict): continue
    if entry.get('hasTrustDialogAccepted') and entry.get('hasCompletedProjectOnboarding'):
        trusted.append(path)
        if path.replace('\\', '/').lower() == home_norm:
            home_ok = True
print('__HOME__:' + ('1' if home_ok else '0'))
print('__DUPES__:' + str(dupes[0]))
print('__SHORT__:' + str(short_keys))
for t in sorted(trusted):
    print(t)
'@
    $captured = & $py -c $script 2>&1
    $lines = @($captured | ForEach-Object { "$_" })
    if ($lines.Count -gt 0 -and $lines[0] -match "^__ERROR__:") {
        return @{ ok = $false; error = ($lines[0] -replace "^__ERROR__:","") }
    }
    $homeOk = $false
    $dupes = 0
    $shortKeys = 0
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($l in $lines) {
        if ($l -match "^__HOME__:1") { $homeOk = $true; continue }
        if ($l -match "^__HOME__:0") { $homeOk = $false; continue }
        if ($l -match "^__DUPES__:(\d+)$") { $dupes = [int]$Matches[1]; continue }
        if ($l -match "^__SHORT__:(\d+)$") { $shortKeys = [int]$Matches[1]; continue }
        if ($l) { $paths.Add($l) | Out-Null }
    }
    return @{
        ok = $true
        home = $homeOk
        paths = $paths.ToArray()
        dupes = $dupes
        short_keys = $shortKeys
    }
}

# Canonical fix for the three Windows trust-state gotchas:
#   1. Legacy splat-as-chars damage: single-char keys under `projects`
#      (e.g. "C", ":", "\\", "U", "s"...) written by old `pager trust`.
#   2. Path-form mismatch: claude writes forward-slash keys; backslash
#      entries are sibling-ignored.
#   3. Duplicate `hasTrustDialogAccepted` keys within a single object
#      (claude appends `false` after init; last value wins per JSON spec).
#
# Round-tripping through json.load -> json.dump collapses duplicate keys
# (the loader keeps the last value, the dumper writes each key exactly once),
# so the explicit `True` write that follows wins cleanly.
#
# Idempotent. Returns @{ ok = $true; touched = @(...); removed = @(...) }
#                  or @{ ok = $false; error = "..." }.
function Repair-PagerTrust {
    param([string[]]$ExtraPaths = @())
    $py = Get-PythonExe
    if (-not $py) {
        return @{ ok = $false; error = "python not available" }
    }
    $script = @'
import json, os, sys
p = os.path.expanduser('~/.claude.json')
if not os.path.exists(p):
    d = {}
else:
    with open(p) as f:
        d = json.load(f)
projects = d.setdefault('projects', {})

removed = []
for k in list(projects):
    if len(k) < 4:
        removed.append(k); del projects[k]

home = os.environ.get('USERPROFILE') or os.path.expanduser('~')
targets = [home] + sys.argv[1:]

def normkey(s):
    return s.replace('\\', '/').lower()

touched = []
for t in targets:
    t_norm = normkey(t)
    matched = [k for k in projects if normkey(k) == t_norm]
    if not matched:
        key = t.replace('\\', '/')  # store in claude's expected form
        projects[key] = {}
        matched = [key]
    for k in matched:
        projects[k]['hasTrustDialogAccepted'] = True
        projects[k]['hasCompletedProjectOnboarding'] = True
        touched.append(k)

with open(p, 'w') as f:
    json.dump(d, f, indent=2)
print('__REMOVED__:' + '|'.join(removed))
print('__TOUCHED__:' + '|'.join(sorted(set(touched))))
'@
    # Force array context so a single-element call doesn't get splatted
    # one character at a time (the bug we're fixing).
    $splatPaths = @($ExtraPaths)
    $captured = & $py -c $script @splatPaths 2>&1
    $lines = @($captured | ForEach-Object { "$_" })
    $removed = @()
    $touched = @()
    foreach ($l in $lines) {
        if ($l -match '^__REMOVED__:(.*)$') {
            $removed = @($Matches[1] -split '\|' | Where-Object { $_ })
        }
        if ($l -match '^__TOUCHED__:(.*)$') {
            $touched = @($Matches[1] -split '\|' | Where-Object { $_ })
        }
    }
    return @{ ok = $true; touched = $touched; removed = $removed }
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
    Write-Host "  trust [--check|--reset|--repair] [PATH ...]   pre-accept claude's Trust dialog"
    Write-Host ""
    Write-Host "Other"
    Write-Host "  info                      full state summary"
    Write-Host "  doctor [--fix]            health check (--fix runs 'trust --repair' first)"
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
    $pidPath = Join-Path $PagerLogsDir "$Session.pid"
    $urlCachePath = Join-Path $PagerLogsDir "$Session.url"

    # Build claude argv.
    $claudeArgs = New-Object System.Collections.Generic.List[string]
    if (-not $env:PAGER_NO_DANGEROUS) {
        $claudeArgs.Add("--dangerously-skip-permissions")
    }
    if (-not $env:PAGER_NO_REMOTE) {
        $claudeArgs.Add("--remote-control")
        $claudeArgs.Add($Session)
    }

    # CRITICAL: do NOT use -RedirectStandardOutput / -RedirectStandardError here.
    # Redirection strips claude's TTY, and claude then bails with "Input must be
    # provided ... --print". Instead we let claude have a hidden console window
    # (real TTY, no UI), and scrape the URL out of the console screen buffer
    # in Invoke-PagerUrl via AttachConsole + ReadConsoleOutputCharacter.
    $startArgs = @{
        FilePath          = "claude"
        ArgumentList      = $claudeArgs.ToArray()
        WorkingDirectory  = $Cwd
        WindowStyle       = "Hidden"
        PassThru          = $true
    }
    $proc = Start-Process @startArgs
    if (-not $proc) {
        Write-Host "ERROR: failed to start claude" -ForegroundColor Red
        exit 1
    }
    $proc.Id | Out-File -FilePath $pidPath -Encoding ascii -Force
    # Clear any old URL cache from a previous run.
    Remove-Item -Path $urlCachePath -ErrorAction SilentlyContinue

    # Sanity check: still alive after a couple seconds? (claude could fail to
    # find an auth token, hit a version mismatch, etc. -- those errors die fast.)
    Start-Sleep -Milliseconds 2500
    $alive = $true
    try { Get-Process -Id $proc.Id -ErrorAction Stop | Out-Null } catch { $alive = $false }
    if (-not $alive) {
        Write-Host ""
        Write-Host "WARNING: claude exited within 2.5 seconds." -ForegroundColor Yellow
        Write-Host "  Most common causes:"
        Write-Host "    * claude not authenticated -- run 'claude' once interactively to log in"
        Write-Host "    * claude version doesn't support --remote-control"
        Write-Host "    * --dangerously-skip-permissions rejected"
        Write-Host ""
        Write-Host "  Verify directly (in a normal PowerShell window):"
        Write-Host "    claude --version"
        Write-Host "    claude --dangerously-skip-permissions --remote-control claude"
        Write-Host ""
        Remove-Item -Path $pidPath -ErrorAction SilentlyContinue
        exit 1
    }

    # Claude rewrites its own project entry in ~/.claude.json during init and
    # appends `hasTrustDialogAccepted: false`. JSON spec: later value wins, so
    # without a re-stamp our pre-launch `true` loses. Sleep 4s to let claude
    # finish its first write, then repair the entry.
    Start-Sleep -Milliseconds 4000
    $null = Repair-PagerTrust -ExtraPaths @($Cwd)

    Write-Host "Started session '$Session'."
    Write-Host "  PID:    $($proc.Id)"
    Write-Host "  cwd:    $Cwd  (pre-trusted)"
    Write-Host "  State:  running in hidden console (real TTY, no visible window)"
    Write-Host ""
    Write-Host "  Phone URL:   pager url $Session     (scrapes claude's console buffer)"
    Write-Host "  Stop:        pager stop $Session"
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
        # Remove PID and URL-cache files in either case.
        Remove-Item -Path "$PagerLogsDir\$($p.Session).pid" -ErrorAction SilentlyContinue
        Remove-Item -Path "$PagerLogsDir\$($p.Session).url" -ErrorAction SilentlyContinue
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
    $urlCachePath = Join-Path $PagerLogsDir "$Session.url"

    # Fast path: we've successfully scraped this session's URL before. Cached
    # URLs survive subsequent calls even if claude has scrolled the URL line
    # off the visible screen buffer.
    if (Test-Path $urlCachePath) {
        $cached = (Get-Content -Path $urlCachePath -Raw -ErrorAction SilentlyContinue).Trim()
        if ($cached -match "^https://claude\.ai/code/session_") {
            Write-Host ("{0,-20} {1}" -f "[$Session]", $cached)
            return
        }
    }

    # Otherwise, find the live session and scrape its hidden console buffer.
    $procs = Get-PagerProcesses | Where-Object { $_.Session -eq $Session -and $_.Alive }
    if (-not $procs) {
        Write-Host ("{0,-20} {1}" -f "[$Session]", "no session running. Start with: pager start $Session")
        return
    }
    $targetPid = $procs[0].PID

    $url = Read-UrlFromConsole -TargetPid $targetPid
    if ($url) {
        $url | Out-File -FilePath $urlCachePath -Encoding ascii -Force
        Write-Host ("{0,-20} {1}" -f "[$Session]", $url)
    } else {
        Write-Host ("{0,-20} {1}" -f "[$Session]", "(URL not visible in claude's console buffer yet)")
        Write-Host "  Try again in a few seconds -- claude prints the URL within ~5s of startup."
        Write-Host "  If it never appears, claude may have scrolled past it. Restart: pager restart $Session"
    }
}

# Read claude's hidden console screen buffer via Win32 APIs to find the
# Remote Control URL. Runs in a SIDECAR pwsh process because AttachConsole
# requires the calling process to not already have a console (pwsh does).
function Read-UrlFromConsole {
    param([int]$TargetPid)

    # The sidecar script: FreeConsole -> AttachConsole(target) -> read whole
    # screen buffer -> regex for URL -> print -> exit.
    $sidecar = @'
param([int]$TargetPid)
$ErrorActionPreference = "Continue"
Add-Type -Namespace PagerWin -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool AttachConsole(uint dwProcessId);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern System.IntPtr GetStdHandle(int nStdHandle);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct COORD { public short X; public short Y; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct SMALL_RECT { public short Left; public short Top; public short Right; public short Bottom; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct CSBI {
    public COORD dwSize;
    public COORD dwCursorPosition;
    public short wAttributes;
    public SMALL_RECT srWindow;
    public COORD dwMaximumWindowSize;
}
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
public static extern bool GetConsoleScreenBufferInfo(System.IntPtr hConsoleOutput, out CSBI lpConsoleScreenBufferInfo);
[System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool ReadConsoleOutputCharacter(System.IntPtr hConsoleOutput, System.Text.StringBuilder lpCharacter, uint nLength, COORD dwReadCoord, out uint lpNumberOfCharsRead);
"@
[void][PagerWin.Native]::FreeConsole()
if (-not [PagerWin.Native]::AttachConsole([uint32]$TargetPid)) {
    [Console]::Error.WriteLine("AttachConsole failed for pid $TargetPid (err " + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() + ")")
    exit 2
}
$STD_OUTPUT_HANDLE = -11
$h = [PagerWin.Native]::GetStdHandle($STD_OUTPUT_HANDLE)
$info = New-Object PagerWin.Native+CSBI
if (-not [PagerWin.Native]::GetConsoleScreenBufferInfo($h, [ref]$info)) {
    [Console]::Error.WriteLine("GetConsoleScreenBufferInfo failed")
    exit 3
}
$width  = [int]$info.dwSize.X
$height = [int]$info.dwSize.Y
if ($width -le 0 -or $height -le 0) {
    [Console]::Error.WriteLine("Bad buffer size: ${width}x${height}")
    exit 4
}
$all = New-Object System.Text.StringBuilder ($width * $height + $height)
$buf = New-Object System.Text.StringBuilder $width
for ($y = 0; $y -lt $height; $y++) {
    $coord = New-Object PagerWin.Native+COORD
    $coord.X = 0
    $coord.Y = [short]$y
    $read = [uint32]0
    [void][PagerWin.Native]::ReadConsoleOutputCharacter($h, $buf, [uint32]$width, $coord, [ref]$read)
    [void]$all.AppendLine($buf.ToString(0, [int]$read).TrimEnd())
    [void]$buf.Clear()
}
[void][PagerWin.Native]::FreeConsole()
$text = $all.ToString()
$m = [regex]::Match($text, "https://claude\.ai/code/session_[A-Za-z0-9]+")
if ($m.Success) {
    Write-Output $m.Value
    exit 0
}
exit 1
'@

    # Write the sidecar to a temp .ps1 and invoke whichever PowerShell host
    # is available. powershell.exe (5.1) is always present on Win10+.
    $tempPs1 = [System.IO.Path]::GetTempFileName()
    $tempPs1Final = $tempPs1 + ".ps1"
    Move-Item -Path $tempPs1 -Destination $tempPs1Final -Force
    Set-Content -Path $tempPs1Final -Value $sidecar -Encoding ASCII

    $hostExe = $null
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $hostExe = $cmd.Source }
    if (-not $hostExe) {
        $cmd = Get-Command powershell -ErrorAction SilentlyContinue
        if ($cmd) { $hostExe = $cmd.Source }
    }
    if (-not $hostExe) {
        Remove-Item -Path $tempPs1Final -ErrorAction SilentlyContinue
        return $null
    }

    try {
        $captured = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $tempPs1Final -TargetPid $TargetPid 2>$null
        if ($LASTEXITCODE -eq 0 -and $captured) {
            return ($captured | Select-Object -First 1).Trim()
        }
    } catch {
        # fall through to return $null
    } finally {
        Remove-Item -Path $tempPs1Final -ErrorAction SilentlyContinue
    }
    return $null
}

function Invoke-PagerLogs {
    param([string]$Session = "claude")
    Write-Host "Windows-native v0.7.0-alpha doesn't capture session output to a file." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Why: claude needs a real TTY to run interactively; redirecting stdout/stderr"
    Write-Host "to a file strips the TTY and makes claude bail to --print mode. So claude runs"
    Write-Host "in a hidden console with no log capture in this alpha."
    Write-Host ""
    Write-Host "What you can do instead:"
    Write-Host "  pager url $Session     scrape just the claude.ai/code URL from the console"
    Write-Host "  pager status           is the session alive?"
    Write-Host ""
    Write-Host "For full log tailing, install WSL2 + the Linux installer (tmux-backed)."
}

function Invoke-PagerTrust {
    param([string[]]$Argv)
    $mode = "set"
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Argv) {
        if ($a -eq "--check")  { $mode = "check"; continue }
        if ($a -eq "--reset")  { $mode = "reset"; continue }
        if ($a -eq "--repair") { $mode = "repair"; continue }
        if ($a -eq "-h" -or $a -eq "--help") {
            Write-Host "Usage: pager trust [--check|--reset|--repair] [PATH ...]"
            Write-Host "  Pre-accept Claude Code's `"Trust this folder?`" dialog for PATH(s)."
            Write-Host "  Default PATH is `$env:USERPROFILE."
            Write-Host "  --check    report TRUSTED / NOT TRUSTED for each path (exit 1 if any missing)"
            Write-Host "  --reset    remove the trust entry for each path"
            Write-Host "  --repair   scrub legacy garbage + force trust=true + dedupe ~/.claude.json"
            return
        }
        $paths.Add($a) | Out-Null
    }

    # `set` and `--repair` both safely upsert. Route both through
    # Repair-PagerTrust so we get garbage cleanup + path-form normalization +
    # duplicate-key collapse on every set, not just on explicit --repair.
    if ($mode -eq "set" -or $mode -eq "repair") {
        $extras = @($paths.ToArray())
        $result = Repair-PagerTrust -ExtraPaths $extras
        if (-not $result.ok) {
            Write-Host "ERROR: $($result.error)" -ForegroundColor Red
            exit 1
        }
        if ($result.removed.Count -gt 0) {
            Write-Host "Removed $($result.removed.Count) legacy garbage entries from projects:" -ForegroundColor Yellow
            foreach ($r in $result.removed) {
                Write-Host "  - $r" -ForegroundColor DarkYellow
            }
        }
        if ($result.touched.Count -gt 0) {
            foreach ($t in $result.touched) {
                Write-Host "TRUSTED:     $t" -ForegroundColor Green
            }
        } elseif ($result.removed.Count -eq 0) {
            Write-Host "(no changes)" -ForegroundColor DarkGray
        }
        return
    }

    # check + reset: explicit list. Force array context so a single-element
    # pipeline doesn't unwrap to a scalar string (the splat-as-chars bug).
    if ($paths.Count -eq 0) { $paths.Add($env:USERPROFILE) | Out-Null }
    $normalized = @($paths | ForEach-Object {
        $resolved = if (Test-Path $_) { (Resolve-Path -Path $_).Path } else { $_ }
        # Forward slashes match claude's stored form.
        $resolved -replace '\\', '/'
    })

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

def normkey(s):
    return s.replace('\\', '/').lower()

any_failed = False
dirty = False
for target in targets:
    t_norm = normkey(target)
    matched = [k for k in projects if normkey(k) == t_norm]
    if mode == 'check':
        ok = bool(matched) and all(
            projects[k].get('hasTrustDialogAccepted') and projects[k].get('hasCompletedProjectOnboarding')
            for k in matched
        )
        if ok:
            print(f'TRUSTED:     {target}')
        else:
            print(f'NOT TRUSTED: {target}')
            any_failed = True
    elif mode == 'reset':
        if matched:
            for k in matched:
                del projects[k]
            dirty = True
            print(f'RESET:       {target}')
        else:
            print(f'NOOP:        {target}')
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
                -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" start default-boot"
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
    param([switch]$Fix)

    Write-Host ""
    if ($Fix) {
        Write-Host "pager doctor --fix" -ForegroundColor White -NoNewline
    } else {
        Write-Host "pager doctor" -ForegroundColor White -NoNewline
    }
    Write-Host "   $PagerRoot" -ForegroundColor DarkGray
    Write-Host ""

    if ($Fix) {
        Write-Host "Repairing trust state..." -ForegroundColor Cyan
        $r = Repair-PagerTrust
        if ($r.ok) {
            if ($r.removed.Count -gt 0) {
                Write-Host "  removed $($r.removed.Count) legacy garbage projects entries" -ForegroundColor Yellow
            }
            foreach ($t in $r.touched) {
                Write-Host "  trusted: $t" -ForegroundColor Green
            }
            if ($r.removed.Count -eq 0 -and $r.touched.Count -eq 0) {
                Write-Host "  (nothing to repair)" -ForegroundColor DarkGray
            }
        } else {
            Write-Host "  trust repair failed: $($r.error)" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "Re-running checks..." -ForegroundColor Cyan
        Write-Host ""
    }

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
        else { & $Warn "`$env:USERPROFILE not trusted" "pager trust --repair" }
        if ($trust.dupes -gt 0) {
            & $Warn "duplicate hasTrustDialogAccepted key(s) in ~/.claude.json: $($trust.dupes)" "pager trust --repair"
        }
        if ($trust.short_keys -gt 0) {
            & $Warn "legacy single-char projects keys: $($trust.short_keys) (splat-bug damage)" "pager trust --repair"
        }
    } else {
        & $Warn "trust state: $($trust.error)" "pager trust --repair"
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
    { $_ -in "doctor", "check" } {
        $fix = ($rest -contains "--fix") -or ($rest -contains "-f")
        Invoke-PagerDoctor -Fix:$fix
    }
    { $_ -in "help", "--help", "-h", $null, "" } { Show-Help }
    default {
        Write-Host "Unknown subcommand: $cmd" -ForegroundColor Red
        Write-Host ""
        Show-Help
        exit 1
    }
}
