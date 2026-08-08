#!/usr/bin/env bash
# Builds YamVideo.app into ./build. No Xcode project needed — just the toolchain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/YamVideo.app"
DEPLOY_TARGET="14.0"

echo "==> Cleaning"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> Compiling Swift sources"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
ARCH="$(uname -m)"
xcrun swiftc \
	-parse-as-library \
	-O -whole-module-optimization \
	-target "${ARCH}-apple-macos${DEPLOY_TARGET}" \
	-sdk "$SDK" \
	-o "$APP/Contents/MacOS/YamVideo" \
	"$ROOT"/Sources/*.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Generating app icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if xcrun swift "$ROOT/Tools/makeicon.swift" "$BUILD/icon-1024.png" 1024 2>/dev/null \
	&& [ -s "$BUILD/icon-1024.png" ]; then
	for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
		"128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
		"512 512x512" "1024 512x512@2x"; do
		set -- $spec
		sips -z "$1" "$1" "$BUILD/icon-1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
	done
	iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
	rm -rf "$ICONSET" "$BUILD/icon-1024.png"
else
	echo "    (skipped — icon generator unavailable)"
fi

echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
	|| echo "    (ad-hoc signing failed; the app will still run locally)"

# Make Finder/Dock pick up the new icon and bundle metadata immediately.
touch "$APP"

echo
echo "Built $APP"
if command -v ffmpeg >/dev/null 2>&1; then
	echo "ffmpeg: $(command -v ffmpeg)"
else
	echo "NOTE: ffmpeg is not installed. Run: brew install ffmpeg"
fi
echo "Open it with:  open \"$APP\""
