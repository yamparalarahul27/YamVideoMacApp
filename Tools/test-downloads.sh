#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build"
xcrun swiftc -target "$(uname -m)-apple-macos14.0" "$ROOT/Sources/Shell.swift" "$ROOT/Sources/Downloads.swift" "$ROOT/Tests/DownloadsSmoke/main.swift" -o "$ROOT/build/yamvideo-download-tests"
python3 "$ROOT/Tools/test-downloads.py" "$ROOT/build/yamvideo-download-tests"
