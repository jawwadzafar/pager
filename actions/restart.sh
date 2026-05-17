#!/usr/bin/env bash
# Example action — restart a systemd service. Pass service name as $1.
# Usage: server-action <host> restart -- nginx
set -euo pipefail
SERVICE="${1:?service name required (e.g. server-action host restart -- nginx)}"
sudo systemctl restart "$SERVICE"
sudo systemctl status --no-pager "$SERVICE" | head -10
