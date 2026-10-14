#!/usr/bin/env bash
# Two local clients edit the project open in YamVideo at the same time.
#
# Both plan against the same revision. One commits; the other is refused with
# revision_conflict, rereads state and commits on top. Nothing is lost, and every step
# is an ordinary undo step in the app, credited to "Codex" or "Claude".
#
# Needs a running YamVideo with at least one loaded recording. Everything it does can be
# undone with ⌘Z.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CTL="${YAMVIDEO_CTL:-$ROOT/build/yamvideoctl}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -x "$CTL" ] || { echo "Build first: ./build.sh"; exit 2; }

field() { python3 -c "import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {'d': d}))" "$1"; }

"$CTL" state > "$WORK/state.json" || { cat "$WORK/state.json"; exit 2; }
SESSION=$(field "d['result']['sessionID']" < "$WORK/state.json")
PROJECT=$(field "d['result']['projectID']" < "$WORK/state.json")
REVISION=$(field "d['result']['revision']" < "$WORK/state.json")
CLIP=$(field "next((c['id'] for c in d['result']['clips'] if c['status'] != 'probing' and c['media']), '')" < "$WORK/state.json")
[ -n "$CLIP" ] || { echo "Add a recording in YamVideo first, then run this again."; exit 2; }
WIDTH=$(field "next(c['media']['width'] for c in d['result']['clips'] if c['id'] == '$CLIP')" < "$WORK/state.json")
HEIGHT=$(field "next(c['media']['height'] for c in d['result']['clips'] if c['id'] == '$CLIP')" < "$WORK/state.json")
DURATION=$(field "next(c['editedDuration'] for c in d['result']['clips'] if c['id'] == '$CLIP')" < "$WORK/state.json")

echo "Project revision $REVISION, recording $CLIP (${WIDTH}x${HEIGHT}, ${DURATION}s edited)"

# Codex hides the top-left corner; Claude cuts the recording in the middle.
python3 - "$CLIP" "$WIDTH" "$HEIGHT" "$DURATION" "$WORK" <<'EOF'
import json, sys
clip, width, height, duration, work = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
json.dump({"label": "Hide the corner", "commands": [{"type": "addBlurArea", "clipID": clip,
    "rect": {"x": 0, "y": 0, "width": max(16, width // 5 // 2 * 2), "height": max(16, height // 6 // 2 * 2)}}]},
    open(f"{work}/codex.json", "w"))
json.dump({"label": "Cut in the middle", "commands": [{"type": "splitSection", "clipID": clip, "at": round(duration / 2, 3)}]},
    open(f"{work}/claude.json", "w"))
EOF

apply() { "$CTL" apply --file "$WORK/$1.json" --session "$SESSION" --project "$PROJECT" --revision "$2" --client "$3"; }

echo "Codex and Claude both apply against revision $REVISION…"
set +e
apply codex "$REVISION" Codex > "$WORK/codex.out" 2>/dev/null & CODEX=$!
apply claude "$REVISION" Claude > "$WORK/claude.out" 2>/dev/null & CLAUDE=$!
wait $CODEX; CODEX_STATUS=$?
wait $CLAUDE; CLAUDE_STATUS=$?
set -e

for who in codex claude; do
  printf '  %-7s %s\n' "$who:" "$(field "('committed at revision %d' % d['result']['revision']) if d['ok'] else ('refused: ' + d['error']['code'])" < "$WORK/$who.out")"
done

if [ "$CODEX_STATUS" -ne 0 ] || [ "$CLAUDE_STATUS" -ne 0 ]; then
  LOSER=$([ "$CODEX_STATUS" -ne 0 ] && echo codex || echo Claude)
  [ "$LOSER" = codex ] && NAME=Codex || NAME=Claude
  LOSER=$(echo "$LOSER" | tr '[:upper:]' '[:lower:]')
  CURRENT=$("$CTL" state | field "d['result']['revision']")
  echo "$NAME rereads state (now revision $CURRENT) and applies again…"
  apply "$LOSER" "$CURRENT" "$NAME" > "$WORK/retry.out"
  echo "  $NAME: $(field "'committed at revision %d' % d['result']['revision']" < "$WORK/retry.out")"
fi

echo
echo "Both edits are in the open project. In YamVideo, the Edit menu now offers"
echo "Undo for each one, credited to the client that made it."
