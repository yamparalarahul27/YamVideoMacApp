#!/usr/bin/env bash
# Copies the channel's Style.md and each project's Video.md from this Mac into
# docs/channel, so Git keeps them. Run it after each video, then commit.
#   docs/channel/sync.sh                 the footage folder ~/Desktop/DJIOsmoFootage
#   docs/channel/sync.sh FOLDER          another footage folder
# It only copies into docs/channel. It never changes the app's files.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LIBRARY="${YAMVIDEO_LIBRARY_PATH:-$HOME/Library/Application Support/YamVideo/Library}"
FOOTAGE="${1:-$HOME/Desktop/DJIOsmoFootage}"

cp "$LIBRARY/Style.md" "$HERE/Style.md"
echo "Style.md  <- $LIBRARY/Style.md"

mkdir -p "$HERE/videos"
shopt -s nullglob
for notes in "$FOOTAGE"/*" Video.md"; do
	cp "$notes" "$HERE/videos/"
	echo "videos/$(basename "$notes")"
done
