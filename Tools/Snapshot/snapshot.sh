#!/usr/bin/env bash
# Renders YamVideo's views offscreen with a sample recording. See main.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 RECORDING OUTPUT_DIR"; exit 2; }
BIN="$ROOT/build/yamvideo-snapshot"
mkdir -p "$ROOT/build"
SOURCES=()
for file in "$ROOT"/Sources/*.swift; do [ "$(basename "$file")" = "App.swift" ] || SOURCES+=("$file"); done
xcrun swiftc -target "$(uname -m)-apple-macos14.0" -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
	-o "$BIN" "${SOURCES[@]}" "$ROOT/Tools/Snapshot/main.swift" 2>&1 | grep -E "error" || true
# Its own table store, so imported conversions never reach the owner's.
# The graphics engine from the source tree, as the app bundle carries it.
YAMVIDEO_ROOT="$ROOT" YAMVIDEO_LUT_STORE="$(mktemp -d)" "$BIN" "$1" "$2"
