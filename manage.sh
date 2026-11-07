#!/bin/sh
set -eu
base="$HOME/Library/Application Support/HDMILPCM"
agent="$HOME/Library/LaunchAgents/local.hdmi-lpcm.plist"
domain="gui/$(id -u)"
[ -x "$base/hdmi-lpcm" ] && [ -f "$base/config.json" ] && [ -f "$agent" ] || { echo 'No complete installation found.'; exit 1; }
command_name="${1:-status}"
case "$command_name" in
  status) exec "$base/hdmi-lpcm" status "$base/config.json" ;;
  policy) [ "$#" -eq 2 ] && { [ "$2" = idle ] || [ "$2" = reconnect ]; } || { echo 'Usage: sh manage.sh policy idle|reconnect'; exit 2; } ;;
  accept-mapping) [ "$#" -eq 1 ] || exit 2 ;;
  update)
    cd "$(dirname "$0")"
    sh ./build.sh
    # Check the new program before stopping the installed listener.
    ./build/hdmi-lpcm self-test
    ;;
  restart) ;;
  *) echo 'Usage: sh manage.sh status|policy idle|policy reconnect|accept-mapping|update|restart'; exit 2 ;;
esac
# Always restart the original listener when a configuration operation fails.
/bin/launchctl bootout "$domain/local.hdmi-lpcm" 2>/dev/null || true
resume() { /bin/launchctl bootstrap "$domain" "$agent"; }
trap 'resume' EXIT
case "$command_name" in
  policy) "$base/hdmi-lpcm" policy "$base/config.json" "$2" ;;
  accept-mapping) "$base/hdmi-lpcm" accept-mapping "$base/config.json" ;;
  update)
    cp "$base/hdmi-lpcm" "$base/hdmi-lpcm.previous"
    cp build/hdmi-lpcm "$base/hdmi-lpcm.new"
    chmod 700 "$base/hdmi-lpcm.new"
    mv "$base/hdmi-lpcm.new" "$base/hdmi-lpcm"
    cp HDMILPCM.swift build.sh uninstall.sh manage.sh "$base/"
    ;;
esac
printf '%s\n' 'Operation complete; listener restarting with the saved configuration.'
