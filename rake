#!/bin/bash
# Builds (if needed) and runs Screenshot Rake. Pass --help for options.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$DIR/.build/ScreenshotRake"
if [ ! -x "$BIN" ] || [ "$DIR/ScreenshotRake.swift" -nt "$BIN" ]; then
  mkdir -p "$DIR/.build"
  echo "Building..."
  swiftc -O -swift-version 5 "$DIR/ScreenshotRake.swift" -o "$BIN"
fi
exec "$BIN" "$@"
