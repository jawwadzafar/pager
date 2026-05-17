#!/usr/bin/env bash
# Example action — quick host health snapshot.
set -e
echo "=== $(hostname) ==="
uptime
echo
free -h | head -2
echo
df -h / | tail -1
