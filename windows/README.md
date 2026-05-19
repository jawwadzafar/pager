# pager on Windows

**Status:** alpha (v0.7.0-alpha). Pure-native PowerShell install — no WSL. Tested
shape works on Windows 10/11 with PowerShell 5.1 (default) and PowerShell 7+.

This page is the Windows companion to the top-level [README](../README.md).
For the cross-platform pitch, walkthrough, and CLI reference, read that first;
this file is just the Windows-specific install / uninstall / troubleshooting.

---

## Install

```powershell
irm https://raw.githubusercontent.com/jawwadzafar/pager/main/install.ps1 | iex
```

That's it. Detects your shell, clones into `%USERPROFILE%\.pager`, installs
deps, wires `$PROFILE`, pre-trusts your home dir in `~/.claude.json`, registers
a `pager` Scheduled Task at logon.

After it finishes, **open a new PowerShell window** so `$PROFILE` reloads and
the `pager` function is on PATH. Then:

```powershell
pager info       # full state summary
pager url        # phone URL
pager doctor     # health check
```

### Don't want autostart?

```powershell
$env:PAGER_NO_AUTOSTART=1
irm https://raw.githubusercontent.com/jawwadzafar/pager/main/install.ps1 | iex
```

Skips the Scheduled Task registration. Opt in later with `pager autostart enable`.

### Pin to a specific tag

```powershell
$env:PAGER_BRANCH = "v0.7.0-alpha"
irm https://raw.githubusercontent.com/jawwadzafar/pager/main/install.ps1 | iex
```

### Manual install (from a fresh clone)

```powershell
git clone https://github.com/jawwadzafar/pager.git $env:USERPROFILE\.pager
cd $env:USERPROFILE\.pager
.\windows\bootstrap.ps1                    # full setup
.\windows\bootstrap.ps1 -NoAutostart       # skip the Scheduled Task
```

`bootstrap.ps1` is idempotent — re-run any time to update.

---

## What the Windows bootstrap does, step by step

1. **Dependencies via `winget`**: Git, OpenSSH Client (Windows Capability),
   Python 3.12. Skips anything already installed.
2. **`logs\` directory** at `%USERPROFILE%\.pager\logs`.
3. **`.env`** copied from `.env.example` if not present.
4. **PowerShell `$PROFILE`** gets a `# pager: auto-load` block that loads
   `.env` and defines `function pager { & "%USERPROFILE%\.pager\bin\pager.ps1" @args }`.
5. **Claude Code trust** pre-set in `~/.claude.json` for `$env:USERPROFILE`
   so `claude` doesn't show its "Trust this folder?" dialog on first run.
   - Step 5b: if `$env:PAGER_TRUST_PATHS` is set (semicolon-separated on
     Windows), each path also gets pre-trusted.
6. **SSH key informational check** — reports whether `~/.ssh/id_ed25519`
   exists. No action taken.
7. **Scheduled Task `pager`** registered to run at user logon, with
   battery-resilient settings (`-AllowStartIfOnBatteries`, restart on failure).

---

## Uninstall

**The clean way** — use `pager uninstall`:

```powershell
pager uninstall          # stops Scheduled Task + running session, cleans $PROFILE
Remove-Item -Recurse -Force $env:USERPROFILE\.pager   # optional: final wipe
```

`pager uninstall` is **non-destructive**: tears down the Scheduled Task and
strips the `# pager: auto-load` block from `$PROFILE` (with a timestamped
backup), but leaves `~/.pager` and `.env` in place. Add `-y` to skip the
confirmation prompt.

**Manual fallback** (if `pager uninstall` errors out):

```powershell
# 1. Kill the Scheduled Task
Unregister-ScheduledTask -TaskName pager -Confirm:$false -ErrorAction SilentlyContinue

# 2. Stop any running claude sessions started by pager
Get-ChildItem "$env:USERPROFILE\.pager\logs\*.pid" -ErrorAction SilentlyContinue | ForEach-Object {
    $procId = Get-Content $_
    try { Stop-Process -Id $procId -Force -ErrorAction Stop } catch {}
    Remove-Item $_ -Force
}

# 3. Strip the "# pager: auto-load" block from $PROFILE (manual edit)
notepad $PROFILE    # delete the pager block, save, close

# 4. Final wipe
Remove-Item -Recurse -Force "$env:USERPROFILE\.pager"
```

If you also want a fully clean `~/.claude.json` (forgetting the pre-trusted
`$env:USERPROFILE` entry):

```powershell
# from inside the repo, BEFORE the final wipe:
pager trust --reset $env:USERPROFILE
```

---

## How Windows-native session capture works (and what it can't do)

On Linux/macOS, pager runs claude inside **tmux**, which provides a PTY (real
terminal) and lets pager capture every byte of output to a log file. Claude
runs interactively and the URL ends up greppable in `logs/claude.log`.

On Windows there's no tmux equivalent shipped, and `Start-Process` forces a
hard choice:
- **Redirect stdout/stderr to files** → no TTY → claude bails to `--print`
  mode → exits with `Input must be provided...`. This is what v0.7.0-alpha
  and -alpha-1 did, and why claude died immediately.
- **Don't redirect** → claude gets a hidden console window with a real TTY,
  runs interactively in the background. But no log capture.

**v0.7.0-alpha-3 chooses option 2** plus a screen-buffer scraper:

