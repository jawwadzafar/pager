# Changelog

All notable changes to **pager** are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.2] — 2026-05-19

Watchdog + `pager start` now refuse to thrash when claude isn't installed.

### Fixed
- **Watchdog no longer tries to restart claude every 70s when the claude binary isn't on PATH.** Previously: pgrep fast path fails → slow path calls `cmd_start` → claude binary missing → wrapper bash exits → next tick repeats. Result: `watch.csv` filled with `restart-failed` rows; on macOS, each attempt could trip TCC prompts. **Now:** if `command -v claude` fails inside the watchdog, we log a single `action=claude-missing` row and exit. No tmux session created, no restart loop, no TCC noise. As soon as the user installs claude, the next tick sees it and resumes normal restart behavior.
- **`pager start` now fails fast with an install hint if claude isn't on PATH**, instead of spinning up a tmux session whose `claude --remote-control ...` immediately fails and leaves a useless wrapper-bash session looking "alive." Same install message bootstrap prints in its soft-check (link to Claude Code site + the `npm install -g @anthropic-ai/claude-code` one-liner).

### Added
- New smoke test: `watchdog logs claude-missing (no restart loop)`. Test 9b runs the watchdog with `PATH=/usr/bin:/bin` (no claude), confirms `watch.csv` ends with `action=claude-missing` rather than `restart-failed`. 24/24 tests now.

### Notes
- This is purely a defensive behavior change — when claude IS installed (the normal case), the watchdog behaves identically to v0.6.1.
- If you see `claude-missing` rows in `~/.pager/logs/watch.csv`, the fix is: install Claude Code from https://claude.com/code, then `pager start`. Or `pager autostart disable` if you've decided you don't want pager running here at all.

## [0.6.1] — 2026-05-19

Contribution surface + safety nets.

