# Graphics track — implementation plan

**Updated:** 2026-10-15. **Status:** G0 (the template engine), G1 part 1 (graphics in
the app: data, commands, preview, timeline, inspector), G1 part 2 (export with graphics
from the app), G2b (move and resize on the picture), the Publish panel, the thumbnail
maker and the end screen layout (G3) are implemented; see sections 8 to 14. Feature 6 of
section 6a (Auto edit options) is next. Phase 5 of
[local co-editing](local-coediting.md) merged first, so graphics use schema version 6.
**Parent plan:** [Local co-editing](local-coediting.md), section 7 ("Remotion and later
layers"). This plan is the layer design that section asks for, limited to graphic overlays.

## 1. Goal

The owner makes YouTube talking-head videos. A first video went through this flow:
cut in YamVideo, then 12 motion graphics (name plate, gear list, phone with app screens,
route, link, three rule panels, flow diagram, recap, end card) made outside the app with
HyperFrames and rendered over the app's export.

The owner wants those graphics **in the app**: see them when Play runs, select one,
change its text, timing, images and style, and export from the app. Example request:
"the side panel must come in as an overlay with a shade, not as a solid block".

Not in scope: free-form drawing, arbitrary HTML from users or agents, audio in graphics,
vertical (9:16) layouts (phase G3), and graphics in Movie mode (phase G3).

## 2. Decisions

1. **One HTML engine for preview and export.** Graphics are data. A fixed template engine
   (HTML, CSS, GSAP) in the app bundle draws them. A transparent `WKWebView` over the
   player shows them at the playhead; HyperFrames renders the same page for export. One
   engine means preview and export cannot drift, the same rule the blur and colour paths
   follow.
2. **HyperFrames, not Remotion, for this layer.** Section 7 of the parent plan names
   Remotion. HyperFrames fits better here:
   - The same page runs in `WKWebView` with no bundler.
   - It renders frame-exact and seekable output, including PNG sequences with alpha.
   - The first video already uses it.

   The rule from section 7 stays: there is no arbitrary JavaScript and no shell through the
   editing protocol. Agents send typed props for fixed template kinds.
3. **Graphics are per recording,** like zooms. Times are **edited-recording seconds**, like
   zoom `start`. A cut remaps them the same way `ClipTimeline.remap` remaps zooms.
4. **The video move is native.** The "move aside" effect slides the picture left while a
   side panel shows. It is a timed transform of the video, so it belongs to the app's
   renderers (Core Image in preview, an `overlay` x-expression in FFmpeg), like zooms. The
   HTML engine draws only graphics and the panel tint, never the video.
   The **frosted shade** (blur under the panel) is native too. A web blur cannot see the
   native video under the `WKWebView`, and an overlay rendered on its own has nothing
   under it to blur. So the app blurs the panel region with its blur engine, as a timed
   region that follows the panel slide, and the HTML adds only the tint. This uses the
   whole-frame blur work of phase 5. In `full` mode (outside the app) the engine uses CSS
   `backdrop-filter` for the same look.
   The **blurred fill** is native too. Moving the video left by 480 px leaves the right
   480 px empty. A larger (×1.3), blurred, darker copy of the same frame fills it, and the
   moved video's right edge fades into the copy over 220 px. Without it the far side is
   black, which the first renders showed under the frosted panel.
5. **Export composites per graphic.** Each graphic, and each panel span, renders on its own
   to a transparent clip of its own length. FFmpeg overlays each clip at its time. A change
   to one graphic re-renders only that graphic (cache key: template version + props +
   asset hashes + size + fps).

## 2a. Two kinds of ink

The owner likes the **ink** look (handwriting and drawn marks over a soft haze, as in
"writing over a talking head"). It can come from two sources, and both share the same
layout: the move aside, the blurred fill, the haze and the writing area.

1. **Template ink** (no hand work): the engine's `ink` look draws the same graphic kinds as
   handwriting and stroke-by-stroke marks. An agent or the owner fills in the props.
2. **Hand-drawn ink, no AI needed:** the owner draws on the black canvas of the YamDraw
   iPad app, which records the screen. YamVideo imports the recording as an **ink clip**:
   - **Key:** a `screen` blend (Core Image `CIScreenBlendMode` in preview, FFmpeg
     `blend=all_mode=screen` on a canvas-sized pad in export) makes black transparent and
     keeps white and coloured ink.
   - **Fields:** `source` path, `crop` (remove iPad edges; suggest it from the area where
     ink appears), `rect` (placement in the writing area), `sourceIn`/`sourceOut`,
     `start` (edited seconds), `speed` (0.25–8, to shorten slow drawing), `holdUntil`
     (keep the last frame), `fadeOut`.
   - It is native, so it needs no Node, HyperFrames or network. It is a timeline block and an
     inspector section like the other graphics. Agents can only help with timing.
   - Later: YamDraw exports strokes as data (points, times, colour), and the engine replays
     them as ink. Then each stroke can be recoloured, moved or retimed.

## 3. Data model

```
ProjectClip.graphics: GraphicsTrack?          // nil = no graphics (old projects)

GraphicsTrack
  style: GraphicsStyle
  items: [Graphic]                            // sorted by start, may overlap only across zones

GraphicsStyle
  accent: String         // "#F5C42C"
  panel: shade | solid   // shade = see-through gradient over the video (default)
  moveVideo: Bool        // slide the picture to the left half while a panel shows (default true)
  edge: Double           // soft edge of the shade next to the speaker, design px (default 170);
                         // the tint and the native blur both fade in over this width
  look: glass | ink | mix  // mix (owner's choice): panel kinds in ink, column kinds as glass cards

Graphic
  id: UUID
  kind: GraphicKind
  start: Double          // edited-recording seconds
  end: Double
  props: GraphicProps    // typed per kind, see below; beat times are seconds after `start`
  look: glass | ink ?    // overrides the style for this graphic
```

**Zones.** Each kind has a zone. **Column** kinds sit in the right third (x 1240–1860 on
a 1920×1080 design canvas, from the top). **Panel** kinds fill the side panel. Two column
graphics must not overlap in time. Two panel graphics must not overlap either. Panel
graphics closer than 1.0 s share one panel, so the shade does not flash between them.

**Kinds (template version 1).** These come from the first video:

| Kind | Zone | Props (beats in seconds after start) |
|---|---|---|
| `namePlate` | column | kicker, title, detail |
| `featureList` | column | kicker; items [{title, detail, icon, image?, at}] (a transparent product photo replaces the icon); stat? {label, from, to, suffix, at} |
| `titleCard` | column | kicker, title, detail; badges [text], badgesAt |
| `phoneScreens` | column | kicker, title, detail; screens [{image, at}] |
| `route` | column | kicker, from, to, drawAt; question?, questionAt; chips [{text, at}] |
| `link` | column | kicker, url, typeAt |
| `panelTitle` | panel | kicker, title, count (numbered badges), countAt |
| `rule` | panel | kicker, number, title, subtitle?; points [{text, at}]; demo? (below) |
| `checklist` | panel | kicker, title, footer; items [{text, at}] |
| `endCard` | column | kicker, title, detail, button |
| `endScreen` | screen | videos (1 or 2), side (left, right: the speaker's side), kicker, title (added in G3, section 14) |

`rule.demo` is one of: `image` {image, flag? {text, box {x, y, w, h} in image fractions,
at}}, `account` {rows [text], button, toast, tapAt, clearAt}, `flow` {nodes [{text, at}],
note? {text, at}, stamp? {text, at}, sweepAt}, `accessibility` {tilesAt, growAt,
contrastAt, tip {text, at}, chips [{text, at}], sample, breakAt, fixAt}.

`icon` is one name from a fixed set: camera, mic, app, link, check, none. Images are file
paths, with the same relink rule as source media; a missing image draws a grey frame and
the export refuses with `missing_media`.

## 4. The template engine

New folder `Resources/Graphics/`, copied into the bundle by `build.sh`:

- `graphics.js` — builds every graphic from one JSON object, then one paused GSAP
  timeline. It is synchronous and deterministic, has no timers and no network. It exposes
  `YamGraphics.load(json, {mode})`, `seek(seconds)` and `spans()`.
- `graphics.css` — tokens (`--accent`, panel shade) and the shared parts (glass card,
  kicker, phone frame, number, point, chip).
- `gsap.min.js`, `fonts/Inter-400/700.woff2` — pinned copies.
- `page.html` — the page shell. Modes: `preview` (all graphics, transparent page, seeked
  by the app), `unit` (one graphic or panel span, local time from 0, for export), `full`
  (graphics plus a `<video>` and `<audio>` root child, for HyperFrames full renders and for
  checks outside the app).

Motion vocabulary, the same for every kind: column graphics slide in 56 px from the right
(0.6 s, power3.out) and leave 36 px to the right (0.4 s). Contents rise 20 px (0.5 s).
Marks pop (back.out) or draw (stroke). The panel shade slides in 160 px and fades (0.8 s).
The video move uses smoothstep, `p² (3 − 2p)` over 0.8 s, in all three places (GSAP
custom ease, Core Image, FFmpeg expression) so that they agree to the frame.

## 5. App changes (phase G1)

| Area | Files | Change |
|---|---|---|
| Model and schema | `Models.swift`, `Timeline.swift` | `Graphic`, `GraphicsTrack`, `GraphicsStyle`, typed props. `graphics` is optional in `ProjectClip`. Schema version 6 (phase 5 took 5), with a gate that refuses graphics in older versions. Remap through cuts beside zooms; report `removedGraphics`. |
| Commands | `EditCommands.swift`, `ProjectCommandDispatcher.swift` | `addGraphic`, `updateGraphic` (patch), `removeGraphic`, `replaceGraphics`, `setGraphicsStyle`. Validate per kind: times in range, beats inside the graphic, no overlap in a zone, text length limits, known icons, image paths exist. Undo labels such as "Edit Graphic Text". |
| Agents | `AgentRequests.swift`, `Tools/YamVideoCLI`, `Tools/AgentBridge` | Wire types, `state` shows `graphics`, `reveal --graphic`, the activity highlight diff. |
| Preview | `Playback.swift`, new `GraphicsOverlay.swift` | `WKWebView` (transparent, no input) over `PlayerSurface`, fitted to `AVPlayerView.videoBounds`. The app calls `seek(previewTime)` on every playhead change and at 30 Hz while playing. Edits call `load` with new JSON. The move-aside transform goes into `renderFrame`. |
| Timeline | `TimelineView.swift` | A Graphics lane: one block per graphic, with column and panel blocks in two tones. Click selects; drag moves; edge drag changes the length. Snaps like zoom blocks. |
| Inspector | `InspectorView.swift` | Graphic section: kind, start, length, text fields, items with "appear after" times, image pickers, Delete, Show It. Recording section: Style (Panel: Shade / Solid; Move video aside; Accent). |
| Export | `FFmpeg.swift`, new `GraphicsRender.swift` | Find `node` like `ffmpeg`, with an explicit `PATH`. Render each changed unit to a cached PNG sequence with `hyperframes render --format png-sequence`, pinned version. Add each unit as an input with `-itsoffset`, `overlay=eof_action=pass` after zoom and scale, and before subtitles. Input indexes shift after the GIF palette. The move aside is its own ffmpeg stage (section 10). Progress: graphics 0–40 %, encode 40–100 %. As built: HyperFrames is downloaded into the app's folder on the owner's click rather than run through `npx`, and Movie exports leave graphics out (G3). |
| Build and tests | `build.sh`, `test.sh`, `Tests/main.swift` | Copy `Resources/Graphics`. Add the new logic files to `test.sh`. |

When `node` is missing, preview still works (it needs only WebKit). Export then says that
graphics need Node.js, and the Export sheet's **Draw graphics into the video** switch
exports without them.

## 6. Phases

- **G0 — template engine (now, new files only).** `Resources/Graphics/` engine with the 10
  kinds; `Tools/Graphics/assemble.mjs` writes a `full` or `unit` page from a JSON file;
  the first video's 12 graphics as JSON; a full render with shade B to prove parity with
  the hand-built version. No Swift changes, so no clash with phase 5.
- **G1 — in the app (after phase 5 merges).** Section 5. Load the first video's JSON
  into its project with `replaceGraphics`.
- **G2 — authoring, templates and the skill.**
  - "Add Graphic" menu with defaults per kind; duplicate; copy the project's images into a
    `<project>.assets` folder.
  - **Looks:** a saved `GraphicsStyle` (accent, panel, move video) that a new recording
    gets by default.
  - **Video templates:** a saved set of graphics with placeholder text, for a format that
    repeats (name plate, numbered rule panels, recap, end card). "Apply Template" adds them
    to a recording. Agents fill in the text and the times from the transcript.
  - **A Claude skill** in `.claude/skills/youtube-edit/`: transcribe, cut with the owner's
    saved choices (see the Auto edit options plan), plan graphics from the transcript, add
    them with `replaceGraphics`, export, and write the title, description and chapters. It
    uses only `yamvideoctl` commands, so every step lands in the app as an undo step.
- **G2b — move and resize on the picture (owner's request).** Select a graphic, then drag
  it or its corner handles in the Preview area. Each graphic gets an optional
  `transform {x, y, scale}` in design pixels; the engine applies it to the graphic's
  host, so preview and export agree. A drag is one gesture and one undo step
  (`updateGraphic`), with snapping to the column, the panel and the frame's safe area.
- **G3 — Publish panel (owner's request).** The project stores what YouTube needs:
  title, description, tags, chapters and a thumbnail. Chapters come from the graphics
  and markers. A preview shows the video as YouTube shows it: the watch page (player,
  title, channel, description with chapters) and a search-result card with the
  thumbnail at its real size. **Export for YouTube** writes the MP4, the `.srt`, the
  thumbnail and a text file. The upload itself stays with the owner or an agent in the
  owner's browser.
- **G3 — end screen (owner's request).** An `endScreen` kind for the last 5–20 s
  (YouTube's limit): the speaker moves into a smaller frame over a blurred backdrop, and
  the frame keeps empty, marked boxes exactly where YouTube's end screen elements sit
  (the Subscribe circle and one or two 16:9 video cards), so nothing covers them. The
  Publish panel stores which element goes in which box. YouTube's upload API cannot set
  end screen elements, so placing them stays a YouTube Studio step, by the owner or an
  agent in the owner's browser. Today's end card (top-right column) conflicts with those
  elements; the first video works around it by placing them in the left half.
- **G3 — thumbnail maker.** Pick a frame on the timeline; Apple Vision
  (`VNGenerateForegroundInstanceMaskRequest`) cuts the speaker out; a thumbnail
  template (large title, accent tag, optional icon or product photo, outline on the
  cut-out) renders at 1280×720 through the same engine. The first video's thumbnail was
  made this way by hand on 2026-10-15.
- **G3 — more.** 9:16 layouts for Shorts; graphics in Movie mode; caption styles.

## 6a. Next features, in order (2026-10-15)

The owner's priority after the first video. Start a new session with "start feature 1
from docs/plans/graphics-track.md".

1. **Export with graphics from the app (G1 part 2).** Done 2026-10-15; section 10.
2. **Move and resize on the picture (G2b).** Done 2026-10-15; section 11.
3. **Publish panel with a YouTube preview (G3).** Done 2026-10-15; section 12.
4. **Thumbnail maker (G3).** Done 2026-10-15; section 13.
5. **End screen layout (G3).** Done 2026-10-15; section 14.
6. **Auto edit options.** The choices Claude asked before the first edit become app
   settings stored in the project and readable by agents: transcript model (whisper.cpp
   large-v3-turbo q5 or base.en, downloaded only with consent) and language; cut style
   (Tight: pauses of 0.42 s or more cut to about 0.22 s, plus stumbles from the
   transcript; Natural: the silence sheet's defaults; Review each cut); captions (SRT for
   upload, burn in and SRT, none); audio normalised to -14 LUFS. Word timing needs
   `whisper-cli -dtw large.v3.turbo -nfa`.
7. **YamDraw ink clips.** Section 2a, item 2.
8. **Authoring (G2).** Section 6: Add Graphic menu, looks, video templates and the
   `youtube-edit` Claude skill.

## 7. Acceptance gates

- **Frame match:** for each kind, a G0 `full` render matches the hand-built composition
  of the first video at its hero frame.
- **Seek is deterministic:** in `preview` mode, the same time gives the same DOM state,
  in any seek order.
- **Remap:** a cut before a graphic moves it; a cut through its start removes it and
  reports it.
- **Move aside:** the Core Image and FFmpeg versions agree within 2 px at five sample
  times of the move.
- **Export:** marker pixels from a test graphic land in the expected box. An unchanged
  graphic is not rendered again. Cancel deletes partial output.
- **Agents:** an agent edit to one graphic is one undo step, refused on a stale revision,
  and shown in the activity feed.
- **Real use:** load the first video, change the panel to Solid and back, move one
  graphic, edit one text, export, and compare with the G0 render.

## 8. G0 status (2026-10-14)

- `Resources/Graphics/`: `graphics.js` (10 kinds, 4 rule demos, `plan`, `load`, `seek`),
  `graphics.css`, `page.html`, pinned GSAP 3.15.0 and Inter 400/700.
- `Tools/Graphics/assemble.mjs` writes `full` and `unit` pages; `--units` lists the units.
- The first video's 13 graphics as JSON (outside the repo, next to the footage) render
  through the engine. Snapshots at 13 hero times match the hand-built composition, with
  the shade-B panel. HyperFrames lint: 0 errors, 0 warnings.
- A `unit` page renders one graphic with alpha and its own time from 0 (checked over a
  magenta background), which is the export form for G1.
- Changes from the hand-built version: the tap ring of the account demo no longer shows
  before the tap; the panel shade gained a frost (`backdrop-filter`, `full` mode only).
- Owner feedback on the first render: the shade was too dark next to the speaker. The
  shade and the frost now fade in over `style.edge` (default 170 px), and the panel
  content moves right by `edge − 108` px to stay on the dark part.
- **Ink look** (owner's request, from a "writing over a talking head" reference frame):
  `style.look` is `glass`, `ink` or `mix`. Ink is done for `panelTitle`, `rule` (all four
  demos) and `checklist`: Virgil handwriting revealed left to right, marks drawn stroke by
  stroke with a seeded wobble, a taped photo for images, and a wide haze (`.yg-veil`) in
  place of the panel. Column kinds have no ink version yet and stay glass.
- `full` mode adds the blurred fill: a second `<video id="bg-fill">` under the main one. A
  960×540 copy (`--fill`) is enough because it is blurred, and it avoids the renderer's
  duplicate-media warning and a slow second 1080p decode.
- `featureList` items take an `image`: a product photo cut out with Apple Vision
  (`VNGenerateForegroundInstanceMaskRequest`, the "Copy Subject" engine). G2 can offer
  this cut-out in the app when an image is added.
- `preview` mode works in a browser: out-of-order seeks show the right graphic, and the
  count-up goes both ways. It is not yet tested inside `WKWebView`.
- Not done: automated tests for the engine (G1 adds a Node check that seeks out of order
  and compares DOM state).

## 9. G1 part 1 status (2026-10-14)

- **Data and schema:** `Sources/Graphics.swift` has `Graphic`, `GraphicsTrack`,
  `GraphicsStyle`, panel spans, the move curve and the engine's files and page writer.
  Props stay `JSONValue`, so a new template field needs no schema change. Project
  version 6 stores `graphics` per recording.
- **Commands:** `addGraphic`, `updateGraphic`, `removeGraphic`, `replaceGraphics` (with an
  optional style) and `setGraphicsStyle`, plus `importGraphics` for agents. Cuts remap
  graphics like zooms and report `removedGraphics`. The command catalog describes all six.
- **Preview:** `GraphicsOverlay.swift` loads the engine page in a transparent `WKWebView`
  over the player and seeks it to the playhead. `moveAside` in `Playback.swift` does the
  move, the blurred fill and the frost in Core Image. A graphics-only edit does not
  reload the video; a change to the move swaps only the video composition.
- **Timeline and inspector:** a Graphics lane under Effects (column row, panel row; drag to
  move, drag the right edge to change the length). The inspector edits the selected
  graphic's times, look, text, numbers and images from its data, and the recording's
  style, and imports a graphics file.
- **Tests:** 44 checks, including Swift and JavaScript agreeing on panel spans, cut remap,
  version gates, import, the page, agents, and move-aside pixels. Suite: 900/900.
- **Real use:** the first video's 13 graphics imported into its project with one agent
  command (one undo step) and saved as version 6.
- **Known:** graphics show in **Preview**, not in Edit frame. Each rebuild of the ad-hoc
  signed app can make macOS ask again for Desktop access; the first image read waits on it.
- **Next (part 2):** export. Render each unit to a cached PNG sequence with HyperFrames,
  overlay in ffmpeg, and port `moveAside` to an ffmpeg graph with a parity test.

## 10. G1 part 2 status (2026-10-15)

- **Export draws graphics.** Each graphic, and each panel span, is a render unit
  (`GraphicsTrack.renderUnits`, the same list as `plan()` in graphics.js). A unit's page
  carries only what it draws, timed from its first frame. That frame sits on the export's
  frame grid (`origin`, a new `unit` option in the engine), so beats land on the frames
  the preview shows. HyperFrames renders the page to PNG frames with alpha, at 1920×1080,
  or 3840×2160 for exports wider than 2400 px. ffmpeg adds each unit as an input at its
  start and lays it over the picture after the downscale and before the captions, fitted
  to the width and pinned to the top, as the preview fits the stage.
- **Cache.** `~/Library/Caches/YamVideo/GraphicsRender/<key>`. The key covers the engine
  files, the HyperFrames version, the unit's data, its images (path, size and date), its
  length, the frame rate and the size. New text in one graphic draws that graphic again
  and nothing else; a graphic moved by whole frames draws nothing; a panel graphic keeps
  its panel mates without their text, so editing one leaves the others alone. Frames no
  export has used for 30 days are removed. A cancelled render leaves nothing behind.
- **HyperFrames.** Pinned 0.8.159. It is downloaded with npm into
  `~/Library/Application Support/YamVideo/HyperFrames/0.8.159`, with its headless Chrome
  (about 220 MB together), only when the owner clicks **Download HyperFrames…** in the
  Export sheet. It runs on Node.js 22 or later from the usual places (nodejs.org,
  Homebrew, MacPorts, Volta, nvm), with telemetry, update checks and self-install off.
  Without it, an export with graphics stops and says how to get it, or to switch graphics
  off: the sheet's **Draw graphics into the video**, or `graphics: false` in the export
  settings.
- **The move aside in ffmpeg** (`FFmpeg.moveStage`). The video is cut into frame windows
  around each panel. Only those go through the move; the rest pass straight through, and
  concat joins them in order. In a window the frames are 10-bit 4:4:4: the fill at
  quarter size (grown, blurred, then one darkening and desaturating table), the edge fade
  as a still ramp merged into the alpha, and the frost at half size under a still ramp.
  Per-frame values come from `GraphicsMotion` through `sendcmd`. The ramps' gains go out a
  frame early, because mergeplanes reads them one frame ahead (measured at 30, 29.97 and
  15 fps).
- **Preview change for parity.** `moveAside` now works on the encoded values, like the blur
  effects: the fill is darkened (×0.86) and desaturated (0.9) by one matrix instead of an
  exposure step in linear light, and the masks are plain numbers. The look is close to
  before.
- **Colour tags.** ffmpeg 9 makes a blend's inputs agree on colour space and range, and
  converts one to match. That converted untagged recordings to BT.709 under the graphics.
  Graphics and the ramps now carry the picture's own tags, so the picture is never
  converted for them (checked: identical pixels).
- **Agents.** `state.graphicsRenderer` (`ready`, `needsNode`, `needsDownload` or
  `unknown`), the `graphics` export setting, and an early `unsupported_capability` refusal
  when something must be drawn but HyperFrames is missing. The catalog describes both.
- **Tests** (940 checks): units and keys; the engine and the app listing the same units;
  move parity at six times across a glass and an ink panel (worst offset 0 px, mean
  difference 0.76 of 255 in the fill and 1.2 over the frame); frames away from panels
  untouched and every frame kept; overlay place and timing with stand-in frames, also
  after a cut and a downscale; an untagged recording's colours kept exactly; an unchanged
  graphic not drawn again; cancel; the HDR refusal; the missing-renderer message; agent
  state; and a real HyperFrames render when it is downloaded.
- **Real use (a demo on this Mac).** A 24 s 1080p recording with seven graphics in the
  mix look (name plate, feature list, a panel of three ink graphics, link, end card),
  imported and exported by an agent through `yamvideoctl`. First export 69 s (8 units
  drawn); after one text change 26 s (1 unit drawn); unchanged 18 s; without graphics
  11 s.
- **Open.** The first video's own project, on the other Mac, is the real-use gate: export
  it from the app and compare with the G0 render. Graphics in Movie exports (G3). The
  move costs about 1 s of processing per second of panel, mostly resizing; a faster path
  can come later if long panels feel slow. In the demo, a long ink checklist line ran past
  the frame's edge: a template limit, not the export.

## 11. G2b status (2026-10-15)

- **Data.** Each graphic has an optional `transform {x, y, scale}`: a move in design
  pixels from its place in the template, and a scale (0.4–2.5) from the top-left corner
  of its zone. The template's own place is stored as no transform. Project version 7;
  an older version holding transforms is refused, so a build without this feature never
  drops them on save.
- **Engine.** Each graphic now sits in a `.yg-place` wrapper that carries the transform,
  so the template's own motion on the host is untouched. `YamGraphics.place()` moves
  graphics without rebuilding them (used while dragging). `bounds()` measures each
  graphic's drawn box once it has fully come in, without its transform: the painted
  boxes, images, SVG shapes and tight text. `boxes()` measures what shows at the current
  time. The export draws the transform because the same engine renders the units.
- **Preview.** Click a graphic on the picture to select it, drag it to move it, and drag
  a corner to resize it; the opposite corner stays put and the graphic keeps its shape. It
  snaps to the title-safe area (5 % in), the centre lines, its own place in the template,
  and the column or the panel; orange guide lines show the snap. ⌥ turns snapping off, as
  on the timeline. A drag is one gesture and one undo step ("Move Graphic on Picture",
  "Resize Graphic") and keeps Preview open. ⌥ arrow keys nudge the selected graphic
  (⇧ for 10 px). A graphic not on screen at the playhead shows a dashed box.
- **Inspector.** Across, Down and Size %, and Reset Position.
- **Agents.** `transform` on `addGraphic` and `updateGraphic` (only the keys given
  change); out-of-range values are refused with the range. `preview` with `composed: true`
  now draws the graphics, using the same engine page in an offscreen WebKit view, and
  returns each showing graphic's box in the preview's pixels.
- **Tests** (970 checks): the transform maths, snapping to the safe area, the centre and
  home, corner resizes keeping the opposite corner, snapping to 100 %, the size limits, a
  drag being one undo step that keeps Preview open, nudge and reset, the version gate,
  graphics files carrying placements, agent edits and refusals, the engine's measured
  box, a placed graphic landing where its transform says in the offscreen drawing, and a
  real export drawing it there.
- **Real use (on this Mac).** An agent moved a name plate to the lower left at 120 %
  through `yamvideoctl`. The composed preview reported its box, and the exported frame
  matched the preview. `Tools/Snapshot` shows the selection box on the moved card and the
  inspector fields.
- **Open.** Hands-on dragging in the running app (the gestures are covered by the maths
  and model checks, not by a pointer). A graphic can be placed partly off the frame; the
  preview shows its box, and agents see it in the reported box.

## 12. Publish panel status (2026-10-15)

- **Data.** Each recording keeps what YouTube needs (`PublishInfo`, project version 8):
  title, description, tags, category (Science & Technology by default), chapters, a
  thumbnail image, the captions' language, and the channel name for the preview. Chapter
  times are edited-recording seconds. Like markers, they follow their footage through
  cuts and go with it when it is cut away; the first chapter stays at 0:00.
- **YouTube's rules, checked as you type.** These block Export for YouTube: no title, a
  title over 100 characters, `<` or `>` in the title or description, a description over
  5,000 characters with its chapters, tags over 500 characters as YouTube counts them
  (quotes around a phrase, commas between), and a thumbnail file that has gone. These
  only warn: chapters YouTube would turn off (first not at 0:00, fewer than three, one
  shorter than ten seconds), and no thumbnail (YouTube picks a frame).
- **Chapters suggested** from named markers and from panel title, rule, checklist and
  title-card graphics: an "Intro" at 0:00 unless something starts in the first ten
  seconds, then candidates at least ten seconds apart that end ten seconds before the
  video does.
- **Captions on the edited timeline** (`Sources/Captions.swift`). SRT and WebVTT cues are
  moved through cuts, reordering and speed changes: each surviving part shows while its
  footage plays. The upload gets this as an SRT named with its language. The same file
  is now burned into exports of cut or retimed recordings, which fixes the drift noted in
  PR #6. ASS keeps its source timing and is left out of the upload.
- **Publish sheet** (toolbar **Publish…**): the fields with live counts and issues,
  chapters (add at the playhead, suggest, edit, delete), the thumbnail (choose an image,
  or **Use Frame at Playhead**, which saves the composed picture with its graphics next
  to the recording), and the captions file. A preview shows a sketch of YouTube's watch
  page (player, title, channel, description with chapters) and a search result with the
  thumbnail at its real 360 px width.
- **Export for YouTube** writes into a folder: the MP4 (H.264 whatever the export format
  is set to), `<title>.<language>.srt`, `<title> thumbnail.jpg` (the middle of the image
  at 16:9, 1280×720, under 2 MB), `<title> YouTube.txt` with every field to paste, and
  `<title>.youtube.json` with the same for an agent. The video is written under a
  temporary name and moved into place when done. The upload stays with the owner.
- **Agents.** `setPublishInfo` (only the keys given change; thumbnail is a path),
  `state.clips[].publish`, `publishIssues` and `suggestedChapters`, and `export` with
  `youtube: true` and a folder (`yamvideoctl export --youtube`), whose result lists every
  file.
- **Tests** (1019 checks): the counts and every rule, chapter suggestions, the timestamp
  format both ways, the round trip and version gate, chapters through a cut, captions
  through cuts, reordering and speed, a real export whose burned caption shows when its
  footage plays (not at its source time), the thumbnail conversion, a full Export for
  YouTube from a GIF-set project, refusal without a title, and agents writing, patching,
  being refused and exporting.
- **Real use (this Mac).** An agent wrote the details for the 24 s demo through
  `yamvideoctl`, used a composed preview at 11.5 s as the thumbnail, and exported for
  YouTube: MP4, 1280×720 thumbnail, upload text and JSON. The chapter warning showed as a
  warning, not a refusal. `Tools/Snapshot` shows the sheet with both previews.
- **Open.** Upload itself (by the owner, or an agent in the owner's browser). End screen
  element boxes (feature 5) and the thumbnail maker (feature 4) build on this.

## 13. Thumbnail maker status (2026-10-15)

- **Design** (`ThumbnailDesign`, kept in the publish details; project version 9): the
  frame (edited seconds, carried through cuts), a title of up to three lines where words
  between asterisks take the accent colour, a tag, the accent (the graphics accent by
  default), an optional picture beside the title, whether to cut the speaker out and
  outline them, the speaker's size (100–160 %, growing up from the bottom), what is
  behind them (as recorded, darker, blurred or plain), and the title's side (away from
  the speaker by default).
- **Cut-out.** Apple Vision (`VNGenerateForegroundInstanceMaskRequest`) cuts the
  foreground out of the frame as Preview shows it (colour, zoom, effects; no graphics).
  Cut-outs are kept by the frame's content, so the same frame is cut once. A frame with
  nothing in front is used as it is, and the maker says so.
- **Template.** `YamGraphics.thumbnail(data)` in the engine draws it on the 1920×1080
  stage: the frame (dimmed, blurred or hidden), a scrim behind the title, the speaker cut
  out with a white outline (an SVG dilate filter), a tag pill, and the title, sized down
  from 170 px until it fits its column. The same page draws the live preview and, through
  an offscreen WebKit snapshot, the final 1280×720 PNG.
- **Maker** (Publish → **Make Thumbnail…**): the frame (slider and Use Playhead), title,
  tag, accent, speaker, background, side and picture, with a live preview large and at
  YouTube's 360 px search size. **Save Thumbnail** writes the PNG next to the recording
  and makes it the video's thumbnail with its design, in one undo step.
- **Agents.** `setPublishInfo` with `design` (only its keys given change), and a
  `thumbnail` request (`yamvideoctl thumbnail --clip ID [--save]`) that draws the stored
  design, or changes tried over it without storing them, and returns the PNG's path,
  whether a speaker was found and where, and with `save` the saved file's path.
- **Tests** (1041 checks): design rules and defaults, Vision cutting out a subject and
  finding nothing in a plain frame, the title on the side away from the speaker (or the
  side asked for), the cut-out staying bright on the darker background and the whole frame
  darker without it, the accent tag, the version gate, a frame after the end refused, and
  agents patching the design, trying one without storing it, saving, and being refused.
- **Real use (this Mac).** An agent designed a thumbnail for a test recording through
  `yamvideoctl`, drew it with a blurred background, saved it next to the recording and
  made it the video's thumbnail. The live preview was checked with WebKit's own snapshot;
  `Tools/Snapshot` cannot capture a web view in a sheet of its own.
- **Open.** Real footage of a person (the tests use a drawn subject). Several looks or
  layouts to choose from, and saving a design as a look for the next video.

## 14. End screen status (2026-10-15)

- **YouTube's rules** (checked 2026-10-15 against YouTube's help page): end screen elements
  show in the last 5 to 20 seconds of a video of at least 25 seconds, up to four of them:
  a video (best for viewer, most recent upload or a chosen one), a playlist, Subscribe, a
  channel, or a link (Partner Program only). YouTube's upload API cannot set them; they are
  placed in YouTube Studio (Content → the video → Editor → End screen). YouTube does not
  publish the elements' sizes; creators measure a video card at about 615×346 and the
  circle at about 296 px on a 1920×1080 frame, which the layout uses, with a 10 px margin
  round each drawn box.
- **Data** (project version 10). A new kind, `endScreen`, in a new `screen` zone, with
  `videos` (1 or 2), `side` (where the speaker sits) and the kicker and title beside the
  circle. It must end where the video ends (within 0.05 s), last 5 to 20 s, and be the only
  graphic on screen: column graphics end by its start, and panels must have slid away
  (0.8 s after they end). It cannot be moved on the picture. Cuts keep it on the last
  seconds, as long as it was, shortened when something now runs into it, or dropped and
  reported when under 5 s. The publish details keep which element goes in each box
  (`endScreen`: circle subscribe or channel, and per video box best for viewer, most
  recent upload, a chosen video or a playlist, with its link and title).
- **Layout** (`EndScreenLayout`, and `endLayout` in the engine with the same numbers): the
  speaker's frame at half size (960×540 at 96, 102), the circle below it, the kicker and
  title beside the circle, and the video cards in the other column (two stacked, or one),
  mirrored when the speaker sits on the right.
- **The move is native**, like the move aside: over 0.8 s (smoothstep) the picture shrinks
  about its top-left corner into the frame, over the move aside's blurred, darker fill, and
  stays there to the end. Core Image scales with Lanczos; the export cuts the end screen's
  frames out of the video, gives each frame of the move its own `scale` (Lanczos) and
  `overlay` place, and one place to the rest, with the same whole-pixel numbers
  (`GraphicsMotion.screenPlacement`). The engine draws the light frame round the speaker
  (an outer shadow only, so the picture stays clear), the boxes, and the text. In the app's
  Preview and in composed previews each box says what goes in it; exports draw the boxes
  only, since YouTube's elements cover them.
- **App.** Inspector Graphics → **End Screen** (and Publish → **Add End Screen**) adds it
  for the last 20 s, or as much of them as is clear. On the timeline it spans both rows and
  only its start drags. The inspector has Video boxes (one, two) and Speaker (left,
  right). Publish has an End Screen section with the choice for each box and the Studio
  note. Warnings (never blocking): a video under 25 s, a chosen video or playlist without a
  YouTube link, another channel without a name, choices without a layout.
- **Export for YouTube** adds an END SCREEN section to the upload text (the note that the
  upload API cannot set the elements, when it starts, and each element with its box in
  words and as percentages of the frame) and `endScreen` to the JSON (times, the speaker's
  frame, and each box in pixels and fractions, with `uploadAPICanSet: false`).
- **Agents.** `addGraphic` with just `{"kind": "endScreen"}` places it; `updateGraphic`
  with `start` keeps its end at the end; refusals say the window (5 to 20 s), that nothing
  may show over it, and that it cannot be moved. `setPublishInfo` with `endScreen` (only
  its keys given change). `state.clips[].endScreen` lists its times and boxes with the
  chosen elements. A composed preview draws it with its labels.
- **Found on the way.** ffmpeg's `concat` times a segment by its frames' mean spacing, so
  a one-frame segment adds no time: the first export lost the 24 frames of the move.
  From the end screen's first frame on, frames are now timed by their number on the
  stage's frame grid; a test checks every frame keeps its place.
- **Tests** (1091 checks): the layout (inside the picture, nothing overlapping, YouTube's
  sizes, mirrored) and the engine laying it out the same; every rule and its message; a
  new end screen's span; cuts before, inside and through it; the move's curve and whole-
  pixel places; preview and export agreeing at six frames during and after the move (worst
  offset 0 px, mean difference 2.95 of 255 in the scaled picture and 1.73 over the frame), the fill beside the frame, frames before it untouched, an
  exported MP4 keeping every frame and its time; the engine's frame and boxes in an
  offscreen drawing; the upload text and JSON; the issues; the version gate; and agents
  adding it with just its kind, choosing elements, being refused, moving its start, and a
  composed preview.
- **Real use (this Mac).** A 32 s 1080p recording in an isolated app instance, driven only
  through `yamvideoctl`: an agent added a name plate and an end screen with just its kind
  (placed at 0:12 to 0:32), chose a specific video and Most recent upload for the two
  cards, and was refused, with the reason, when it tried to move the end screen on the
  picture, leave it 3 s, or add a link over it. Composed previews at 12.4 s (mid-move) and
  14 s show the frame following the picture and the labelled boxes. Export for YouTube took
  36 s and wrote the MP4 (960 frames over 32 s, evenly spaced, like the source), the upload
  text with its END SCREEN section, and the JSON; the MP4's frames match the composed
  previews, without the labels. `Tools/Snapshot` shows the timeline block, the inspector and
  the Publish section.
- **Open.** Placing the elements in YouTube Studio on a real upload, which also checks the
  boxes against Studio's own element sizes (YouTube does not publish them). Real footage of
  a person. Layouts with a link element (Partner Program) or four elements. Mid-move a
  composed preview lists no box for the end screen until its boxes pop in.
