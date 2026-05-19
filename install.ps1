# pager installer for Windows (PowerShell entry point).
# Mirror of install.sh for Linux/macOS.
#
# Usage:
#   irm https://raw.githubusercontent.com/jawwadzafar/pager/main/install.ps1 | iex
#
# Or, with options:
#   $env:PAGER_NO_AUTOSTART=1; irm ... | iex      # skip Scheduled Task
#   $env:PAGER_BRANCH="v0.7.0-alpha"; irm ... | iex  # pin to a tag
#
# Requires PowerShell 5.1+ (default on Windows 10+) or PowerShell 7+.
# Native Windows; does NOT use WSL.

# Strict mode but don't die on every external command exit code.
$ErrorActionPreference = "Stop"

# --- config ----------------------------------------------------------------
$Repo   = if ($env:PAGER_REPO)   { $env:PAGER_REPO   } else { "https://github.com/jawwadzafar/pager.git" }
$Branch = if ($env:PAGER_BRANCH) { $env:PAGER_BRANCH } else { "main" }
$Target = if ($env:PAGER_HOME)   { $env:PAGER_HOME   } else { "$env:USERPROFILE\.pager" }
$SkipAutostart = [bool]$env:PAGER_NO_AUTOSTART

# --- helpers ---------------------------------------------------------------
function Log  ($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok   ($msg) { Write-Host "    OK $msg" -ForegroundColor Green }
function Warn ($msg) { Write-Host "    !  $msg" -ForegroundColor Yellow }
function Die  ($msg) { Write-Host "    ERROR: $msg" -ForegroundColor Red; exit 1 }

# --- preflight banner ------------------------------------------------------
Log "pager installer  (os: windows, target: $Target, branch: $Branch)"

Write-Host @"

  About to install pager on Windows. Here's what happens:

    1. Clone the pager repo into $Target
    2. Install Git + OpenSSH + Python via winget (if missing)
    3. Wire your PowerShell `$PROFILE so 'pager' is on PATH + .env loads
    4. Pre-trust `$env:USERPROFILE in ~/.claude.json (so claude won't show its trust dialog)
"@
if (-not $SkipAutostart) {
    Write-Host "    5. Register a Scheduled Task so pager comes back at every login"
}
Write-Host @"

  After install, run 'pager info' any time to see state + commands.

  Don't want autostart? Re-run with `$env:PAGER_NO_AUTOSTART=1 first.

  Pure Windows native install -- does NOT use WSL.
  Note: 'pager attach' is read-only on Windows (use 'pager logs' to tail).
  For full PTY-based attach, install WSL2 and use the Linux installer there.

"@

# --- git is required ------------------------------------------------------
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Warn "git not found. Will try to install via winget below."
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "Neither git nor winget found. Install Git for Windows from https://git-scm.com/download/win, then re-run."
    }
    Log "Installing Git via winget..."
    winget install --silent --accept-source-agreements --accept-package-agreements --id Git.Git
    # Refresh PATH for current session
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Die "git still not found after winget install. Reopen PowerShell and re-run."
    }
}

# --- claude soft check ----------------------------------------------------
if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Warn "claude (Claude Code CLI) not found on PATH."
    Warn "  Install: https://claude.com/code   (or: npm install -g @anthropic-ai/claude-code)"
    Warn "  pager will install; you'll need claude before 'pager start' will work."
}

# --- clone / update -------------------------------------------------------
if (Test-Path "$Target\.git") {
    Log "Existing clone at $Target -- fetching latest..."
    git -C $Target remote set-url origin $Repo 2>$null
    git -C $Target fetch --quiet origin
    git -C $Target checkout --quiet $Branch 2>$null
    git -C $Target pull --ff-only --quiet 2>$null
    Ok "Updated $Target"
} elseif (Test-Path $Target) {
    Die "$Target exists but isn't a git checkout. Move or remove it, then re-run."
} else {
    Log "Cloning $Repo into $Target..."
    git clone --depth=1 --branch $Branch $Repo $Target
    Ok "Cloned to $Target"
}

# --- run the Windows bootstrap --------------------------------------------
Log "Running Windows bootstrap (longest step)..."
$bootstrap = Join-Path $Target "windows\bootstrap.ps1"
if (-not (Test-Path $bootstrap)) {
    Die "Bootstrap not found at $bootstrap. Did the clone fail?"
}
if ($SkipAutostart) {
    & $bootstrap -NoAutostart
} else {
    & $bootstrap
}
