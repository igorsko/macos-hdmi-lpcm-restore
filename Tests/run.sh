#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
sh ./build.sh
./build/hdmi-lpcm self-test
if ./build/hdmi-lpcm unsupported-command >/dev/null 2>&1; then
  echo 'Invalid command unexpectedly succeeded'; exit 1
fi
# Audit the constrained CoreAudio write surface.
[ "$(grep -c 'AudioObjectSetPropertyData(' HDMILPCM.swift)" -eq 1 ]
sh -n build.sh install.sh uninstall.sh
printf '%s\n' 'PASS: command validation, single guarded CoreAudio setter, shell syntax'