| What | How |
|---|---|
| `pager start` | `Start-Process claude -WindowStyle Hidden` (no redirect). claude runs in a hidden console window. No taskbar entry, no visible UI. |
| `pager url` | Spawns a sidecar PowerShell that calls Win32 `FreeConsole` + `AttachConsole(claudePid)` + `ReadConsoleOutputCharacter` to scrape claude's hidden console screen buffer, regexes for the `claude.ai/code/session_...` URL, caches it to `logs\<session>.url`. |
| `pager status` / `pager stop` | Track by PID (unchanged). |
| `pager logs` | **Doesn't work.** Prints an explanation pointing here. |

### Known caveats

- **`pager logs` shows nothing.** No log file gets written. Use `pager url`
  for the URL and `pager status` for liveness. For full log tailing, use
  WSL2 + the Linux installer (tmux-backed).
- **The URL must be on claude's current screen when you first run `pager url`.**
  claude prints the Remote Control URL within ~5 seconds of startup. If you
  wait long enough that the URL scrolls off (lots of activity), the scraper
  can't see it anymore. Once `pager url` succeeds once, the URL is cached in
  `logs\<session>.url` and subsequent calls read from there.
- **No watchdog yet.** If claude crashes, the Scheduled Task's restart
  settings (RestartInterval=2min, RestartCount=3) is the only recovery
  mechanism. A proper user-timer watchdog is v0.8 work.

### When to use WSL2 instead

If you need any of: live log tailing, the inventory-driven SSH helper
(`pager ssh`), the watchdog, or the most-battle-tested code path — install
WSL2 and use the Linux installer there. Same pager, same commands, but
running on tmux + bash:

```powershell
wsl --install -d Ubuntu       # one-time, requires reboot
wsl                            # drop into Ubuntu
curl -fsSL https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh | sh
```

---

## Honest deviations from Linux / macOS

| Feature | Linux / macOS | Windows |
|---|---|---|
| Persistent terminal session | tmux | `Start-Process -WindowStyle Hidden`, stdout/stderr redirected to `logs\<name>.log`/`.err`, PID tracked in `logs\<name>.pid` |
| Attach | `pager attach` (full PTY via tmux) | `pager logs` — **read-only** tail of the log file |
| Watchdog | every-60-second user-timer / launchd watch agent that restarts dead sessions and writes `watch.csv` | Scheduled Task's built-in `RestartInterval=2min, RestartCount=3` is the only restart-on-crash for now |
| `pager kill` semantics | hard-kill, ignores the `.stopped` semaphore the watchdog respects | alias for `pager stop` (no watchdog, so no semaphore needed) |
| `pager ssh` inventory | full `yaml`-driven SSH multiplexer | not ported yet — Python + pyyaml are installed so it's a small follow-up |
| `pager doctor --fix` | safe auto-fixes for common problems | not ported yet — `pager doctor` reports state only |

**For full PTY-based attach**, install WSL2 and run the Linux installer there
instead. That gets you the bash `bin/pager`, tmux, the watchdog, and full
`pager attach`.

---

## Troubleshooting

### `pager status` shows session as DEAD right after `pager start`

See [Known limitations](#known-limitations) above. The smoking-gun output
is in `~/.pager/logs/claude.err`:

```
Input must be provided either through stdin or as a prompt argument when using --print
```

`pager start` in v0.7.0-alpha-2 detects this case within ~2.5 seconds, prints
the same explanation, and cleans up the stale PID file automatically.

### `ssh : OpenSSH_for_Windows_… RemoteException` during bootstrap (1/7)

PowerShell's `$ErrorActionPreference = "Stop"` treats native-command stderr
(which is where `ssh -V` writes its version banner) as a terminating error.
Fixed in v0.7.0-alpha-1 via a `Get-NativeVersion` helper. If you see it on a
fresh clone, you're on the broken alpha — re-run `irm | iex` to pick up the
fix.

### `irm ... | iex` fails with `Invoke-WebRequest: ParameterBindingException`

Usually means you tried `irm <url> | iex` outside PowerShell (e.g. in cmd.exe).
Open Windows Terminal or PowerShell first, then run the install command.

### `pager` not recognized after install

Open a **new** PowerShell window so `$PROFILE` reloads — the running window is
still on the old profile. Or run `. $PROFILE` to reload it in place.

### `pager start` says "claude not found on PATH"

You need [Claude Code](https://claude.com/code) installed separately:
```powershell
npm install -g @anthropic-ai/claude-code
```
Then re-run `pager start`. The pager installer doesn't pull `claude` because
it changes versions frequently and the npm install is the supported path.

### Scheduled Task didn't trigger on next login

```powershell
Get-ScheduledTask -TaskName pager | Get-ScheduledTaskInfo
```
If `LastTaskResult` is non-zero, check `logs\claude.err` for what crashed.
Most common cause: `claude` not installed, or `--cwd` defaulting to a
directory that was deleted. Re-register cleanly with:
```powershell
pager autostart disable
pager autostart enable
```

### Where everything lives

| What | Where |
|---|---|
| Repo / install root | `%USERPROFILE%\.pager` |
| Session log | `%USERPROFILE%\.pager\logs\<name>.log` |
| Session PID file | `%USERPROFILE%\.pager\logs\<name>.pid` |
| `.env` | `%USERPROFILE%\.pager\.env` |
| Profile wiring | `$PROFILE` (run `notepad $PROFILE` to inspect) |
| Scheduled Task | `Task Scheduler` → `pager` (top-level, not in a folder) |
| Trust state | `%USERPROFILE%\.claude.json`, key `projects.<path>.hasTrustDialogAccepted` |
