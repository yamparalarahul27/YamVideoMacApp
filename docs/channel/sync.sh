#!/usr/bin/env bash
# Copies the channel's Style.md and each project's Video.md from this Mac into
# docs/channel, so Git keeps them. Run it after each video, then commit.
#   docs/channel/sync.sh                 the footage folder ~/Desktop/Yamparala Media
#   docs/channel/sync.sh FOLDER          another footage folder
# It only copies into docs/channel. It never changes the app's files.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="${YAMVIDEO_LIBRARY_PATH:-$HOME/Library/Application Support/YamVideo/Library}"
FOOTAGE="${1:-$HOME/Desktop/Yamparala Media}"

cp "$LIBRARY/Style.md" "$HERE/Style.md"
echo "Style.md  <- $LIBRARY/Style.md"

mkdir -p "$HERE/videos"
shopt -s nullglob
# Video.md is next to each project, in its video folder (docs/footage-layout.md).
for notes in "$FOOTAGE"/*" Video.md" "$FOOTAGE"/*/*" Video.md"; do
	cp "$notes" "$HERE/videos/"
	echo "videos/$(basename "$notes")"
done
