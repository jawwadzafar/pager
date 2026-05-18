# pager on macOS

macOS-specific bootstrap and supporting files for `pager`. **Linux users:** use the root `bootstrap.sh` instead.

## Supported macOS versions

- **macOS 26 Tahoe** (current)
- **macOS 15 Sequoia** (last)

Both Apple Silicon (M1+) and Intel are supported. The script branches on `uname -m` to find the right Homebrew prefix (`/opt/homebrew` vs `/usr/local`).

## Install

From the repo root:

```bash
./macos/bootstrap.sh
```

The script is **idempotent** — safe to re-run any time. It only does work that's still missing.

### What happens on first run

1. **Homebrew install (interactive).** If `brew` isn't already on the box, the script invokes the official Homebrew installer. That installer will prompt for your Mac password to set up `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel). After it finishes, the rest of the bootstrap continues automatically.
2. **`brew install tmux libyaml python@3.13`** — runtime deps.
3. **Optional: `brew install hudochenkov/sshpass/sshpass`** — only needed if you have `password_env:` hosts in `inventory.yaml`. Failures here are non-fatal (warning only).
4. **PyYAML via pip.** Homebrew's pyyaml formula was disabled in late 2024, so we install pyyaml via `pip3 install --user --break-system-packages pyyaml`. This is safe — pyyaml is a single small library, `--user` installs to your per-user site-packages, and `--break-system-packages` only bypasses the PEP 668 protective warning (no system Python is modified).
5. **`~/.zprofile`** gets a `brew shellenv` line and a `~/.local/bin` PATH prepend.
6. **`~/.zshrc`** gets the pager `.env` auto-source line.
7. **One LaunchAgent** is installed at `~/Library/LaunchAgents/com.pager.agent.plist` and loaded via `launchctl bootstrap gui/$(id -u)`. It runs `pager watchdog claude` at load (which spawns the session) and then every 70 seconds (which checks health + restarts if needed). One agent = one entry in Login Items.

After bootstrap finishes, open a new terminal (or run `source ~/.zprofile && source ~/.zshrc`) and you should be able to run `pager`, `pager url`, etc.

## Permissions you'll be asked for

macOS gates a few things behind dialogs that the script can't suppress (and shouldn't — they're how the OS keeps you in control). Here's what you'll see and what to do.

### During first install

