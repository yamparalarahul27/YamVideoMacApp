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
| `setExportSettings` | `settings`: only the keys to change, e.g. `{"format": "gif"}`; `{"graphics": false}` exports without graphics |
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
| `addGraphic` | `clipID`, `graphic`: `{kind, start, end, props, look?, id?}`. An `endScreen` needs only its kind: it takes the last 20 s (or as much as is clear of other graphics, at least 5 s) and ends where the video ends; `props` `videos` (1 or 2), `side` (left, right: where the speaker sits), `kicker`, `title`. `state.clips[].endScreen` lists its boxes |
| `updateGraphic` | `clipID`, `graphicID`, `graphic`: only the fields to change (`start` keeps the length; `props` replaces all props; `transform` `{x, y, scale}` moves and scales it on the picture, only the keys given) |
| `removeGraphic` | `clipID`, `graphicID` |
| `replaceGraphics` | `clipID`, `graphics`, `graphicsStyle`? |
| `setGraphicsStyle` | `clipID`, `graphicsStyle`: any of `accent`, `panel` (shade, solid), `moveVideo`, `edge` (0–400), `look` (glass, ink, mix) |
| `setPublishInfo` | `clipID`, `publish`: only the keys to change, from `title`, `description`, `tags`, `category`, `chapters` (`[{time, title}]`), `thumbnail` (a path), `language`, `channel`, `design` (the thumbnail maker's design; only its keys given change), `endScreen` (the YouTube element for each end screen box: `circle` subscribe or channel, `channel`, `message`, `videos` `[{kind: bestForViewer|recentUpload|video|playlist, link, title}]`; only its keys given change). YouTube's limits show in `state.clips[].publishIssues`; `suggestedChapters` has chapters from markers and graphics |
| `importGraphics` | `clipID`, `path` of a graphics.json (the format `Tools/Graphics` uses) |
| `setAutoEditOptions` | `autoEdit`: only the keys to change, from `model` (`large-v3-turbo-q5_0`, `base.en`), `language` (a whisper code or `auto`), `cutStyle` (`tight`, `natural`, `review`), `captions` (`upload`, `burnIn`, `off`), `normaliseAudio`. `state.autoEdit` shows them, whether they were saved, and which models this Mac has |
| `importTranscript` | `clipID`, `path` of whisper-cli's full JSON (`-ojf`, with `-dtw` for word times) or `{model, language, words: [{text, start, end}]}` in source seconds |
| `clearTranscript` | `clipID` |
| `addShort` | `clipID`, `short`? with any of the keys below, and `id` to choose its id. A Short is a vertical 1080×1920 version of up to 3:00 of the recording for YouTube Shorts, with the same edit, graphics (laid out for 9:16; no end screen) and captions. With no times it covers a recording under 3:00 whole, else a minute from `start` (or 0) |
| `updateShort` | `clipID`, `shortID`, `short`: only the keys to change: `start`, `end` (edited seconds; 1 s to 3:00; Shorts do not overlap), `window` (`{x, y, width, height}` 9:16 in source pixels, `"speaker"` to centre it on the face Apple Vision finds, `"centre"` or null for the full height centred), `title`, `description`, `tags`, `hidden` (graphic ids left out), `placements` (`{graphicID: {x, y, scale}}` on the 1080×1920 canvas, null puts one back), `cover` (seconds into the Short), `panels` (`sheet`, `shade`, `split`), `captions` (`stepUp`, `over`, `hide`: burned-in captions while a graphic covers the lower half). `state.clips[].shorts` shows each with its window, the graphics in it and its issues |
| `removeShort` | `clipID`, `shortID` |
| `setScreen` | `clipID`, `path` of a screen recording, `offset`? (the screen's time at the recording's source time 0, seconds). The recording stays the master: its sound and cuts drive both pictures. A first screen starts in the screen layout with the bubble on the face Apple Vision finds |
| `updateScreen` | `clipID`, `screen`: only the keys to change: `offset`, `crop` (`{x, y, width, height}` in the screen recording's pixels, or null), `layout` (the base layout: `speaker`, `screen`, `split`), `bubble` (`corner` `topLeft`, `topRight`, `bottomLeft`, `bottomRight`; `size` 0.15–0.5 of the frame's height; `face` `{x, y}` in source pixels, `"speaker"` for Apple Vision, or null; `shape` `circle` or `rounded`; `corners` 0.05–0.45 of a rounded square's side) |
| `removeScreen` | `clipID` |
| `addLayout` | `clipID`, `layout`: `{start, end, layout}` in edited seconds, and `id` to choose its id. Layouts may touch but not overlap; a change eases over 0.4 s |
| `updateLayout` | `clipID`, `layoutID`, `layout`: only the keys to change (`start` alone keeps the length) |
| `removeLayout` | `clipID`, `layoutID` |
| `replaceLayouts` | `clipID`, `layouts`: every layout at once. `state.clips[].screen` shows the screen, its offset, the layouts and `covered` (where the screen file has footage) |

`yamvideoctl catalog` prints all of this from the app itself, with each field's type,
unit, range and default and an example per command. Effect starts and marker times
accept `timeSpace: "movie"` like zoom starts.

A section of an uncut recording has the recording's own ID. A split keeps the left
section's ID and reports the new right one in `createdIDs`.

## Other requests

| command | what it does |
|---|---|
| `undo` / `redo --transaction ID` | Undo or redo the named step. Refused (`history_conflict`) if another edit is now on top — an agent never undoes someone else's work by accident. |
| `preview --clip ID --time T [--composed] [--cropped] [--original]` | Renders one frame to a PNG and returns its path, tagged with the revision and source time it shows. `--composed` renders it as the owner's Preview plays it — crop, zoom, colour, blur areas, whole-frame effects and graphics — at the export's frame size, and lists each graphic showing with its box in `graphics`. `--original` leaves the colour correction out. |
| `manual` | The Agents Manual as text: the rules for work with the owner and a recipe for each common job. Read it first. Without a running app, it prints the copy in the app next to this tool. |
| `catalog` | Every command and request, described for an agent: fields, units, ranges, defaults, examples and conventions. |
| `analyze --kind silence\|zooms\|screenZooms\|autoEdit\|thumbnailFrames --clip ID [--style S] [--limit N]` | Starts a job that proposes cuts, zooms or thumbnail frames for the revision it read. It applies nothing. `autoEdit` proposes the cuts the project's cut style makes, pauses and stumbles from the transcript, each with its `reasons` (`pause`, `filler`, `repeat`, `restart`, `fragment`). `thumbnailFrames` gives the `limit` (default 8) best moments for the thumbnail, best first: Apple Vision scores each for `smile`, face `quality`, `eyes` open and `facing` the camera (0 to 1), with its edited `time` for the design, the `face` box in the recording's pixels, and `sheet`, a PNG of the faces to look at. It takes about 20 s for a 9-minute recording. |
| `transcribe --clip ID [--model M] [--language L]` | Starts a job that transcribes the recording on this Mac with whisper.cpp; the words land as one undo step (Transcribe). Defaults are the project's `autoEdit` answers. Refused with `unsupported_capability` when whisper.cpp or the model is missing: only the owner can download a model, in Auto Edit. |
| `transcript --clip ID` | The words in source seconds with `editedStart` (null when cut), the captions on the edited timeline, and the stumbles found. |
| `autoedit --clip ID [--style S] [--label TEXT]` | The whole auto edit as a job, by the project's answers: transcribe if the cut style or captions need words, cut, and set captions and loudness, as one undo step. With `review` nothing is cut and the cuts come back for the owner. |
| `thumbnail --clip ID [--save]` | Draws the recording's thumbnail from its design (the frame, the speaker cut out with Apple Vision, the title, tag and picture) and returns the PNG's path, whether a speaker was found and where. With `--save` it is also saved next to the recording (`savedPath`); then `setPublishInfo` with `thumbnail` uses it. Changes tried over the design without storing them go in the request's `design` (raw `request`). |
| `export --youtube --path FOLDER --clip ID` | Export for YouTube into an existing folder: the MP4, the captions as an SRT on the edited timeline, a 1280×720 thumbnail under 2 MB, the upload text and a JSON of it. With an end screen, both say when it starts and which element goes in which box (in pixels and fractions of the frame): YouTube's upload API cannot set end screen elements, so they are placed in YouTube Studio, by the owner or an agent in the owner's browser. Refused while `publishIssues` has a blocking issue. |
| `preview --clip ID --short ID --time T` | A Short as its viewer shows it: 1080×1920, its window, its graphics laid out for 9:16 and its burned-in captions, with each graphic's box. `T` is seconds into the Short. |
| `export [--youtube] --path OUT.mp4\|FOLDER --clip ID --short ID` | Exports a Short: a 1080×1920 MP4, or with `--youtube` into a folder its MP4, its captions as an SRT on its own timeline, a 1080×1920 cover JPEG, the upload text and a JSON (`short: true`; the related-video link to set in YouTube Studio, which the upload API cannot). Refused while `state.clips[].shorts[].issues` has a blocking issue. |
| `reveal --clip ID --short ID [--time T]` | Selects the Short and shows it in the owner's Short viewer. |
| `reveal --clip ID --layout ID` | Selects a screen layout and moves the playhead into it. |
| `export --path OUT (--clip ID \| --movie)` | Starts an export job of exactly the revision named. Editing is locked until it ends, and your Stop (⌘.) cancels it. A recording's graphics are drawn in; `state.graphicsRenderer.status` says whether this Mac can (`ready`, `needsNode`, `needsDownload`). Only the owner can download HyperFrames, so on `unsupported_capability` ask them, or export without graphics. |
| `job ID [--wait]` / `cancel ID` | Job status and result, or cancel it. |
| `save [--path FILE]` | Saves without a dialog: in place, to a first location, or — to a different path — as a copy with its own identity. |
| `reveal --clip/--section/--zoom/--effect/--marker/--graphic/--time` | Moves your view, only when asked; edits never do. |
| `library` | The Library, apart from any project: every idea with its title, notes, topic, links, images (with paths), stage (`idea`, `inProduction`) and linked project; the topics in use; the Library's own `revision` and top undo and redo steps. |
| `library apply --file EDITS.json --revision N [--dry-run] [--label TEXT]` | Library commands (`catalog`'s `libraryCommands`) as one undo step on the Library page, against the Library's revision: `addIdea {title, ideaID?, notes?, topic?, links?, paths?}`, `updateIdea {ideaID, title?, notes?, topic? ("" clears), links?}`, `removeIdea`, `addIdeaImages {ideaID, paths}`, `removeIdeaImage {ideaID, image}`, `linkProject {ideaID, path?}` (left out: the saved project open in Studio), `unlinkProject`. |
| `library undo` / `library redo --transaction ID --revision N` | Undo or redo your own Library step. |
| `reveal --idea ID` | Shows an idea on the Library page. |
| `scan --path FOLDER` | What Add Past Videos would find there: YamVideo projects with the Export for YouTube files made from them, exports whose project is missing, and what the Library already holds. Changes nothing; `importVideos {paths}` adds them, `addPost {ideaID, videoID, link?}` records where a video is published. |

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
