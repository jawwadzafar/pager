# pager — Makefile
# Standard OSS targets. `make help` lists them all.
#
# The pager binary is self-locating: it reads `$(dirname "$(readlink -f "$0")")/..`
# to find its repo root. So `make install` just symlinks the binary into PATH —
# the repo stays where it is, lib/sudo.sh and inventory.yaml stay relative.

PREFIX ?= $(HOME)/.local
BINDIR := $(PREFIX)/bin
SYSTEMD_USER_DIR := $(HOME)/.config/systemd/user
REPO_ROOT := $(abspath $(dir $(firstword $(MAKEFILE_LIST))))

# Resolve shellcheck location (optional dep)
SHELLCHECK := $(shell command -v shellcheck 2>/dev/null)
BATS       := $(shell command -v bats 2>/dev/null)

# Bash scripts to lint/test
BASH_FILES := bin/pager lib/sudo.sh bootstrap.sh install.sh \
              linux/bootstrap.sh macos/bootstrap.sh \
              tests/smoke.sh actions/*.sh

.PHONY: help install uninstall service service-uninstall \
        watchdog watchdog-uninstall \
        test lint check bootstrap status url clean logs version \
        sync-installer

help:  ## Print this help
	@printf '\033[1mpager\033[0m — make targets\n\n'
	@awk -F'## ' '/^[a-zA-Z_-]+:.*## / { \
	  split($$1, a, ":"); \
	  printf "  \033[36m%-22s\033[0m %s\n", a[1], $$2 \
	}' $(MAKEFILE_LIST)
	@printf '\nVariables:\n'
	@printf '  PREFIX=%s         (install prefix; bin/ goes to PREFIX/bin)\n' '$$HOME/.local'
	@printf '\n'

install:  ## Symlink pager into $$PREFIX/bin (no system files touched)
	@mkdir -p $(BINDIR)
	@ln -sfv $(REPO_ROOT)/bin/pager $(BINDIR)/pager
	@echo
	@echo "Installed: $(BINDIR)/pager → $(REPO_ROOT)/bin/pager"
	@echo "Make sure $(BINDIR) is on PATH (it usually is on Ubuntu/Debian)."
	@echo "Try: pager help"

uninstall:  ## Remove the symlink installed by 'make install'
	@if [ -L "$(BINDIR)/pager" ]; then \
	  rm -v "$(BINDIR)/pager"; \
	else \
	  echo "Not a symlink at $(BINDIR)/pager — leaving it alone."; \
	fi

service:  ## Install + enable the pager.service systemd user unit
	@mkdir -p $(SYSTEMD_USER_DIR)
	@sed -e 's|__PAGER_ROOT__|$(REPO_ROOT)|g' \
	  $(REPO_ROOT)/linux/systemd/pager.service > $(SYSTEMD_USER_DIR)/pager.service
	@chmod 644 $(SYSTEMD_USER_DIR)/pager.service
	@systemctl --user daemon-reload
	@systemctl --user enable --now pager.service
	@echo "Service installed and started. Status: $$(systemctl --user is-active pager.service)"
	@echo "For boot autostart (before any login), also run: sudo loginctl enable-linger $$USER"

service-uninstall:  ## Stop + remove the pager.service systemd user unit
	-@systemctl --user disable --now pager.service 2>/dev/null
	@rm -fv $(SYSTEMD_USER_DIR)/pager.service
	@systemctl --user daemon-reload
	@echo "Service removed."

watchdog:  ## Install + enable the pager-watch.timer (1-min health check)
	@mkdir -p $(SYSTEMD_USER_DIR)
	@sed -e 's|__PAGER_ROOT__|$(REPO_ROOT)|g' \
	  $(REPO_ROOT)/linux/systemd/pager-watch.service > $(SYSTEMD_USER_DIR)/pager-watch.service
	@sed -e 's|__PAGER_ROOT__|$(REPO_ROOT)|g' \
	  $(REPO_ROOT)/linux/systemd/pager-watch.timer   > $(SYSTEMD_USER_DIR)/pager-watch.timer
	@chmod 644 $(SYSTEMD_USER_DIR)/pager-watch.service $(SYSTEMD_USER_DIR)/pager-watch.timer
	@systemctl --user daemon-reload
	@systemctl --user enable --now pager-watch.timer
	@echo "Watchdog timer installed. Next tick in: $$(systemctl --user list-timers pager-watch.timer --no-legend 2>/dev/null | awk '{print $$1, $$2}')"
	@echo "State log: $(REPO_ROOT)/logs/watch.csv"

watchdog-uninstall:  ## Stop + remove the pager-watch timer/service
	-@systemctl --user disable --now pager-watch.timer 2>/dev/null
	@rm -fv $(SYSTEMD_USER_DIR)/pager-watch.timer $(SYSTEMD_USER_DIR)/pager-watch.service
	@systemctl --user daemon-reload
	@echo "Watchdog removed."

bootstrap:  ## Full setup (apt + env + service + linger) — same as ./bootstrap.sh
	@$(REPO_ROOT)/bootstrap.sh

test:  ## Run smoke tests
	@bash $(REPO_ROOT)/tests/smoke.sh

lint:  ## shellcheck all bash files (skipped silently if shellcheck not installed)
	@if [ -z "$(SHELLCHECK)" ]; then \
	  echo "shellcheck not installed — skipping. Install: sudo apt install shellcheck"; \
	  exit 0; \
	fi
	@$(SHELLCHECK) -x $(BASH_FILES)
	@echo "shellcheck: ok"

check: lint test  ## Run lint + test (the CI target)

status:  ## Show pager + service status
	@printf '\033[1mService:\033[0m '; systemctl --user is-active pager.service 2>/dev/null || echo "(not installed)"
	@printf '\033[1mLinger:\033[0m  '; loginctl show-user $$USER -p Linger 2>/dev/null || echo "(unknown)"
	@printf '\033[1mSessions:\033[0m\n'
	@$(REPO_ROOT)/bin/pager status | sed 's/^/  /'

url:  ## Print phone-accessible Remote Control URLs for all running sessions
	@$(REPO_ROOT)/bin/pager url --all

logs:  ## Tail the default 'claude' session log
	@tail -F $(REPO_ROOT)/logs/claude.log 2>/dev/null || echo "No log yet."

version:  ## Print version
	@grep -E '^## \[[0-9]+\.' CHANGELOG.md 2>/dev/null | head -1 | sed 's/^## //; s/^/pager /' \
	  || echo "pager (no CHANGELOG — pre-release)"

clean:  ## Remove generated logs
	@rm -fv $(REPO_ROOT)/logs/*.log 2>/dev/null || true
	@echo "Logs cleaned."

sync-installer:  ## Copy install.sh -> docs/install.sh (Pages publishes /docs)
	@cp -v $(REPO_ROOT)/install.sh $(REPO_ROOT)/docs/install.sh
	@chmod 644 $(REPO_ROOT)/docs/install.sh
	@echo "Synced. Commit both files together."
