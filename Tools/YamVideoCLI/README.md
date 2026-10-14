# yamvideoctl — local co-editing

`yamvideoctl` lets a local agent — Codex, Claude, a script — read and edit the project
that is open in YamVideo on the same Mac, while you keep editing it. Every agent edit goes
through the same command path as your own clicks and drags: it lands on the real
timeline, it is one ordinary undo step (credited to the agent in the Edit menu), and it
can never silently overwrite something you changed in the meantime.

`./build.sh` builds it next to the app as `build/yamvideoctl`. Add that folder to your
`PATH`, or call it by its full path.

## How it is kept local and safe

- YamVideo listens on a Unix-domain socket in a private temporary directory (`0700`, the
  socket `0600`). There is no network listener. A connection from any other user is
  refused, and the client refuses a socket owned by anyone else or reached via a symlink.
- A running app advertises itself in `~/Library/Application Support/YamVideo/AgentBridge/`.
  The record is only a pointer; the client checks that the instance answering is the one
  it names. Records from apps that are no longer running are ignored and cleaned up.
- Nothing is uploaded. Previews are PNG files in `~/Library/Caches/YamVideo/AgentArtifacts`;
  responses carry their paths, never image bytes. (A connected agent's model may still
  see what the agent chooses to send it.)
- Agents cannot replace source recordings, overwrite files without `overwrite`, save
  over a project file that changed on disk, or edit while you are mid-drag or exporting.

## The workflow

1. **Read** — `yamvideoctl state` returns the session, project and revision, every
   recording with stable IDs for its sections, blur areas and zooms, the export settings,
   the movie order and what you have selected.
2. **Plan** — work out commands against what you read.
3. **Apply** — send them with the revision you read:

   ```sh
   yamvideoctl apply --file edits.json --session S --project P --revision 12 --client Claude
   ```

   All commands in one request apply together or not at all. If anyone edited in the
   meantime you get `revision_conflict` with the current revision: read state again and
   replan. Nothing is merged for you.
4. **Follow** — `yamvideoctl events --after N` pages through what changed (100 at a time),
   including the owner's edits and finished jobs.

`--dry-run` validates and reports what would change — new IDs, zooms a cut would remove —
without committing anything.

## Commands (`edits.json`)

A list of commands, or `{"commands": [...], "sessionID": …, "projectID": …,
"expectedRevision": …, "label": "Tighten the intro"}`. `label` is what Undo will say.

Times: `at`, and zoom `start`, are **edited-recording seconds**; `trimSection` and section
ranges are **source seconds**. Add `"timeSpace": "movie"` to give `splitSection`/zoom times
in movie seconds instead — movie time is never assumed. Values are not clamped: anything
out of range is refused, with a message that says why. Times snap to whole source frames
and rectangles to even pixels, as the export does; `state` shows what was stored.
Rectangles are `{"x", "y", "width", "height"}` in source pixels, origin top-left.

| type | fields |
|---|---|
| `splitSection` | `clipID`, `at` |
| `trimSection` | `clipID`, `sectionID`, `start` and/or `end` |
| `deleteSection` | `clipID`, `sectionID` |
| `moveSection` | `clipID`, `sectionID`, `index` |
| `setSectionSpeed` | `clipID`, `sectionID`, `speed` (0.25–4) |
| `replaceSections` | `clipID`, `sections`: `[{id?, start, end, speed?}]` |
| `setCrop` | `clipID`, `rect` |
| `setAspect` | `clipID`, `preset`: Free, 16:9, 9:16, 1:1, 4:5, 4:3, 2.39:1 |
| `addBlurArea` / `updateBlurArea` / `removeBlurArea` | `clipID`, `areaID`, `rect` |
| `replaceBlurAreas` | `clipID`, `areas`: `[{id?, rect}]` |
| `addZoom` | `clipID`, `start`, `target` `{x, y}`, `hold`? (2), `level`? (2), `zoomID`? |
| `updateZoom` | `clipID`, `zoomID`, any of `start`, `hold`, `level`, `target` |
| `removeZoom` / `replaceZooms` | `clipID`, `zoomID` / `zooms` |
| `setMovieOrder` | `order`: every recording ID |
| `setIncludedInMovie` | `clipID`, `included` |
| `setMovieCanvas` | `canvas`: firstClip, widescreen, portrait, square |
| `setExportSettings` | `settings`: only the keys to change, e.g. `{"format": "gif"}` |
| `setSubtitles` / `clearSubtitles` | `clipID`, `path` |
| `addMedia` | `paths` (probed first) |
| `removeMedia` | `clipID` |
| `relinkMedia` | `clipID`, `path` of a moved copy of the same video |
| `setInputProfile` | `clipID`, `profile`: auto, standard, pocket3DLogM, hlg, pq (HLG/PQ only for files tagged so) |
| `importTechnicalLUT` | `clipID`, `path` of DJI's Pocket 3 D-Log M to Rec.709 `.cube` (checked first; needs `pocket3DLogM`) |
| `clearTechnicalLUT` | `clipID` (also turns Natural colour off) |
| `setColorCorrection` | `clipID`, `enabled` (Natural colour) |
| `setColorAdjustments` | `clipID`, any of `exposureEV` (−2–2), `warmth` (−1–1), `contrast` (0.5–1.5), `saturation` (0–2) |
| `resetColorAdjustments` | `clipID` |
| `copyColorAdjustments` | `clipID` (from), `targets`: recording IDs, `includeInterpretation`? (also copy profile and conversion) |
| `addBlurEffect` | `clipID`, `start`, `end` or `duration`? (3), `amount`? (0–80, 24), `mix`? (0–1, 1), `fadeIn`/`fadeOut`? (0.25, shrunk to fit), `enabled`?, `effectID`? |
| `updateBlurEffect` | `clipID`, `effectID`, any of `start` (keeps the length), `end`, `duration`, `amount`, `mix`, `fadeIn`, `fadeOut`, `enabled` |
| `removeBlurEffect` | `clipID`, `effectID` |
| `addMarker` | `clipID`, `time`, `label`?, `color`? (red, orange, yellow, green, blue, purple), `markerID`? |
| `updateMarker` / `removeMarker` | `clipID`, `markerID`, and for update any of `time`, `label`, `color` |
| `addGraphic` | `clipID`, `graphic`: `{kind, start, end, props, look?, id?}` |
| `updateGraphic` | `clipID`, `graphicID`, `graphic`: only the fields to change (`start` keeps the length; `props` replaces all props) |
| `removeGraphic` | `clipID`, `graphicID` |
| `replaceGraphics` | `clipID`, `graphics`, `graphicsStyle`? |
| `setGraphicsStyle` | `clipID`, `graphicsStyle`: any of `accent`, `panel` (shade, solid), `moveVideo`, `edge` (0–400), `look` (glass, ink, mix) |
| `importGraphics` | `clipID`, `path` of a graphics.json (the format `Tools/Graphics` uses) |

