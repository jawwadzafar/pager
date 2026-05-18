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
7. **Two LaunchAgents** are installed at `~/Library/LaunchAgents/com.pager.{session,watch}.plist` and loaded via `launchctl bootstrap gui/$(id -u)`.

After bootstrap finishes, open a new terminal (or run `source ~/.zprofile && source ~/.zshrc`) and you should be able to run `pager`, `pager url`, etc.

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
# Check that the LaunchAgents are loaded
launchctl print gui/$(id -u)/com.pager.session
launchctl print gui/$(id -u)/com.pager.watch
launchctl list | grep pager

# Restart the session agent (e.g. after a config change)
launchctl bootout   gui/$(id -u)/com.pager.session
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.pager.session.plist

# Trigger the watchdog manually (instead of waiting 70s)
launchctl kickstart gui/$(id -u)/com.pager.watch

# Tail launchd-level stdout/stderr (the `tmux pipe-pane` log at logs/claude.log is the pane content)
tail -F ~/pager/logs/launchd-session.out ~/pager/logs/launchd-session.err
tail -F ~/pager/logs/launchd-watch.out  ~/pager/logs/launchd-watch.err
```

## Uninstall

```bash
launchctl bootout gui/$(id -u)/com.pager.session
launchctl bootout gui/$(id -u)/com.pager.watch
rm ~/Library/LaunchAgents/com.pager.session.plist
rm ~/Library/LaunchAgents/com.pager.watch.plist
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
│   ├── com.pager.session.plist.template      ← session LaunchAgent
│   └── com.pager.watch.plist.template        ← watchdog LaunchAgent (StartInterval=70s)
└── README.md                                 ← you are here
```

The `.template` files have `__USER_HOME__` and `__BREW_BIN__` placeholders that bootstrap substitutes with absolute paths at install time. `launchd` doesn't expand `$HOME` or `~` — paths must be literal absolute.
