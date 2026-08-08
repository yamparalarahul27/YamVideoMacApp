#!/usr/bin/env bash
# Builds a small CLI from the app's own logic files and runs the end-to-end checks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$ROOT/build/yamvideo-tests"
mkdir -p "$ROOT/build"

xcrun swiftc \
	-target "$(uname -m)-apple-macos14.0" \
	-sdk "$(xcrun --show-sdk-path --sdk macosx)" \
	-o "$BIN" \
	"$ROOT/Sources/Models.swift" \
	"$ROOT/Sources/Shell.swift" \
	"$ROOT/Sources/FFmpeg.swift" \
	"$ROOT/Sources/CropEditor.swift" \
	"$ROOT/Tests/main.swift"

"$BIN"