`yamvideoctl catalog` prints all of this from the app itself, with each field's type,
unit, range and default and an example per command. Effect starts and marker times
accept `timeSpace: "movie"` like zoom starts.

A section of an uncut recording has the recording's own ID. A split keeps the left
section's ID and reports the new right one in `createdIDs`.

## Other requests

| command | what it does |
|---|---|
| `undo` / `redo --transaction ID` | Undo or redo the named step. Refused (`history_conflict`) if another edit is now on top — an agent never undoes someone else's work by accident. |
| `preview --clip ID --time T [--composed] [--cropped] [--original]` | Renders one frame to a PNG and returns its path, tagged with the revision and source time it shows. `--composed` renders it as the owner's Preview plays it — crop, zoom, colour, blur areas and whole-frame effects — at the export's frame size. `--original` leaves the colour correction out. |
| `catalog` | Every command and request, described for an agent: fields, units, ranges, defaults, examples and conventions. |
| `analyze --kind silence\|zooms --clip ID` | Starts a job that proposes cuts or zooms for the revision it read. It applies nothing. |
| `export --path OUT (--clip ID \| --movie)` | Starts an export job of exactly the revision named. Editing is locked until it ends, and your Stop (⌘.) cancels it. |
| `job ID [--wait]` / `cancel ID` | Job status and result, or cancel it. |
| `save [--path FILE]` | Saves without a dialog: in place, to a first location, or — to a different path — as a copy with its own identity. |
| `reveal --clip/--section/--zoom/--effect/--marker/--graphic/--time` | Moves your view, only when asked; edits never do. |

## Errors

Every refusal is `{"ok": false, "error": {"code", "message", "retryable",
"currentRevision"?}}`. Codes: `revision_conflict`, `wrong_session` (the project was
reopened or replaced — read state again), `interaction_in_progress` (you are mid-drag),
`export_in_progress`, `agents_paused`, `history_conflict`, `invalid_command`,
`invalid_request`, `not_found`, `missing_media`, `unsupported_capability`,
`request_id_reused`, `request_in_progress`, `disk_conflict`, `resync_required`,
`session_full`. The CLI adds `app_not_running`, `multiple_instances` and
`untrusted_endpoint` for connection problems (exit status 2).

Every edit carries a `requestID` (the CLI makes one; pass `--request-id` to retry). A
retry with the same ID and payload returns the original answer and is never applied
twice; a timeout does not mean an edit was cancelled — retry with the same ID to find out.

## Try it

Open a project with at least one recording, then run `Tools/YamVideoCLI/demo.sh`. It
plays two clients that plan against the same revision: one commits, one is refused,
rereads and commits. Watch the timeline update, then press ⌘Z — each step undoes on its
own, and the Edit menu names who made it.

The wire protocol (newline-delimited JSON, protocol version 1) is defined in
`Sources/AgentProtocol.swift` and answered in `Sources/AgentRequests.swift`.