### Added
- **Soft `claude` check** in `install.sh`, `linux/bootstrap.sh`, and `macos/bootstrap.sh`. Prints install instructions (https://claude.com/code, or `npm install -g @anthropic-ai/claude-code`) when Claude Code CLI isn't on PATH. Doesn't hard-fail — the user might have it on a not-yet-loaded PATH, or might want to install pager first and `claude` later.
- **Linux non-apt detection.** `linux/bootstrap.sh` now detects the user's package manager (dnf, yum, pacman, zypper, apk, emerge, xbps-install) and fails fast with a clear error + named distro family + contribution invite if it's not `apt-get`. No more half-installing on a Fedora box. Today's bootstrap continues to support Debian/Ubuntu/Pop!_OS/Mint/Raspberry Pi OS; other distros are tractable PRs (touch points listed in the error message).
- **`CODE_OF_CONDUCT.md`** — short pointer to Contributor Covenant 2.1 + a brief description of expectations and reporting.
- **README "Contributing" section** rewritten with: file-tour table, "Open opportunities" list naming specific PRs that would land cleanly (Linux distros, Homebrew formula, real-time log viewer, etc.), link to CONTRIBUTING.md and CODE_OF_CONDUCT.md.
- **README badges**: `PRs welcome` (links to CONTRIBUTING.md), `maintained: yes`. Existing badges retained.

### Changed
- `CONTRIBUTING.md` fully refreshed for the current repo layout (linux/, macos/, lib/autostart.sh, install.sh, the autostart subcommand). Adds explicit guidance about ASCII-only POSIX `sh` files (the v0.5.2 macOS Unicode regression motivated this rule). "Open opportunities" mirrors what's in the README.
- README tests badge bumped from "20/20" to "23/23" to match the actual smoke-test count.

### Notes
- No behavior change for existing users; everything in this release is doc + safety net. Re-bootstrapping is safe.
- Still no GitHub release cut for v0.6.0 or v0.6.1 — those are tagged in git only. v0.5.7 remains "latest" on the GitHub Releases page until the macOS verification on v0.6.x completes.

## [0.6.0] — 2026-05-19

**`pager autostart` subcommand + cleaner separation of "register the unit" vs "run the install."** Autostart stays on by default (that's the whole pitch — "Claude Code that never sleeps"), but you can now toggle it without re-bootstrapping, opt out at install time, and the docs are honest about the macOS TCC prompt cost.

### Added
- **`pager autostart [enable | disable | status]`** subcommand. OS-aware: on macOS installs the LaunchAgent + copies the .app bundle into `~/Applications` + ad-hoc codesigns + lsregisters; on Linux installs the systemd `--user` units + enables + starts. `status` returns 0 if enabled, 1 if disabled. Backed by the new `lib/autostart.sh`.
- **`lib/autostart.sh`** — shared functions (`autostart_enable`, `autostart_disable`, `autostart_status`) sourced by both bootstraps AND `bin/pager`, so the same code path runs whether autostart is being set up at install time or toggled later.
- **`--no-autostart` flag** on `macos/bootstrap.sh`, `linux/bootstrap.sh`, and `install.sh`. Pass-through from the curl one-liner with `sh -s -- --no-autostart`. Skip the LaunchAgent / systemd registration entirely; pager runs only when you type `pager start`.
- **macOS bootstrap pre-warns** about the TCC prompt storm right before triggering it, so users see the explanation in terminal scrollback as the dialogs pop. Tells them exactly which one to Allow (`tmux` App Management) and which are safe to deny (Full Disk Access, Music, Photos, Contacts, Documents).

### Changed
- **Default behavior stays the same**: autostart is registered at install time. `--no-autostart` opts out.
- **Refresh-but-don't-disable**: if a prior install had autostart enabled, re-bootstrapping refreshes the plist / units rather than removing them. Re-bootstrapping for an upgrade no longer silently kills your autostart.
- Bootstrap step count consolidated: macOS now ends at "10/10 autostart" (was 11/11), Linux at "8/8 verify" (was 10/10). The "install systemd units" and "enable linger" and "start service" steps fold into the single autostart step.
- `bin/pager` help: new "Autostart" section in `cmd_help` covers `enable`, `disable`, `status`.
- `macos/README.md` permission-prompt section reworded to honestly explain "this is what you'll see on first login" + `--no-autostart` as the escape hatch for users who don't want it.
- Website hero copy mentions the `--no-autostart` option without burying the lede on the default behavior.

### Notes
- This dev branch is not tagged until end-to-end verified on a real Mac. Merge to `main` + tag `v0.6.0` happens once that's confirmed clean.

## [0.5.7] — 2026-05-19

Revert the C launcher experiment + finally tell users honestly what to expect on first login.

### Changed
- **Reverted `macos/pager.app/Contents/MacOS/pager` from a compiled C Mach-O binary back to a shell shim.** The v0.5.6 hypothesis was that a Mach-O launcher would let macOS render the Login Items icon; real-Mac test after restart confirmed the icon still doesn't render. Same root cause as before — BTM tags ad-hoc-signed bundles as "Unknown Developer" regardless of executable type. Compiling in bootstrap was added complexity (clang dependency, build step, gitignored artifact) for zero functional gain, and may have been making the macOS TCC permission storm WORSE on first login by triggering more Gatekeeper checks against the Mach-O. Shell shim is simpler, fewer prompts, equally non-fixing of the icon.
- Removed `macos/pager.app/Contents/MacOS/pager.c` and the clang compile step in `macos/bootstrap.sh`. `.gitignore` entry for the compiled binary path also removed since the shim is now committed at that path.
- `Info.plist` `CFBundleVersion` bumped to `0.5.7`.

### Added
- **macos/README.md now has a clear "After first login: the permission-prompt storm" section** explaining what macOS prompts users will see on first run, which to **Allow** (the App Management / tmux one — that's the only critical one), and which to **Don't Allow** (Music, Photos, Contacts, Documents, Full Disk Access — pager doesn't need any of them). Honest framing: this is what unsigned-by-Apple-Developer-ID looks like on Tahoe; the same prompt storm hits Ollama, brew-services entries, and every other community-distributed background tool. **Choices are remembered, so subsequent logins are quiet — the avalanche is once per fresh install.**

### Accepting the icon limitation
- The Login Items icon never started rendering despite our six iterations (v0.5.0 .app bundle → v0.5.1 OG polish → v0.5.2 hotfix → v0.5.3 symlink → v0.5.4 AssociatedBundleIdentifiers → v0.5.5 copy instead of symlink → v0.5.6 Mach-O launcher). The BTM dump on a real Tahoe install showed `Parent Identifier: Unknown Developer`, which is the field that drives the "Item from unidentified developer" label *and* the fallback to a generic exec icon. Both are tied to whether the bundle is signed by an Apple Developer ID, not whether the bundle is structurally correct. **Without paying Apple $99/year, this is what macOS does for any community-distributed CLI.** Fine — pager works, the .app bundle is honest about what it is, the docs explain the situation. We're not chasing this further.

## [0.5.6] — 2026-05-19

**Mach-O launcher binary.** v0.5.5 finally got the bundle indexed (`mdfind` confirmed `kMDItemCFBundleIdentifier == "com.pager.agent"` returned the path), but Login Items still showed the generic exec icon. Real-Mac diagnostics with `qlmanage`:
- `qlmanage -t .icns` → succeeded, produced a 6.8 KB thumbnail (icon file is valid).
- `qlmanage -t pager.app` → **hung indefinitely**, required Ctrl+C.

That asymmetry pinpointed it: macOS Tahoe rejects icon rendering for bundles whose `Contents/MacOS/<executable>` is a shell script (`#!/bin/sh ...`), even when the .icns + Info.plist + LaunchServices indexing + `AssociatedBundleIdentifiers` are all correct. The bundle has to have a Mach-O binary launcher.

### Fixed
- **Added `macos/pager.app/Contents/MacOS/pager.c`** — a ~30-line C launcher that `execv`s `$PAGER_ROOT/bin/pager` (falling back to `~/.pager/bin/pager` if `PAGER_ROOT` is unset). Passes argv through unchanged.
- **Bootstrap step 10c compiles it** via `clang -arch arm64 -arch x86_64 -O2 -mmacosx-version-min=11.0` — universal binary that runs on both Apple Silicon and Intel, and loads on Sequoia 15+ / Tahoe 26+.
- The compiled binary replaces the old shell-script launcher at the same path. Codesign now signs a real Mach-O instead of a script.
- `clang` is a hard requirement now (already implied by Homebrew install, which Xcode CLT provides) — bootstrap fails fast with a clear message if it's missing.
- Removed `macos/pager.app/Contents/MacOS/pager` (the shell launcher) from the repo; replaced with `pager.c` source. The compiled binary is gitignored (built per install).
- `Info.plist` `CFBundleVersion` + `CFBundleShortVersionString` bumped to `0.5.6` to invalidate any cached metadata.

### Why the "Item from unidentified developer" label persists
BTM showed `Parent Identifier: Unknown Developer` in the dump. That's the label macOS attaches to all ad-hoc-signed (no Apple Developer ID) entries — and it's fundamental to BTM's grouping in the Login Items UI. **Without paying Apple $99/year for a Developer ID, that label cannot change.** The same label appears for Ollama, Homebrew `brew services` entries, and other ad-hoc-signed background items. The icon is separate from the label — v0.5.6 fixes the icon part; the label is just how macOS marks unsigned items.

### Migration
1. `cd ~/.pager && git pull`
2. `./macos/bootstrap.sh` — compiles the C launcher, copies the bundle to `~/Applications`, ad-hoc signs.
3. Verify:
   ```bash
   file ~/Applications/pager.app/Contents/MacOS/pager
   # expect: Mach-O universal binary with 2 architectures: [arm64] [x86_64]
   ```
4. Reopen System Settings → General → Login Items & Extensions. Quit System Settings entirely if it was open (`Cmd+Q`) before reopening.
5. The pager row should now show the actual icon. The label will still say "Item from unidentified developer" — that part is permanent without a paid Developer ID, see above.

## [0.5.5] — 2026-05-19

**The bundle was never actually getting indexed.** v0.5.4 added `AssociatedBundleIdentifiers` to the plist correctly, and ad-hoc codesigned the bundle correctly, and called `lsregister -f` correctly — but real-Mac diagnostics caught that `mdfind 'kMDItemCFBundleIdentifier == "com.pager.agent"'` returned **empty** after the install. LaunchServices/Spotlight never actually indexed the bundle. With no indexed bundle for that ID, `AssociatedBundleIdentifiers` has nothing to resolve to, and Login Items falls back to generic exec.

### Fixed
- **Bootstrap step 10c now COPIES the bundle into `~/Applications/pager.app`** as a real directory, instead of symlinking it. Root cause: Spotlight's indexer skips paths inside hidden directories, and apparently won't follow a symlink to index a target inside `~/.pager/`. Even after `lsregister -f` "succeeded," `mdfind` confirmed the bundle never landed in the metadata DB. Copying as a real directory at the standard `~/Applications` location fixes the indexing.
- Ad-hoc codesign now runs against the copy (not the canonical source).
- `lsregister -f` runs against the copy.
- The plist's `ProgramArguments` is updated post-render to point at the copy too, so everything routes through the indexable path.
- `pager uninstall` switched from `rm -f` to `rm -rf` on `~/Applications/pager.app` since it's a directory now (handles both legacy symlinks and the new real dir).

### Architecture note
The .app at `~/Applications/pager.app` is purely metadata — its `Contents/MacOS/pager` launcher reads `$PAGER_ROOT` from the LaunchAgent's `EnvironmentVariables` and `exec`s `$PAGER_ROOT/bin/pager`. So one source of truth remains: the canonical install at `$PAGER_ROOT`. The bundle copy at `~/Applications/` is what macOS looks at; the actual code lives at `~/.pager/bin/pager`.

### Migration
1. `cd ~/.pager && git pull`
2. `sfltool resetbtm` (only needed once if you didn't reset between iterations)
3. `./macos/bootstrap.sh` — this is the bootstrap that will actually populate the LaunchServices DB.
4. Verify the fix landed:
   ```bash
   mdfind 'kMDItemCFBundleIdentifier == "com.pager.agent"'
   # expect: /Users/you/Applications/pager.app
   ```
5. Reopen Login Items panel.

Logout + login is optional after v0.5.5 but may be needed if the Login Items panel doesn't live-refresh.

## [0.5.4] — 2026-05-19

**The actual fix for the Login Items icon.** v0.5.3 added the `~/Applications/pager.app` symlink and `lsregister -f`, but the icon still didn't render — real-Mac test showed generic exec icon persisting. Research revealed the missing piece is `AssociatedBundleIdentifiers`, a key added in macOS Ventura 13 specifically for the legacy-plist case (i.e., when an app installs a LaunchAgent into `~/Library/LaunchAgents/` instead of using the modern SMAppService API).

### Fixed
- **Added `AssociatedBundleIdentifiers` to `com.pager.agent.plist.template`** pointing at `com.pager.agent` (matches `CFBundleIdentifier` in the .app's `Info.plist`). This is what tells the Login Items UI to render the bundle's icon + display name instead of falling back to generic exec. Per Apple's developer forums, it's the canonical fix for the "Item from unidentified developer" issue on Ventura+.
- **Bootstrap step 10c now ad-hoc codesigns the bundle** (`codesign --force --sign - $PAGER_ROOT/macos/pager.app`). Ad-hoc signing (the `-` identity) needs no Apple Developer ID and no keychain. It improves Gatekeeper's icon-resolution reliability — unsigned bundles sometimes get treated as untrusted and the icon falls back to generic.
- **`lsregister -f` now runs against both the symlink AND the canonical path** (`~/Applications/pager.app` + `$PAGER_ROOT/macos/pager.app`). BTM's bundle-lookup is loosely documented; covering both paths maximizes the chance of a hit.
- **ProgramArguments restored to the canonical `$PAGER_ROOT/macos/pager.app/...` path** (was the symlink in v0.5.3). Icon resolution is handled separately via `AssociatedBundleIdentifiers`, so the symlink only needs to exist for LaunchServices indexing, not for the actual exec.

### Migration from v0.5.3
1. `cd ~/.pager && git pull`
2. `sfltool resetbtm` — clears the BTM Login Items cache (the stale "Item from unidentified developer" entry sticks otherwise).
3. `./macos/bootstrap.sh` — re-renders the plist with `AssociatedBundleIdentifiers`, ad-hoc signs, re-registers.
4. Reopen System Settings → General → Login Items & Extensions — the `pager` row should now show the actual pager icon + "pager" name.
5. If it still doesn't: log out and log back in (macOS sometimes only refreshes the Login Items panel on a fresh session).

### Notes
- Fresh installs via `curl | sh` on v0.5.4+ get the right setup from the start — no migration steps needed.
- Sources for this fix: Apple Developer Forums [thread 713493](https://developer.apple.com/forums/thread/713493) on AssociatedBundleIdentifiers, and [the n8felton write-up](https://n8felton.wordpress.com/2022/10/24/login-and-background-item-management-in-macos-ventura-13/) on Ventura's Login Items model. Cited in commit message.

## [0.5.3] — 2026-05-19

Real-Mac test of v0.5.0 showed that despite the `lsregister -f` of `$PAGER_ROOT/macos/pager.app`, the Login Items row still rendered the generic exec icon + "Item from unidentified developer" — even after `bootout` + `bootstrap`. Two root causes:

1. **macOS BTM caches Login Items metadata keyed by the LaunchAgent's label.** Even though `bootout` removed the runtime entry, the BTM record (which holds the rendered name + icon resolution) wasn't re-evaluated against the new ProgramArguments path.
2. **LaunchServices doesn't reliably scan `~/.pager/macos/`** (a hidden directory, non-standard location). `lsregister -f` worked at the moment we ran it, but BTM's metadata cache wasn't refreshed from the new registration.

### Fixed
- **Bootstrap step 10c now symlinks `~/Applications/pager.app → $PAGER_ROOT/macos/pager.app`** (creates `~/Applications/` if missing). The LaunchAgent plist's `ProgramArguments` is re-rendered at install time to point at the symlink path rather than the hidden `~/.pager` path. Two wins:
  1. `~/Applications` is a standard LaunchServices scan location — bundle metadata is indexed reliably.
  2. BTM keys its Login Items entry against the visible symlink path, so the next time `bootout` + `bootstrap` runs, BTM creates a fresh entry that reads the bundle's `Info.plist` + `AppIcon.icns`.
- Bundle version in `Contents/Info.plist` bumped to `0.5.3` to invalidate any cached metadata.
- `pager uninstall` now removes the `~/Applications/pager.app` symlink too.
- `macos/README.md` recovery table gained a "Login Items shows the wrong icon" row with the `sfltool resetbtm` fix path.

### Notes
- Existing v0.5.0-0.5.2 installs need a one-time `sfltool resetbtm` to clear the cached metadata, then `cd ~/.pager && git pull && ./macos/bootstrap.sh`. The reset is necessary because the BTM entry was created before the `.app` bundle existed in the repo; bootout alone doesn't refresh it.
- Fresh installs from `curl | sh` on v0.5.3+ get the right icon + name from the first bootstrap.

## [0.5.2] — 2026-05-19

Hotfix — fresh installs were broken under macOS `/bin/sh`.

### Fixed
- **`curl … | sh` was failing with `sh: line 72: TARGET?: unbound variable`** on macOS. Root cause: macOS `/bin/sh` is bash 3.2 in POSIX mode, and it misparses the byte sequence `$TARGET…` (variable followed by U+2026 horizontal ellipsis, UTF-8 `E2 80 A6`) — under some locale/encoding paths the parser treats the trailing bytes as if the variable reference were `${TARGET?}` (the POSIX "error if unset" form), then trips `set -u`. Stripped all non-ASCII characters from `install.sh` (`—` → `--`, `…` → `...`, `─` → `-`, box-drawing → ASCII). Also scrubbed `macos/pager.app/Contents/MacOS/pager` for consistency, even though it's a defensive fix there (no expansion would have triggered the actual bug).
- The fresh-install flow now works end-to-end on macOS Tahoe.

### Notes
- The audit only finds two `#!/bin/sh` files in the repo (`install.sh` and the .app launcher). Bash files (`bin/pager`, the bootstraps, `lib/sudo.sh`, etc.) are unaffected — bash full-mode parses UTF-8 bytes in variable contexts correctly; only bash-as-`sh` POSIX mode has the misparse.

## [0.5.1] — 2026-05-19

Content + polish pass on top of 0.5.0 — sharper positioning, defensive .gitignore.

### Changed
- **Headline + positioning rewritten** around the actual differentiator: persistence. "Claude Code that never sleeps." vs the old "Remote Claude Code sessions, from your phone." The hero, the meta description, the OG title + description, and the README intro all now lead with "no timeouts / no session expired / survives reboots" — the value Claude Code in the browser can't give you. Updated across:
  - `docs/index.html` `<title>`, `meta name="description"`, og:title, og:description, twitter:title, twitter:description.
  - `docs/index.html` hero `<h1>` + tagline. New copy contrasts pager against the browser failure mode explicitly.
  - `README.md` intro: top section is now a `## Claude Code that never sleeps.` heading + the same value prop.
  - Regenerated `docs/og-image.png` (1200×630): new layout with the "Claude Code that never sleeps." headline as primary text, proof-point subtitle, accent chip line at the bottom (Linux + macOS • one-line install • MIT). Icon column left, text column right.
  - `assets/scripts/build-favicons.py` updated so re-running the script regenerates the new card.

### Added
- **Comprehensive `.gitignore`** covering secrets (.env / .env.local / .env.*.local / keys / certs / known_hosts), Python build artifacts (`__pycache__`, `*.pyc`, eggs, build/dist, venvs, pytest/mypy/ruff caches), Node defensive entries (`node_modules`, npm/pnpm/yarn lockfile backups + debug logs), OS junk (.DS_Store + the full macOS noise set, Thumbs.db + Windows Recycle Bin, Linux `.fuse_hidden` / `.nfs*`), IDE configs (.vscode, .idea, JetBrains shelf, Sublime workspaces, Atom history), Vim/Emacs swap files + backup files, build outputs (*.o, *.a, *.exe, dist/, target/, out/), tmux/shell history leftovers, docs build outputs (defensive — Pages publishes docs/ as-is right now), and pager-specific forensic backups (`*.pager.bak.*`, `*.pre-install-*`, `pager-fresh-install.log`).
- Removed the previously-committed `assets/scripts/__pycache__/build_icns.cpython-314.pyc` (slipped in with 0.5.0 — now gone and gitignored).

## [0.5.0] — 2026-05-19

The "looks like a real app on the Login Items list" release. Real `.app` bundle, generated icon, watchdog refactor that finally silences the macOS TCC popup on healthy ticks, and a full SEO + favicon pass on the website.

### Added

**`pager.app` bundle + generated AppIcon.icns**
- `macos/pager.app/` is a real macOS app bundle: `Contents/Info.plist` (`CFBundleName=pager`, `CFBundleIdentifier=com.pager.agent`, `LSBackgroundOnly=true`, `LSUIElement=true`, `LSMinimumSystemVersion=15.0`), `Contents/MacOS/pager` (POSIX `sh` launcher that `exec`s `$PAGER_ROOT/bin/pager`), `Contents/Resources/AppIcon.icns` (multi-resolution: 16@2x, 32@2x, 128, 128@2x, 256, 256@2x, 512, 512@2x = 8 PNG-backed entries, ~47 KB total).
- `macos/launchd/com.pager.agent.plist.template` now points its `ProgramArguments` at the .app's launcher (`__PAGER_ROOT__/macos/pager.app/Contents/MacOS/pager`) instead of `bin/pager` directly. That's the trick that makes the **Login Items row show a real "pager" name + icon** instead of "Item from unidentified developer" + generic exec icon.
- `macos/bootstrap.sh` step 10c now `lsregister -f`s the bundle so LaunchServices picks up the icon + display name immediately (otherwise auto-discovery for bundles outside `/Applications` is unreliable on first install).
- `assets/scripts/build_icns.py` — Pillow + stdlib `struct` icon generator. Re-run to rebuild the icon: `python3 assets/scripts/build_icns.py`. No external image tools required (no `iconutil`, no `rsvg-convert`).

**Favicons + Open Graph card for the docs site**
- `assets/scripts/build-favicons.py` re-uses the same icon renderer to emit, into `docs/`:
  - `favicon.ico` (16/32/48 multi-resolution Windows-style)
  - `favicon-16.png`, `favicon-32.png` (modern browsers prefer explicit PNG)
  - `apple-touch-icon.png` (180×180, iOS Home Screen + macOS Safari tab)
  - `icon.svg` (vector, modern browser SVG-favicon path)
  - `og-image.png` (1200×630 social-share card: pager icon left, wordmark + tagline + "Linux + macOS" right)
- `docs/index.html` `<head>` now wires up: `icon`, `alternate icon`, `apple-touch-icon`, `mask-icon`, `theme-color`, `application-name`.

**SEO pass on `docs/index.html`**
- Title and meta `description` rewritten to put "Claude Code", "Linux", "macOS", "phone", "tmux", "claude --remote-control" in the first 160 chars.
- Added `meta name="keywords"`, `author`, `canonical link`.
- Full **Open Graph** set: `og:type`, `og:url`, `og:title`, `og:description`, `og:image` (+ width / height / alt), `og:site_name`, `og:locale`.
- Full **Twitter / X card** set: `twitter:card=summary_large_image`, title, description, image, image:alt.
- **JSON-LD structured data**: `SoftwareApplication` schema.org block with operatingSystem, license, codeRepository, image, offers (price=0).

**SVGs in the README too**
- `README.md` now embeds the `assets/flow.svg` + `assets/flow-dark.svg` pair (via `<picture>`) directly below the "Why this exists" line — matches the visual storytelling of the docs site without having to leave GitHub.
- New `assets/icon.svg` (square vector version of the app icon) is also committed for parity.

### Changed

**Watchdog: pgrep-based liveness fast path**
- `cmd_watchdog` gets a second early-bypass right after the `.stopped` semaphore check. If `pgrep -f "claude .*--remote-control <session>"` finds a running process, the watchdog logs a `noop` row with the live PID + `rc_banner=true` and exits WITHOUT making any tmux call. On macOS this means the App Management TCC prompt ("tmux would like to access data from other apps") **fires at most once per restart, not every 70 seconds**. The slow path (full tmux diagnostic + restart-if-dead) still runs when pgrep finds nothing, so the test "watchdog restarts a dead session" still passes (it uses `PAGER_NO_REMOTE=1`, which intentionally skips the pgrep fast path).

**Dropped `brew install python@3.13`** *(rolled in from 0.4.1 — restating because users skipping straight to 0.5.0 should know)* — `macos/bootstrap.sh` step 2 is just `brew install tmux libyaml` now. Apple's `/usr/bin/python3` is used for the inline json/yaml/datetime work.

**Autostart docs rewritten** in `macos/README.md`. The "Autostart semantics — login vs boot" section now leads with the *recommendation*: enable macOS auto-login + disable FileVault on a dedicated rig. The LaunchDaemon footnote is shorter and clearly marked "out of scope." Matches the `CLAUDE.md` guidance that "LaunchAgent + auto-login is the pragmatic match."

### Notes
- Migrating from 0.4.x → 0.5.0: `cd ~/.pager && git pull && ./macos/bootstrap.sh`. Bootstrap will `lsregister` the new bundle and re-bootstrap the LaunchAgent pointing at the .app's launcher. After re-login (or `launchctl kickstart gui/$(id -u)/com.pager.agent`), the Login Items row should show a real `pager` icon + name.
- If the Login Items row still shows the old generic icon after upgrade, run `sfltool resetbtm` to clear the macOS Background Tasks Management cache, then re-bootstrap. (`pager uninstall` also walks you to that hint on macOS.)

## [0.4.1] — 2026-05-19

Quick follow-up to 0.4.0 — sharper install URL, POSIX-portable installer, drop the dead-weight brew python install.

### Changed
- **Install URL switched to `raw.githubusercontent.com`.** Same one-liner shape (`curl … | sh`) but the new URL is `https://raw.githubusercontent.com/jawwadzafar/pager/main/install.sh`. Advantages over the GitHub Pages URL: zero Pages build delay between a commit and the installer reflecting it, and one canonical source of truth.
- **`install.sh` is now POSIX `sh`-compatible**, not bash. Shebang changed to `#!/bin/sh`. Dropped `set -o pipefail` (kept `set -eu`), replaced `$'\033…'` ANSI literals with explicit `printf '\033'` capture. Runs cleanly under `dash`, `bash`, `ash`, and zsh's `sh`. The one-liner now uses `| sh` instead of `| bash`.
- **Dropped `docs/install.sh` + the `make sync-installer` target + the "installers in sync" smoke test.** No longer needed — `raw.githubusercontent.com` always serves the canonical `install.sh` directly.
- **Dropped `brew install python@3.13`** from the macOS bootstrap step 2. Real-Mac test in 0.3.x showed Apple's `/usr/bin/python3` ends up being used by `bin/pager` anyway (Homebrew's `python@X` formulae don't reliably create the unversioned `/opt/homebrew/bin/python3` symlink). Step 2 is now just `brew install tmux libyaml` — ~75 MB lighter and faster on first install.
- Linted under `shellcheck -s sh install.sh` plus the existing bash-mode pass on the other shell files. Smoke tests: 23/23 pass.

### Notes
- For `PAGER_BRANCH=v0.4.1 …` to actually pin against a specific release, the maintainer needs to push annotated git tags. Tags are pushed alongside this release.

## [0.4.0] — 2026-05-19

The "now-it-feels-real" release: one-line installer, symmetric platform layout, cleaner repo top level.

### Added

**One-line installer** (`curl | bash`, à la Claude Code / rustup / homebrew)

```bash
curl -fsSL https://jawwadzafar.github.io/pager/install.sh | bash
```

- New `install.sh` at repo root + `docs/install.sh` (the Pages-served copy at `https://jawwadzafar.github.io/pager/install.sh`).
- Detects OS (`uname -s`), requires only `git`, clones into `$PAGER_HOME` (default `~/.pager`), then `exec`s the platform bootstrap. Idempotent on re-runs (does a `git pull --ff-only` then re-bootstrap).
- Env overrides: `PAGER_HOME`, `PAGER_BRANCH` (e.g. pin to a tag), `PAGER_REPO` (e.g. fork).
- Fresh-Mac and fresh-Linux failure modes are friendly: missing `git` prints the exact install command (`xcode-select --install` / `sudo apt-get install -y git`).
- `make sync-installer` keeps `install.sh` ↔ `docs/install.sh` byte-identical; new smoke test `installers in sync (root ↔ docs)` runs `diff -q` between them so a forgotten sync fails CI.

### Changed

**Symmetric platform layout** (`linux/` mirrors `macos/`)

```
pager/
├── install.sh              ← one-line entry point (NEW)
├── bootstrap.sh            ← thin OS-detecting shim (Linux | macOS)
├── linux/
│   ├── bootstrap.sh        ← was at repo root, now lives here
│   └── systemd/            ← was at repo root, now lives here
│       ├── pager.service
│       ├── pager-watch.service
│       └── pager-watch.timer
├── macos/
│   ├── bootstrap.sh        ← unchanged
│   └── launchd/com.pager.agent.plist.template
├── bin/pager
├── lib/{common,sudo}.sh
├── assets/
├── docs/                   ← website + install.sh copy
└── tests/, actions/, …
```

- Moved `bootstrap.sh` → `linux/bootstrap.sh`. Root `bootstrap.sh` is now an 8-line dispatcher that `exec`s the right one based on `uname -s`, so anyone with the old path in their muscle memory or in scripts still works.
- Moved `systemd/` → `linux/systemd/`. The unit templates with `__PAGER_ROOT__` substitution (added in 0.3.0) are unchanged in content.
- `Makefile` updated for the new paths: `service` and `watchdog` targets now `sed`-substitute `__PAGER_ROOT__` before installing the units (was a hard-coded path before).
- Smoke tests now also bash-syntax-check `install.sh`, `linux/bootstrap.sh`, `macos/bootstrap.sh`, and the installer sync. The "kill named session" / "watchdog restarts a dead session" pair now uses `pager kill` (the v0.2.2 verb that doesn't set the stop semaphore) — `pager stop` correctly stays-stopped now, which was breaking the old "expect watchdog to respawn" test.
- README install section rewritten: the `curl | bash` is now the primary install. The git-clone + per-OS bootstrap forms are kept as the "manual install" option. Expandable per-OS breakdowns preserved.
- Website hero install block: one big copy-able `curl | bash` line tagged "Linux + macOS" (warm amber pill, distinct from the Linux green and macOS blue tags from the per-OS cards). Walkthrough step 1 + the dedicated Install section also feature the one-liner; the per-OS cards just describe what each bootstrap does, with a "Or, the manual way" terminal block underneath. Added `Uninstall` block on the install page.

### Migration

- **From v0.3.x or earlier:** `cd ~/pager && git pull` will pick up the new layout. Your existing service / LaunchAgent paths still work because they point at `$__PAGER_ROOT/bin/pager`, which hasn't moved. To rename to `~/.pager` while you're at it: `pager uninstall && mv ~/pager ~/.pager && ~/.pager/install.sh`.
- **Fresh installs:** just `curl | bash`.

## [0.3.0] — 2026-05-19

### Added
- **`pager uninstall`** — the missing inverse of `bootstrap.sh`. Stops the service / LaunchAgent, removes the `~/.local/bin/pager` symlink, and strips the pager `.env` auto-source line from `~/.bashrc` / `~/.zshrc` / `~/.zprofile` / `~/.profile` (with a timestamped backup of each rc file). Deliberately leaves the repo and your `.env` in place — `rm -rf $PAGER_ROOT` is a separate, explicit step you do yourself. Pass `-y` / `--yes` to skip the confirmation prompt. OS-aware: `launchctl bootout` on macOS (covers the new `com.pager.agent` *and* the legacy `com.pager.session` / `com.pager.watch` labels for old installs), `systemctl --user stop+disable` on Linux.
- The macOS uninstall path also prints the optional `sfltool resetbtm` hint for clearing any stale Login Items entries and notification stacks.

### Changed
- **Install path is now agnostic of clone location, on both Linux and macOS.** Previously both the macOS LaunchAgent plist and the Linux systemd units hard-coded the install path (`__USER_HOME__/pager/...` on Mac, `%h/pager/...` on Linux), so a clone at any other path (e.g. `~/.pager`, `~/code/pager`) would silently produce broken service files. Replaced with a `__PAGER_ROOT__` placeholder that both bootstraps substitute at install time. The macOS LaunchAgent and the Linux systemd units now also export `PAGER_ROOT` so spawned children inherit the path.
- Linux bootstrap step 7 changed from a flat `install -m 644 …` of the three unit files to a `render_unit` function that sed-substitutes `__PAGER_ROOT__` first.
- The shell-rc auto-source line that bootstrap writes (`~/.zshrc` on macOS, `~/.bashrc` on Linux) now contains the literal `$__PAGER_ROOT` path of the current install instead of the hard-coded `$HOME/pager/.env` form. Idempotency check still matches any `pager/.env` shape, so re-running bootstrap from a new location is safe.
- README now recommends cloning to **`~/.pager`** (hidden, keeps `$HOME` tidy) instead of `~/pager`, with an explicit note that any clone path works. Old installs at `~/pager` continue to work — just re-run bootstrap from there.

### Notes
- Migrating from `~/pager` to `~/.pager`: easiest path is `pager uninstall` (from the current install), then `mv ~/pager ~/.pager`, then `~/.pager/macos/bootstrap.sh` (or `~/.pager/bootstrap.sh` on Linux). Bootstrap rewrites the LaunchAgent plist and shell-rc line with the new path.

## [0.2.3] — 2026-05-19

### Changed
- **One LaunchAgent instead of two on macOS.** Previously installed `com.pager.session.plist` + `com.pager.watch.plist`, which showed up as two separate rows in System Settings → Login Items & Extensions and triggered two "Background item added" notifications. Replaced with a single `com.pager.agent.plist` that runs `pager watchdog claude` at `RunAtLoad=true` + `StartInterval=70`. The watchdog's existing "session missing → spawn it" code path handles initial startup; subsequent ticks check health. Same behavior, half the system noise.
- macOS bootstrap step 10 now migrates any old two-agent install in place: it `bootout`s the old `com.pager.session` / `com.pager.watch`, removes their plist files, then installs the new `com.pager.agent`.
- `bin/pager`'s OS-aware paths (`cmd_doctor`, `cmd_help`, `_watchdog_disable`, `_watchdog_enable`) updated to reference `com.pager.agent`. `cmd_doctor` also warns if a stale `com.pager.session` or `com.pager.watch` plist is still on disk, prompting a re-bootstrap to migrate.
- macos/README.md, CHANGELOG, and the bootstrap verify banner all updated to match.

### Notes
- This is a clean migration — re-run `./macos/bootstrap.sh` on the Mac and the old agents are torn down before the new one is installed. No manual cleanup needed.
- The combined agent also has a side benefit on TCC: only one launchd-spawned context interacts with the tmux server at a time (the watchdog *is* the spawner of the session), which can reduce the cross-context TCC prompts macOS fires for "X would like to access data from other apps."

## [0.2.2] — 2026-05-19

Follow-up to 0.2.1 — adds `kill` and `restart` so users have the full set of session-control verbs, not just `stop` (which now also pauses the watchdog).

### Added
- **`pager kill [name|--all]`** — kills a session WITHOUT setting the stop semaphore. The watchdog will respawn at the next tick. This is the v0.2.0 `stop` behavior, now under its own verb. Use it when you want to force a fresh `claude` process and let the watchdog bring it back automatically.
- **`pager restart [name|--all]`** — kill + start, immediately. Doesn't wait for the watchdog. `--all` additionally bounces the watchdog process (`launchctl bootout`/`bootstrap` on macOS, `systemctl --user stop`/`start pager-watch.timer` on Linux) — useful when the watchdog itself is in a weird state. Always clears the stop semaphore.

### Mental model
- `start` — bring it up. Clears semaphore.
- `stop` — bring it down and keep it down. Sets semaphore.
- `kill` — bring it down, but the watchdog will resurrect it. Doesn't touch semaphore.
- `restart` — kick the session right now. Clears semaphore. `--all` also bounces the watchdog.

## [0.2.1] — 2026-05-19

Hotfix released a few hours after 0.2.0 based on first real-Mac feedback.

### Fixed
- **`pager stop` is now persistent.** Previously, `pager stop` killed the session but the watchdog fired ~70s later, saw the session was gone, and respawned it — `stop` was effectively a no-op short of rebooting. Now `pager stop` touches a `logs/.stopped` semaphore file that the watchdog checks BEFORE making any tmux calls; if present, the watchdog logs a `manually-stopped` row and exits cleanly. `pager start` removes the semaphore and resumes.
- This also fixes a macOS-specific pain: while pager is stopped, the watchdog no longer makes tmux calls, so the macOS App Management TCC prompt (`"tmux" would like to access data from other apps`) stops firing every 70 seconds.

### Added
- **`pager stop --all`** now also unloads the watchdog process itself (`launchctl bootout` on macOS, `systemctl --user stop pager-watch.timer` on Linux) — for "I want pager fully quiet, no ticks at all." Plain `pager stop` still pauses via the semaphore (lighter touch).
- macos/README.md gained a dedicated section explaining the tmux TCC prompt, how to grant the permission permanently in System Settings, and the `pager stop` semantics as a way to silence pager without uninstalling.

## [0.2.0] — 2026-05-19

macOS support — pager now runs natively on **macOS Tahoe 26** and **Sequoia 15**, both Apple Silicon and Intel.

### Added

**macOS bootstrap**
- New `macos/bootstrap.sh` — idempotent installer that mirrors the Linux bootstrap step-for-step. Detects arch (`arm64` → `/opt/homebrew`, `x86_64` → `/usr/local`), installs Homebrew if missing, then `brew install tmux libyaml python@3.13` and (optional) `brew install hudochenkov/sshpass/sshpass`.
- `pyyaml` installed via `python3 -m pip install --user --break-system-packages` with a cascade fallback to plain `--user` for older pip — needed because Homebrew's `pyyaml` formula was disabled 2024-10-06 and modern Homebrew Python enforces PEP 668.
- Wires `~/.zprofile` (`brew shellenv` + `~/.local/bin` PATH) and `~/.zshrc` (pager `.env` auto-source) instead of `~/.bashrc` / `~/.profile`.
- `macos/launchd/com.pager.session.plist.template` + `macos/launchd/com.pager.watch.plist.template` — LaunchAgents replacing `pager.service` + `pager-watch.timer`. Templates substitute `__USER_HOME__` and `__BREW_BIN__` at install time (launchd doesn't expand `$HOME`).
- Modern `launchctl bootstrap gui/$(id -u)` + `bootout` syntax for load/unload (not the legacy `load`/`unload`).
- Session agent uses `KeepAlive { SuccessfulExit = false }` — restart on failure only, matching the Linux `Restart=on-failure` semantics.
- Watch agent uses `StartInterval=70` to mirror the existing systemd timer cadence.

**`bin/pager` cross-platform**
- New `PAGER_OS` runtime detection (`mac` or `linux`) with branching in `cmd_doctor` (`Services` section uses `launchctl print gui/$UID/...` on macOS) and `cmd_help` (`Service` block shows the right command names per OS).
- `cmd_doctor` linger check is replaced on macOS with an informational `autostart: at login (LaunchAgent — no boot-time equivalent on macOS)` line.
- New portable helpers `file_mode()` (replaces `stat -c '%a'`) and `date_to_epoch()` (replaces `date -d`) built on `python3`, fixing silent BSD-coreutils failures on macOS.

**Docs**
- Root `README.md` install section split into **Linux (`apt`)** and **macOS (`brew`)** with two one-command install lines, expandable per-OS step-by-step breakdowns, and a platform badge update.
- New `macos/README.md` covering: supported versions, what the bootstrap does, **macOS permissions you'll be asked for** (Mac password, Xcode CLT, Background Items toggle, firewall apps), what to do if a prompt is denied, login-vs-boot autostart caveat, common operations, uninstall recipe.
- Website (`docs/index.html` + `docs/style.css`) refreshed: cross-platform tagline, two-OS install card grid, OS pill badges (Linux green / macOS blue), retro CRT touches — phosphor glow on the headline, subtle scanline + vignette overlay on the hero, glow on `✓` marks, drop-shadow on the new flow illustration.
- New SVG `assets/flow.svg` (+ `flow-dark.svg`) — companion to the pager logo, showing the full flow: CRT monitor → signal waves → phone, in the same green-screen + chunky-bezel aesthetic. Shipped to `docs/` for the website too.

### Changed

- Platform badge in README now reads `Linux | macOS`.
- Diagram in README + website: `Linux box` → `Your machine`.
- Feature cards on the website: explicit "Linux + macOS" entry; service/watchdog cards mention both backends.

### Notes

- macOS autostart is at **login**, not at boot — LaunchAgent semantics. For closer-to-linger behavior, enable macOS auto-login (incompatible with FileVault). A LaunchDaemon for true boot-time start is intentionally out of scope.
- `~/Library/LaunchAgents/com.pager.*.plist` ownership and `chmod 644` are required for launchctl to load them; bootstrap enforces this.
- The macOS bootstrap pulls `python@3.13` for forward-looking pip support but the actual `python3` on PATH may stay as Apple's CLT 3.9 (Homebrew doesn't always create the unversioned symlink). pyyaml is installed for whichever `python3` is on PATH, so `bin/pager`'s inline yaml parsing stays self-consistent.

## [0.1.0] — 2026-05-19

Initial public release.

### Added

**Core**
- Single binary `bin/pager` with subcommands: `start`, `attach`, `stop`,
  `status`, `url`, `ssh`, `run`, `watchdog`, `doctor` (alias `check`), `help`.
- `claude --remote-control` autostart via `systemd/pager.service`
  (user-level unit, oneshot + RemainAfterExit).
- `systemd/pager-watch.service` + `.timer` — 60-second self-healing
  watchdog. Detects whether the Claude process inside a session is alive
  and restarts it if dead. Appends a row to `logs/watch.csv` every tick
  so post-mortems are trivial.
- **`pager doctor`** — one-command health report. Walks deps, PATH
  resolution (catches the `/usr/bin/pager` BSD-pager / less alias shadow),
  `.env` perms, Claude Code workspace trust flag, both services, linger,
  watchdog tick freshness, running sessions. Exit non-zero if anything is
  broken, with a one-line fix hint on every failure. Run this first when
  something looks off.
- **Enriched `pager status`** — `NAME | CLAUDE | AGE | REMOTE CONTROL URL`
  table for "what's running and where do I jump in".

**Install & ops**
- **`bootstrap.sh`** — idempotent one-command install. Installs apt
  prereqs, creates `.env` from template (chmod 600, gitignored), wires
  `~/.bashrc` to auto-source `.env`, installs `pager` as a real user-PATH
  binary at `~/.local/bin/pager` (ahead of `/usr/bin/pager` on every
  shell type), pre-trusts `$HOME` in `~/.claude.json` so the autostart
  session isn't blocked by Claude Code's first-run "Trust this folder?"
  prompt, installs `pager.service` + `pager-watch.timer`, enables linger,
  starts the service, prints the live phone URL.
- **`Makefile`** — `install`, `service`, `watchdog`, `test`, `lint`,
  `check`, `bootstrap`, `status`, `url`, `logs`, `version`, `help`.
- **`lib/sudo.sh`** — bundled askpass helper. Reads `SUDO_PASSWORD` from
  `.env` and exports `SUDO_ASKPASS` so `sudo -A` runs unattended; falls
  back to interactive `sudo` if `SUDO_PASSWORD` is unset.

**Fleet / SSH**
- `inventory.yaml` schema for SSH host metadata; passwords referenced
  by env-var name only, never literal.
- `actions/uptime.sh`, `actions/restart.sh` — example remote action
  scripts streamed over SSH by `pager run`.

**Tests & quality**
- `tests/smoke.sh` — 20 checks, fully sandboxed (private tmux server +
  stub `claude` binary). Survives running inside a real tmux session
  (`$TMUX` / `$TMUX_PANE` unset, pre-existing `logs/watch.csv`
  preserved + restored). Run via `make check` (lint + tests).
- `.github/ISSUE_TEMPLATE/*` + `.github/PULL_REQUEST_TEMPLATE.md` —
  bug template leads with `pager doctor` output, PR template gates on
  `make check` + doctor green.

**Branding & docs**
- `assets/logo.svg` + `assets/logo-dark.svg` — vector logo (pager device,
  signal waves, wordmark). README auto-switches via
  `<picture media="(prefers-color-scheme: dark)">`.
- **Website** at [jawwadzafar.github.io/pager](https://jawwadzafar.github.io/pager/)
  — single-page pitch + quick-start. Lives in `docs/`, hand-rolled
  HTML/CSS, no build step.
- `README.md` — 60-second phone walkthrough, command reference, install
  modes, watchdog explainer, SSH setup, orientation notes for new Claude
  sessions.
- `CLAUDE.md` — context for future Claude Code sessions resuming work
  in this repo: hard rules (no secrets in chat, no passphrased SSH keys
  for headless, idempotency), how `lib/sudo.sh` works, the trust-prompt
  trap, where new things go.
- `CONTRIBUTING.md` — style + how-to-add-a-subcommand.
- MIT license.

### Security
- `.env` is the only place secrets live; chmod 600 and gitignored.
- No literal credentials in any committed file (verified by the
  `.env.example is template-only` smoke test).
- SSH key passphrase removal is recommended (required for the headless
  flow); bootstrap reports the state and prints the exact fix command
  rather than bypassing the user's passphrase interactively.
- Example hosts use `<box-ip-or-dns>` placeholder rather than any
  IP-looking string, so readers don't mistake an example for a real host.

[Unreleased]: https://github.com/jawwadzafar/pager/compare/v0.6.2...HEAD
[0.6.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.2
[0.6.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.1
[0.6.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.6.0
[0.5.7]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.7
[0.5.6]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.6
[0.5.5]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.5
[0.5.4]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.4
[0.5.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.3
[0.5.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.2
[0.5.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.1
[0.5.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.5.0
[0.4.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.4.1
[0.4.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.4.0
[0.3.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.3.0
[0.2.3]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.3
[0.2.2]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.2
[0.2.1]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.1
[0.2.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.2.0
[0.1.0]: https://github.com/jawwadzafar/pager/releases/tag/v0.1.0
