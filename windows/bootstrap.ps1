# Windows native bootstrap for pager. Idempotent.
#
# Called by install.ps1 after the repo is cloned. Can also be run directly:
#   & $env:USERPROFILE\.pager\windows\bootstrap.ps1 [-NoAutostart]
#
# Requires PowerShell 5.1+ or PowerShell 7+.

param(
    [switch]$NoAutostart
)

$ErrorActionPreference = "Stop"

# This script lives at $PagerRoot\windows\bootstrap.ps1 -- go up two to root.
$PagerRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$PagerBin  = Join-Path $PagerRoot "bin\pager.ps1"

# --- output helpers --------------------------------------------------------
function Log  ($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok   ($msg) { Write-Host "    OK $msg" -ForegroundColor Green }
function Warn ($msg) { Write-Host "    !  $msg" -ForegroundColor Yellow }
function Die  ($msg) { Write-Host "    ERROR: $msg" -ForegroundColor Red; exit 1 }

# Get the version string from a native command (e.g. `ssh -V`, `git --version`)
# without exploding under $ErrorActionPreference="Stop" when the command writes
# to stderr (ssh -V writes to stderr by design). Returns "" on any failure.
function Get-NativeVersion {
    param([scriptblock]$Cmd)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = ""
    try {
        $captured = & $Cmd 2>&1
        $out = ($captured | Out-String).Trim()
    } catch {
        $out = ""
    } finally {
        $ErrorActionPreference = $prev
    }
    if (-not $out) { return "" }
    return ($out -split "`r?`n" | Select-Object -First 1).Trim()
}

# --- 1. dependencies via winget -------------------------------------------
Log "1/7 dependencies"

# Git: should already exist (install.ps1 checks), but verify.
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Die "git not on PATH. Reopen PowerShell after the winget install."
} else {
    $gitVer = (Get-NativeVersion { git --version }) -replace '^git version ',''
    if ($gitVer) { Ok "git $gitVer" } else { Ok "git installed" }
}

# OpenSSH client (built-in on Win10 1803+, but ensure it's installed).
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Log "Installing OpenSSH client (Windows Capability)..."
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction Stop | Out-Null
        Ok "OpenSSH client installed"
    } catch {
        Warn "Could not install OpenSSH client automatically: $_"
        Warn "Install manually: Settings -> Apps -> Optional features -> OpenSSH Client."
    }
} else {
    $sshVer = (Get-NativeVersion { ssh -V }) -replace '^OpenSSH_',''
    if ($sshVer) { Ok "ssh $sshVer" } else { Ok "ssh installed" }
}

# Python (needed for inventory YAML parsing + ~/.claude.json editing).
$pythonExe = $null
foreach ($candidate in 'python', 'python3', 'py') {
    $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
    if ($cmd) { $pythonExe = $cmd.Source; break }
}
if (-not $pythonExe) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Log "Installing Python via winget..."
        winget install --silent --accept-source-agreements --accept-package-agreements --id Python.Python.3.12
        $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
        foreach ($candidate in 'python', 'python3', 'py') {
            $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
            if ($cmd) { $pythonExe = $cmd.Source; break }
        }
    }
    if (-not $pythonExe) {
        Warn "python not found. Install from https://www.python.org/downloads/windows/"
        Warn "  pager will install; 'pager ssh' inventory parsing won't work until python is installed."
    } else {
        $pyVer = Get-NativeVersion { & $pythonExe --version }
        if ($pyVer) { Ok "python $pyVer" } else { Ok "python installed" }
    }
} else {
    $pyVer = Get-NativeVersion { & $pythonExe --version }
    if ($pyVer) { Ok "python $pyVer" } else { Ok "python installed" }
}

# --- 2. pager dir structure -----------------------------------------------
Log "2/7 logs dir"
New-Item -ItemType Directory -Force -Path "$PagerRoot\logs" | Out-Null
Ok "$PagerRoot\logs"

# --- 3. .env ---------------------------------------------------------------
Log "3/7 .env"
if (-not (Test-Path "$PagerRoot\.env")) {
    if (Test-Path "$PagerRoot\.env.example") {
        Copy-Item "$PagerRoot\.env.example" "$PagerRoot\.env"
    } else {
        New-Item -ItemType File -Path "$PagerRoot\.env" -Force | Out-Null
    }
    Warn "Created $PagerRoot\.env from template -- edit it to add real GH_TOKEN, etc. (optional)"
} else {
    Ok ".env already exists"
}

