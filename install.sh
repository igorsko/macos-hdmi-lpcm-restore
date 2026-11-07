#!/bin/sh
set -eu
[ "$#" -eq 2 ] || { echo 'Usage: ./install.sh DEVICE_UID RATE_HZ'; exit 2; }
cd "$(dirname "$0")"
base="$HOME/Library/Application Support/HDMILPCM"
agent="$HOME/Library/LaunchAgents/local.hdmi-lpcm.plist"
[ ! -e "$base" ] && [ ! -e "$agent" ] || { echo 'Existing installation found. Stop and review it before replacing.'; exit 1; }
sh ./build.sh
umask 077
mkdir -p "$base" "$HOME/Library/LaunchAgents"
cp build/hdmi-lpcm "$base/hdmi-lpcm"
cp HDMILPCM.swift build.sh "$base/"
# Capture must succeed before launchd is configured. No audio writes here.
"$base/hdmi-lpcm" capture "$1" "$2" "$base/config.json"
cp uninstall.sh manage.sh "$base/"
/usr/bin/plutil -create xml1 "$agent"
/usr/bin/plutil -insert Label -string local.hdmi-lpcm "$agent"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$agent"
/usr/bin/plutil -insert ProgramArguments.0 -string "$base/hdmi-lpcm" "$agent"
/usr/bin/plutil -insert ProgramArguments.1 -string watch "$agent"
/usr/bin/plutil -insert ProgramArguments.2 -string "$base/config.json" "$agent"
/usr/bin/plutil -insert RunAtLoad -bool YES "$agent"
/usr/bin/plutil -insert KeepAlive -bool YES "$agent"
/usr/bin/plutil -insert ThrottleInterval -integer 30 "$agent"
/usr/bin/plutil -insert ProcessType -string Background "$agent"
/usr/bin/plutil -insert StandardOutPath -string "$base/service.log" "$agent"
/usr/bin/plutil -insert StandardErrorPath -string "$base/service-error.log" "$agent"
/usr/bin/plutil -lint "$agent"
/bin/launchctl bootstrap "gui/$(id -u)" "$agent"
echo "Installed. Inspect: $base/service.log"
