#!/bin/sh
set -eu
cd "$(dirname "$0")"
# Prefer the standalone Apple tools without changing xcode-select globally.
if [ -d /Library/Developer/CommandLineTools/SDKs ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi
mkdir -p build
xcrun swiftc -O -warnings-as-errors -module-cache-path "${TMPDIR:-/tmp}/hdmi-lpcm-module-cache" HDMILPCM.swift -o build/hdmi-lpcm