# --- 4. PowerShell $PROFILE wiring ----------------------------------------
Log "4/7 PowerShell `$PROFILE wiring"
$ProfileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $ProfileDir)) { New-Item -ItemType Directory -Force -Path $ProfileDir | Out-Null }
if (-not (Test-Path $PROFILE))    { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

$profileContent = Get-Content -Raw $PROFILE -ErrorAction SilentlyContinue
if ($null -eq $profileContent) { $profileContent = "" }

$marker = "# pager: auto-load"
if ($profileContent -notmatch [regex]::Escape($marker)) {
    # Use double-single-quoted here-string so $foo inside stays literal at write time.
    # Then we patch in $PagerRoot via -f format.
    $snippet = @'

# pager: auto-load .env and put 'pager' on PATH
$__pagerRoot = "{0}"
if (Test-Path "$__pagerRoot\.env") {{
    Get-Content "$__pagerRoot\.env" | ForEach-Object {{
        if ($_ -match "^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$") {{
            Set-Item -Path "Env:$($Matches[1])" -Value ($Matches[2].Trim().Trim('"').Trim("'"))
        }}
    }}
}}
function pager {{ & "{0}\bin\pager.ps1" @args }}
'@ -f $PagerRoot
    Add-Content -Path $PROFILE -Value $snippet
    Ok "Wrote pager wiring to $PROFILE"
    Warn "Run: . $PROFILE   (or open a new PowerShell) so the 'pager' function is available."
} else {
    Ok "$PROFILE already auto-sources pager"
}

# --- 5. claude.json trust -------------------------------------------------
# Delegates to `pager trust --repair`, which is the single source of truth
# for ~/.claude.json's projects state: stores forward-slash keys (matching
# claude's own format), collapses duplicate `hasTrustDialogAccepted` entries,
# and purges legacy single-char garbage from the splat-as-chars bug.
Log "5/7 Claude Code workspace trust"
if ($pythonExe) {
    $repairOutput = & $PagerBin trust --repair 2>&1
    foreach ($line in $repairOutput) {
        $s = "$line"
        if ($s -match '^TRUSTED:\s*(.+)$') {
            Ok "pre-trusted $($Matches[1])"
        } elseif ($s -match '^Removed ') {
            Warn $s
        } elseif ($s -match '^\(no changes\)') {
            Ok "already pre-trusted"
        } elseif ($s) {
            Write-Host "    $s" -ForegroundColor DarkGray
        }
    }
} else {
    Warn "python not found -- can't pre-trust. Claude will show its trust dialog on first run."
}

# --- 5b. PAGER_TRUST_PATHS (extra dirs to pre-trust) ----------------------
# Mirrors what linux/bootstrap.sh and macos/bootstrap.sh do. Honors either ':'
# or ';' as a separator -- ':' for parity with the Linux/Mac docs, ';' because
# it's the natural Windows PATH separator.
if ($pythonExe -and $env:PAGER_TRUST_PATHS) {
    Log "5b/7 PAGER_TRUST_PATHS extra trust"
    $extra = @($env:PAGER_TRUST_PATHS -split '[;:]' | Where-Object { $_ -ne "" })
    if ($extra.Count -gt 0) {
        $extraOutput = & $PagerBin trust --repair @extra 2>&1
        foreach ($line in $extraOutput) {
            $s = "$line"
            if ($s -match '^TRUSTED:\s*(.+)$') { Ok "pre-trusted $($Matches[1])" }
        }
    } else {
        Warn "PAGER_TRUST_PATHS is set but parsed empty"
    }
}

# --- 6. SSH key check (informational only) --------------------------------
Log "6/7 SSH key"
$sshKey = "$env:USERPROFILE\.ssh\id_ed25519"
if (-not (Test-Path $sshKey)) {
    Warn "No $sshKey. To create one without passphrase (recommended for headless flow):"
    Warn "  ssh-keygen -t ed25519 -f `"$sshKey`" -N '' -C `"$env:USERNAME@$(hostname)`""
} else {
    Ok "$sshKey exists"
}

# --- 7. autostart (Scheduled Task) ----------------------------------------
Log "7/7 autostart"
if ($NoAutostart) {
    Ok "autostart NOT registered (-NoAutostart). 'pager autostart enable' later to opt in."
} else {
    $taskName = "pager"

    # Remove any existing task before re-registering.
    try {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        Ok "Removed previous Scheduled Task '$taskName' to re-register cleanly"
    } catch {
        # No prior task -- fine.
    }

    # Decide which PowerShell to use. Prefer pwsh (7+) if available; else fall back to powershell (5.1).
    # Avoid PS7-only ?. operator for PS5.1 compatibility.
    $pwshExe = $null
    $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
    if ($cmd) { $pwshExe = $cmd.Source }
    if (-not $pwshExe) {
        $cmd = Get-Command powershell -ErrorAction SilentlyContinue
        if ($cmd) { $pwshExe = $cmd.Source }
    }
    if (-not $pwshExe) { Die "Neither pwsh nor powershell on PATH (unexpected on Windows)." }

    $action = New-ScheduledTaskAction -Execute $pwshExe `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PagerBin`" start default-boot"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartInterval ([TimeSpan]::FromMinutes(2)) `
        -RestartCount 3
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited

    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Description "pager - persistent Claude Code session" | Out-Null
    Ok "Scheduled Task '$taskName' registered (runs at user login)"
}

# --- final: defer to pager info -------------------------------------------
Write-Host ""
Write-Host "=================================================================="
Write-Host "  DONE."
Write-Host "  Open a new PowerShell (or run: . `$PROFILE) so 'pager' is on PATH."
Write-Host "  Then run 'pager info' any time to see this:"
Write-Host "=================================================================="
& $PagerBin info
Write-Host "=================================================================="
Write-Host "  Re-running this bootstrap is safe -- only does work that's missing."
Write-Host "=================================================================="
