#!/bin/sh
set -eu
base="$HOME/Library/Application Support/HDMILPCM"
agent="$HOME/Library/LaunchAgents/local.hdmi-lpcm.plist"
# Stop future changes first. It is normal for bootout to fail if already stopped.
/bin/launchctl bootout "gui/$(id -u)/local.hdmi-lpcm" 2>/dev/null || true
if [ "${1:-}" = '--restore-format' ]; then
  "$base/hdmi-lpcm" restore "$base/config.json"
fi
rm -f "$agent"
echo "Automatic start removed. Private baseline, logs and program kept at: $base"
echo 'No speaker mappings or system audio preference files were written.'