| Prompt | Where | What it's for | If you click… |
|---|---|---|---|
| **"Enter your password to install Xcode CLT"** *(only if `git` / clang aren't already present)* | Terminal / GUI | Homebrew needs the Command Line Tools (git, clang, make). | **Allow & install.** Without it, `brew` itself can't run. Re-run `./macos/bootstrap.sh` after CLT finishes installing. |
| **"Password:"** (sudo, in Terminal) | Terminal | The Homebrew installer creates `/opt/homebrew` (or `/usr/local`) which needs root. Only happens once on a fresh Mac. | Type your **Mac login password.** If you cancel, brew install bails out. Re-run the script. |
| **"`/opt/homebrew` is not writable" warning** | Terminal | Sometimes appears on Macs with old brew installs. Bootstrap ignores it as long as `brew` is on PATH. | Usually safe to ignore; if `brew install` later fails, run `sudo chown -R "$(whoami)" /opt/homebrew`. |

No further OS-level dialogs from the script itself — every other step is **user-scope**: brew packages, `pip3 install --user`, writing to `~/Library/LaunchAgents/`, and `launchctl bootstrap gui/$(id -u)` all run as you.

### After the LaunchAgents are loaded

On macOS Ventura+ (Tahoe is fine here), the OS shows an informational notification when a new background item is installed — typically titled something like **"Background item added"**. **This is not a deny/allow prompt** — it's a heads-up. You can ignore it; pager keeps working.

If you click into that notification (or open **System Settings → General → Login Items & Extensions**), you'll see `pager` listed under **Allow in the Background**. The toggle defaults to **on**. **Don't turn it off** — that's the macOS-side kill-switch for the LaunchAgents.

### The "tmux would like to access data from other apps" prompt

This one is real and can be persistent. It's macOS Sonoma+'s **App Management** (cross-app data access) TCC permission, triggered because the watchdog LaunchAgent and the session LaunchAgent are technically two different launchd-spawned processes, and the watchdog's `tmux has-session` call touches the session's tmux server socket — macOS can interpret that as one app reaching into another's data.

**Click "Allow."** Don't click "Don't Allow" — that will silently break the watchdog (it won't see the session, will think it's dead, will try to restart it in a loop).

To make it stop asking forever, grant the permission permanently:

```text
System Settings → Privacy & Security → App Management → toggle tmux ON
```

If `tmux` isn't listed yet, run the watchdog manually once to trigger the prompt: `launchctl kickstart gui/$(id -u)/com.pager.agent`. Then it appears in the list and you can flip the toggle.

You may also need (less common): **Privacy & Security → Files and Folders → tmux → "All".**

If you just want pager to stop bothering you (e.g. you're going on vacation), use `pager stop`:

```bash
pager stop          # kills the session AND pauses the watchdog (semaphore)
pager stop --all    # also unloads the watchdog LaunchAgent itself
pager start         # resumes everything
```

`pager stop` writes a `.stopped` file under `logs/`; the watchdog checks for it before every tick and exits as a noop if present, so no tmux calls fire and no TCC prompts appear while pager is stopped. `pager start` removes the file and resumes.

If you want the OPPOSITE — kill the session but let the watchdog bring it right back (useful when you want a fresh `claude` process to load new MCP servers / settings):

```bash
pager kill          # kills session, watchdog respawns at next tick
pager restart       # kill + start immediately, don't wait for the watchdog
pager restart --all # also bounces the watchdog process (when it's in a weird state)
```

Mental model: **start** = up. **stop** = down and stays down. **kill** = down, watchdog resurrects. **restart** = kick.

### If you accidentally denied something

| What you denied | Symptom | How to recover |
|---|---|---|
| Xcode CLT install | `brew: command not found`, or step 1 of bootstrap warns Homebrew didn't install | Run `xcode-select --install` manually, then re-run `./macos/bootstrap.sh`. |
| Mac password to Homebrew | Bootstrap exits at step 1 | Re-run `./macos/bootstrap.sh` — type the password this time. |
| Background Items toggle (turned `pager` off) | `pager doctor` reports `com.pager.agent: not loaded`; tmux session disappears at next login | System Settings → General → Login Items & Extensions → scroll to **Allow in the Background** → toggle `pager` back on. Or just re-run `./macos/bootstrap.sh` (idempotent — it does `bootout` + `bootstrap` which re-registers cleanly). |
| Network access to claude (Little Snitch / Lulu users) | Claude can't reach claude.ai; no Remote Control URL appears | Allow `claude` outbound to `*.claude.ai` and `*.anthropic.com` in your firewall app. |

Pager itself never asks for Full Disk Access, Accessibility, Screen Recording, or any other TCC permission — none of its features need them. If you see a prompt naming one of those, something else on your Mac is asking (it's almost certainly not pager). Deny and report.

## What works

| Command | Status |
|---|---|
| `pager start` | ✅ Works (tmux + claude) |
| `pager attach` | ✅ Works |
| `pager url` | ✅ Works |
| `pager watchdog` | ✅ Works |
| `pager ssh` | ✅ Works once pyyaml is installed by bootstrap |
| `pager run` | ✅ Works (uses the same ssh path) |
| `pager doctor` | ✅ Works — Services section uses `launchctl print gui/$(id -u)/com.pager.*`; linger is replaced with an informational "autostart at login" line |
| `pager status` | ✅ Works (purely tmux-based, no service queries) |

`bin/pager` detects `uname -s` at runtime and branches between systemd (Linux) and launchd (macOS) for service-state queries. Two portable helpers (`file_mode`, `date_to_epoch`) replace `stat -c` / `date -d` calls that would have failed under BSD coreutils.

## Autostart semantics — login vs boot

Linux pager uses `loginctl enable-linger` so user services run at **boot** before any login. macOS LaunchAgents only run **after the user logs in**.

If your Mac is rebooting while no one is logged in, pager won't come up until login. For most personal Macs this is fine. If you need closer-to-linger behavior:

1. **Enable auto-login**: System Settings → Users & Groups → Login Options → Automatic login → choose your account. This is incompatible with FileVault (FileVault requires manual unlock before any user account is available).
2. **LaunchDaemon alternative**: out of scope for phase 1. A LaunchDaemon would run at true boot time as root and `sudo -u` into the user, but that requires changes to `bin/pager` and broader security review. Phase 3.

## Common operations

```bash
# Check that the LaunchAgent is loaded
launchctl print gui/$(id -u)/com.pager.agent
launchctl list | grep pager

# Restart the agent (e.g. after a config change)
launchctl bootout   gui/$(id -u)/com.pager.agent
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pager.agent.plist

# Trigger a watchdog tick manually (instead of waiting 70s)
launchctl kickstart gui/$(id -u)/com.pager.agent

# Tail launchd-level stdout/stderr (the `tmux pipe-pane` log at logs/claude.log is the pane content)
tail -F ~/pager/logs/launchd-agent.out ~/pager/logs/launchd-agent.err
```

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.pager.agent
rm ~/Library/LaunchAgents/com.pager.agent.plist
rm ~/.local/bin/pager
```

This leaves `~/pager/` and `~/pager/.env` untouched. Delete those manually if you want a full wipe.

## sshpass note

sshpass is removed from Homebrew core for security reasons. We install it from the `hudochenkov/sshpass` tap, which is the most established community tap and still functional on Tahoe/Sequoia even if its release cadence has slowed.

If the tap install fails (network, GitHub rate limit, future tap retirement), bootstrap continues with a warning. You can still use `pager ssh` against key-based hosts — only `password_env:` inventory entries require sshpass.

## Files in this folder

```
macos/
├── bootstrap.sh                              ← the installer
├── launchd/
│   └── com.pager.agent.plist.template        ← single combined LaunchAgent
│                                                (RunAtLoad=true + StartInterval=70)
└── README.md                                 ← you are here
```

The `.template` files have `__USER_HOME__` and `__BREW_BIN__` placeholders that bootstrap substitutes with absolute paths at install time. `launchd` doesn't expand `$HOME` or `~` — paths must be literal absolute.
