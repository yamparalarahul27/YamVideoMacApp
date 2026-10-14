#!/bin/bash
# Builds YamparalaVideo and assembles a runnable .app bundle.
# Adapted from Pen-Fight-Stream's build script.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/Yamparala Video.app"

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/YamparalaVideo"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/YamparalaVideo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Regenerate the icon if the generator changed, then bundle it.
if [ ! -f Resources/AppIcon.icns ] || [ scripts/make-icon.swift -nt Resources/AppIcon.icns ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  swift scripts/make-icon.swift "$ICONSET" >/dev/null
  iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signing identity matters: macOS keys Screen Recording, Camera and
# Microphone grants to the signature. Ad-hoc signing changes the hash on every
# build, which silently revokes all three.
IDENTITY="${YV_SIGN_IDENTITY:-Apple Development: Created via API (PLGP9R7HJ2)}"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  codesign --force --sign "$IDENTITY" --identifier com.yamparala.video "$APP"
else
  echo "warning: '$IDENTITY' not found, falling back to ad-hoc (permissions will reset each build)"
  codesign --force --sign - --identifier com.yamparala.video "$APP" >/dev/null 2>&1
fi

echo "built: $APP"
