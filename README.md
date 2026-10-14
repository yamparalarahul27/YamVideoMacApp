# YamVideo

A native macOS editor for screen recordings: cut mistakes, reorder sections, crop and
blur the frame, arrange smooth zooms, preview the result with sound, and export MP4,
animated GIF or animated WebP. Save the edits in a `.yamvideo` project and pick up later.

Each imported recording has its own timeline. Export recordings separately, or switch to
**Movie** to combine them into one export. **Suggest Zooms** finds concentrated visual
activity locally and proposes editable zooms for you to preview and accept.

Built as a plain SwiftUI app that drives `ffmpeg` — no Xcode project, no dependencies to
vendor, and the exact command it runs is always visible in the Export sheet.

## Requirements

- macOS 14 or later
- `ffmpeg` and `ffprobe`: `brew install ffmpeg`

The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`
(a GUI app doesn't inherit your shell `PATH`). If yours lives somewhere else, the banner
at the top of the window has a **Locate ffmpeg…** button.

WebP export additionally needs an ffmpeg built with `libwebp`, and Homebrew's plain
`ffmpeg` is now a slim build without it — the everything-included one is a separate
formula:

```sh
brew install ffmpeg-full
```

It is keg-only, so it stays out of `bin`; the app looks in
`/opt/homebrew/opt/ffmpeg-full/bin` (and the `/usr/local` equivalent) before the usual
places and picks it up on its own. Check what yours has with
`ffmpeg -encoders | grep libwebp`. The app runs that check itself on launch and says so in
the Format section rather than failing at the end of an export. GIF and MP4 need nothing
extra.

Converting an HDR clip to SDR needs `zscale`, which comes from libzimg, and burning
subtitles in needs `subtitles`, which comes from libass — both optional build flags
(`ffmpeg -filters | grep -E 'zscale|subtitles'`). The app checks for each the same way and
only mentions them when the clip you have selected actually needs them.

## Build and run

```sh
./build.sh
open build/YamVideo.app
```

To keep it around, drag `build/YamVideo.app` to `/Applications` — or:

```sh
cp -R build/YamVideo.app /Applications/
```

Run the checks with `./test.sh` (roughly 285 assertions). Tests include real encodes and
frame-by-frame verification that blurs actually remove detail, zooms land where they
should, burned-in captions land in the band they were aimed at, HDR clips come back
tagged Rec.709, and normalised audio lands on target — plus video and audio section
ordering, exact frame counts, native preview/export coordinate comparisons, undo/redo,
project round trips, autosave recovery, and export failure/cancellation cleanup. Movie
checks cover mixed dimensions, frame rates, rotated footage, silent recordings, GIF
palettes, preview/export parity, and preserving existing exports on cancellation.

## Building a movie

Use the **Movie** workspace in the toolbar after importing recordings. Include or exclude
recordings with the checkboxes and change their order with the arrow buttons. **Edit**
opens a recording's timeline; its cuts, crop, blur areas and zooms also apply in the movie.
The movie preview plays through every included recording with sound.

Choose **Match first clip**, **16:9**, **9:16**, or **1:1** for the canvas. Recordings fit
inside it with black bars where needed. Frame rates normalize to the first recording's
rate without changing playback speed. The export size limit applies to the canvas.
**Export Movie…** (⌘R in Movie) writes one MP4, GIF, or WebP to your chosen destination.
MP4 audio is normalized to AAC; silent clips receive silence. Cancellation keeps an
existing destination intact. Inclusion, order and canvas save with the project.

## Assisted zooms

In a recording's **Zoom** controls, choose **Suggest Zooms**. Analysis samples up to
1,200 small frames on this Mac, looks for localized changes, and ignores full-screen
changes, removed footage, activity outside the crop, and existing zooms. Preview each
suggestion, uncheck any you do not want, then choose **Add Selected**. Added shots use
the same target, timing, strength and undo controls as manual zooms.

This is a visual-activity heuristic: it does not recognize mouse clicks, track a cursor,
or understand which part of your content matters. Quiet footage may yield no suggestions.

## Editing a recording

- **Waveform:** an audio waveform appears below the video sections as analysis finishes.
  It follows cuts, reordering and speed changes. Click or drag it to seek. Analysis stays
  on this Mac; recordings without audio show **No audio track**.
- **Remove pauses:** choose **Review Silence…**, adjust the audio threshold, minimum
  pause length and padding around speech, then listen to each proposed cut. Uncheck cuts
  you want to keep and choose **Apply Cuts**. The time saving reflects current section
  speeds; the minimum-pause setting measures the original recording. One Undo restores
  all removed sections. Low volume is not necessarily silence, so review quiet speech
  and intentional pauses before applying.
- **Change speed:** select a video section and choose **Speed**, from **0.25× to 4×**.
  With several sections selected, one choice sets them all as a single undo step; if any
  is too short for that speed, none change. Split a section first to retime only part of it. Audio preserves pitch in native playback
  and export. Movies, waveforms and time labels follow the new duration. Zoom starts stay
  anchored to their source frames; their hold lengths remain in playback seconds and
  may be shortened or removed if they no longer fit.
- **Play / pause:** press Space or the play button beneath the viewer. Left/Right step one
  frame. The Preview tab shows the edited movie with crop, blur, zooms, cuts and audio;
  Edit frame gives you the original frame and draggable editing handles.
- **Seek:** click or drag the time ruler, or click inside a video section. The timeline
  magnification slider provides more room for precise cuts; scroll horizontally when zoomed in.
- **Split:** place the playhead inside a section and press **⌘B** or click **Split**.
- **Trim:** drag a section's left/right handle, or select it and enter source seconds in
  **In / Out**. Changes snap to source frames. **⌘⇧[ / ⌘⇧]** trim the current section's
  start/end to the playhead. Hidden footage can be restored up to neighboring retained ranges.
- **Select several sections:** **⇧-click** selects every section from the last one clicked
  to this one, in the order they play. **⌘-click** adds or removes one, and **⌘A** selects
  them all. Neither moves the playhead. **⌘← / ⌘→** select the previous or next section,
  and **⇧Home / ⇧End** move the playhead to where the selection starts or to its last
  frame. These keys leave text fields alone, so ⌘A still selects text while you type.
  Trims and order are edited one section at a time.
- **Delete:** select one or more sections, then click the trash button or press **⌘⌫**.
  Several go as one undo step. The gap closes automatically. At least one section stays;
  remove the sidebar item to discard a recording.
- **Reorder:** drag a section onto another, or use the earlier/later arrow buttons.
- **Snapping:** with **Snapping** on (the button above the timeline, or Timeline ▸
  Snapping), dragged edges line up with the playhead, section boundaries, zoom edges and
  the start and end of the timeline once they come within 8 points of one. An accent
  line shows what an edge is holding to. It applies to trims, moving and resizing zooms,
  and dragging the playhead. A trim snaps only to things over its own section, since
  those are the frames it can cut at. Hold **⌥** while dragging to place freely. The
  reach is fixed on screen, so zooming in weakens it until it disappears at frame level.
  The setting is remembered.
- **Arrange zooms:** use Zoom mode to add one at the playhead. Drag a cyan timeline block
  to move its start; drag its right handle to change the hold duration. Zooms stay inside
  the edited duration and cannot overlap. When cutting or reordering, their start frames
  anchor them to retained footage. Zooms whose start was removed, or which no longer fit,
  are removed with a status message; Undo restores them.
- **Undo / redo:** **⌘Z / ⌘⇧Z** restore timeline, crop, blur, zoom, subtitle and
  export-setting edits. A drag or slider is one step however long it is held; it ends when
  you let go. History is kept for the current session, and steps made by a local agent
  are named with the agent's name in the Edit menu.
- **Save:** **⌘S** saves a `.yamvideo` project; **⌘⇧S** saves it under a new name as a
  separate project. **⌘⇧O** opens a project, and **⌘N** starts a new one. Opening/starting
  a project can also be undone. If the project file changed on disk since you opened it,
  ⌘S asks before replacing it.
  Projects are saved as version 4, which adds per-recording colour settings (version 3
  added a project identity and the chosen subtitle file). This build opens versions 1–4;
  older builds refuse a newer file rather than dropping edits they do not understand.
- **Recover:** edits autosave after a short idle period and when quitting. The next launch
  restores the session, including its named save destination. Recovery lives in
  `~/Library/Application Support/YamVideo/Recovery.yamvideo`; it does not overwrite a named
  project until you save. Projects reference the original source paths. If a source moves,
  **Locate Source…** reconnects a video with matching dimensions and duration.

Playback uses AVFoundation and Core Image, so ordinary MP4/MOV recordings preview without
an intermediate render. Other formats remain available for FFmpeg export but may not play
natively. Soft blur/pixelation can look slightly different between the native preview and
FFmpeg export; the Edit frame preview uses the FFmpeg blur graph. Export resolution, encoder
quality and animation frame thinning apply during export. Cuts encode audio to AAC even
when Copy is selected, to keep the cut boundaries synchronized.

## Using it

| | |
|---|---|
| **Add clips** | Drop files (or a folder) onto the window, press ⌘O, or open a video with the app from Finder |
| **Crop** | Drag inside the rectangle to move it, drag any of the 8 handles to resize, or drag on the dimmed area to draw a new one. Exact pixel values are under **Details** in the inspector |
| **Lock a shape** | Pick an aspect preset (16:9, 9:16, 1:1, 4:5, 4:3, 2.39:1) and resizing keeps that ratio |
| **Blur an area** | Switch the picture to **Blur** and drag over anything you want hidden — a face, a name, a URL. Add as many areas as you like; drag or resize them the same way as the crop. **Add Area** drops one in the middle if you'd rather not draw |
| **Zoom in** | Switch to **Zoom**, scrub to the moment, then click the spot. The video eases in, holds still, and eases back out. Pick 1.5×/2×/3× and how long it holds; drag the marker to re-aim it |
| **Pick the frame you work against** | Drag the scrubber under the preview |
| **Inspect what you select** | The inspector on the right follows your selection — a section's speed, trims and order, a zoom's level and hold, a blur area — above the recording's frame, blur, zoom and caption settings |
| **Reuse your work** | **Use on All Recordings** copies the crop, blur areas *and* zooms to every other queued clip with the same dimensions |
| **Add graphics** | In the inspector under **Graphics**, **Import…** a graphics file (graphics.json). The graphics show over the video in **Preview**, in the Graphics lane under the timeline, and in the inspector when you select one: drag a block to move it, drag its right edge to change its length, and change its text, times and images. **Look** chooses glass cards, ink, or ink for panels and cards for the rest |
| **Burn in subtitles** | Drop an `.srt`, `.vtt` or `.ass` next to the video under the same name and it is picked up automatically, or pick one under **Captions** in the inspector. Choose where it sits and how big it is |
| **Make a GIF or WebP** | Pick the format in the Export sheet. Everything else — crop, blur, zoom — works exactly the same |
| **Correct Pocket 3 D-Log M colour** | In the inspector's **Colour** section set **Recorded colour** to **DJI Pocket 3 D-Log M**. The first time, **Get DJI Conversion** opens DJI's download page and **Import Conversion File…** takes the `.cube` you saved. After that, **Natural Colour** is one click, and one Undo. Auto never assumes D-Log M: a `DJI_` file name only makes it ask |
| **Adjust the look** | **Brightness**, **Warmth**, **Contrast** and **Colour strength**, each with its own reset. Exact values are under **Details**. A drag is one undo step, and the picture follows it straight away |
| **Compare before and after** | **Corrected / Original / Compare** under the picture. Compare shows the original on the left half and the corrected picture on the right, at the same frame. It never changes the project or the export |
| **Copy colour to other recordings** | **Copy Colour…** copies the look. Tick **Also copy the recorded colour and conversion** only for recordings made the same way |
| **Blur the whole picture for a moment** | **Effects** mode (or **Add Blur Effect** in the inspector) adds a full-frame blur at the playhead that fades in and out, for a transition, a private moment or a backdrop for a title. Drag its block on the Effects lane to move it, or its edges to retime it; it stops at its neighbours. The inspector sets **Amount**, **Mix**, **Fade in/out**, exact times, and **On** to bypass it without deleting it. Effects mode shows the composed Preview so you see the result |
| **Mark a moment** | Press **M** to drop a marker at the playhead; **⇧M** names the selected one; **⇧↑ / ⇧↓** jump between markers. Markers fly in the ruler, follow their footage through cuts, and are snap targets. They are also how you and an agent can point at the same moment |
| **Export** | **Export…** opens a sheet for the selected recording, all recordings or the movie, with format, quality, audio and destination. ⌘R still exports all recordings (or the movie in Movie). ⌘. stops |

Individual clip output lands next to each source file as `<name>-converted.<ext>` (`.mp4`, `.gif` or
`.webp`, following the format) unless you choose another folder. Existing files are never
overwritten and the source is never clobbered.

### Settings

- **Format** — **MP4 video**, **Animated GIF**, or **Animated WebP**. GIF and WebP are
  silent and looping; the encoder, speed and audio controls are replaced by the options
  that actually apply to them
- **Encoder** (MP4) — H.264 via x264 (best quality per byte), H.264 via VideoToolbox (much
  faster, hardware), or HEVC via VideoToolbox (smallest, tagged `hvc1` so QuickTime plays it)
- **Quality** — one slider; the CRF, VideoToolbox `q` or libwebp quality it maps to is
  shown next to it
- **Scale** — optionally cap the long side (4K/2560/1080p/720p/480p/640/480). Never upscales
- **Blur areas** — **Blur** (soft gaussian), **Pixelate** (chunky mosaic), or **Black box**
  (solid fill, nothing recoverable), plus a strength/block-size slider
- **Subtitles** — burns a subtitle file into the picture. The file is per clip; the
  styling is shared. **Placement** is either **Bottom edge** or **Clear of social UI** —
  the second lifts captions above the caption, username and button rail that TikTok, Reels
  and Shorts draw over the bottom quarter of a vertical frame, where anything low in the
  frame is simply covered up. **Size** is Small, Medium or Large
- **Audio** (MP4) — re-encode to AAC 192k (default), normalise the loudness, copy the
  original stream, or drop it. **Normalise** targets -14 LUFS / -1 dBTP, which is what
  YouTube, Instagram, TikTok and LinkedIn all normalise toward: hit it and they leave your
  audio alone instead of turning it down. It costs one extra pass over the audio
- **Colour** — appears only when the selected clip is HDR (HLG or PQ). **Convert HDR to
  SDR** is on by default and tone-maps to Rec.709; turn it off to pass the source colours
  through untouched

For GIF and WebP:

- **Frame rate** — 24/20/15/12/10 fps, or leave the source rate alone. 15 fps is the
  default and halves the file against 30 fps for very little visible cost. It never pads a
  slow source *up* to a higher rate
- **Loop** — forever (default) or play once
- **Colours** (GIF) — 256/128/64/32. Screen recordings are mostly flat UI colour and
  usually survive 64 with no visible difference
- **Dither** (GIF) — **Ordered** (a fixed pattern, so it compresses well between frames),
  **Diffusion** (best gradients, noisier and bigger), or **None** (hard edges, ideal for
  text and flat UI)
- **Lossless** (WebP) — pixel-exact and much larger; worth it for text-heavy captures

Zooms are per-clip and set in the editor rather than here: level, start and hold length.
The ease is fixed at 0.5s in and out — a consistent ease is most of what makes these look
deliberate rather than homemade.

Every MP4 gets `+faststart` so it streams and scrubs properly on the web.

## Notes on correctness

A few things this handles that are easy to get wrong:

- **Rotated footage.** iPhone and screen-recorded MOVs carry a rotation matrix. ffmpeg
  applies it before filters, so crop and blur rectangles are expressed against the
  *displayed* frame — what you see in the preview is what you get.
- **HDR footage needs tone mapping, not just a bit-depth cut.** iPhone video is HLG by
  default and screen recordings on an HDR display can be too. Converting one straight to
  8-bit `yuv420p` produces a file that is still *tagged* HLG, so every player that honours
  the tag stretches it back out and shows it blown out — except QuickTime on the Mac that
  recorded it, which is why this is easy to ship by accident. The app detects PQ and HLG
  from `color_transfer`, tone-maps through linear light, and tags the result Rec.709.
- **Tone mapping happens in linear light, in float RGB.** Averaging pixels only means
  anything in linear light, and doing the conversion in subsampled YUV would resample
  chroma twice on the way through. The chain linearises, converts to `gbrpf32le`, maps,
  and converts back.
- **The tone map runs at the head of the graph.** Before the blur regions, not after, so
  the blur sees the same pixels the export writes — and so does the preview, which shares
  the graph builder.
- **A whole-frame blur fades per frame, not per pixel.** ffmpeg's `blend` with an
  expression evaluates it for every sample and took 73 s for six seconds of 1080p.
  The fade only changes once a frame, so the app computes each frame's weight itself
  (the same function the preview uses) and hands ffmpeg a `sendcmd` script setting a
  plain opacity per frame: 3.8 s for the same clip. Both renderers blur after crop and
  zoom, before scaling, on encoded RGB in float with no subsampled chroma; on a test
  clip they fade on the same frames and match within 4.4 of 255 across a hard edge.
- **Colour is one table, applied the same way twice.** A recording's DJI conversion and
  its four adjustments are compiled into a single 3D table. ffmpeg applies it with `lut3d`
  (trilinear, float RGB, from the source's own YUV matrix and range, back to 10-bit
  BT.709), and Core Image applies the same table for playback. On a 10-bit test chart the
  two agree within 3 of 255 levels at the 99th percentile. The table runs first, before blur
  areas, so a black area stays black whatever the grade.
- **macOS does not read Rec.709 video with the textbook curve.** It decodes into its own
  `CoreMedia709` space; converting through `itur_709` moves mid-grey by about 19 levels.
  Core Image therefore applies the table in the frame's own decoding space.
- **Conversion files travel by content.** Imported tables are kept under their SHA-256 in
  `~/Library/Application Support/YamVideo/LUTs`, and saving a project copies the ones it
  uses into a `YamVideo Assets` folder beside it. Opening the project on another Mac takes
  them from there. If a table is nowhere to be found, export refuses rather than writing
  uncorrected video. DJI's file is never bundled; the app recognises it by hash.
- **Loudness normalisation is two passes, not one.** `loudnorm` with no measurements is a
  dynamic-range compressor: it moves quiet and loud parts relative to each other. Measuring
  first and handing the numbers back (`linear=true`) makes the second pass a single gain
  change, which is what "normalise" ought to mean. The measurements are passed back as the
  strings ffmpeg printed rather than re-formatted Doubles.
- **`loudnorm` works at 192 kHz internally** and will hand that rate to the encoder if you
  let it, so the output sample rate is pinned back to 48k explicitly.
- **Digital silence measures as `-inf`,** which ffmpeg will not accept back as a
  measurement. That case falls through to the unmeasured filter rather than failing the
  export — normalising silence is a no-op either way.
- **Subtitles are burned last.** After the crop, after the zoom, after the scale, after
  the blur areas. Ahead of the scale the text would be resampled with the picture; ahead
  of the zoom it would be magnified along with it; ahead of a blur area it could be
  smeared by one. Both GIF passes get the same treatment, or the palette would be built
  for a picture the encode never renders.
- **The subtitle file is copied somewhere safe before it is named in a filter.** The
  `subtitles` filter takes its filename as a filter argument, where `:` separates options,
  `,` and `;` separate the graph, and `'` and `\` quote — all of which are perfectly legal
  in a macOS filename. Rather than escape three parser levels by hand, the file is copied
  to a temporary name built only from characters none of them care about. The name comes
  from a hash of the original path, so it is stable between runs (the command in the
  sidebar is the one that runs) and two different files can never share a copy.
- **Blur runs before the crop.** Blur areas live in full-frame coordinates, so moving the
  crop doesn't drag them along with it. The preview bakes the blur in using the same graph
  builder the export uses, so preview and output can't drift apart.
- **`-filter_complex` breaks stream selection.** Blurring needs a filter graph rather than a
  simple chain, which silently drops audio unless every stream is mapped explicitly. There's
  a test for exactly that.
- **Even dimensions.** `yuv420p` needs even width, height, and offsets, so crop values
  snap to even numbers rather than failing at encode time.
- **Audio copying.** ffmpeg will happily copy PCM audio into MP4 as `ipcm`, producing a
  file QuickTime and Safari can't decode. The app warns when the selected clip's audio
  isn't MP4-compatible and Copy is chosen.
- **Progress and cancelling.** Progress is parsed from ffmpeg's `-progress` stream;
  cancelled or failed encodes delete their partial output instead of leaving a stub.
- **Zoom keeps the exact frame rate.** `zoompan` re-times to whatever rate you give it, so
  rounding 29.97 to 30 shortens a clip by ~1ms/s and drifts audio out of sync. The rate is
  carried through verbatim as `30000/1001`.
- **Zooming upscales.** A 2× zoom on 1080p shows 540p worth of pixels stretched back up, so
  it looks softer. Record at 4K (or Retina) and export to 1080p and zooms cost nothing.
- **Zooms near an edge clamp inward** rather than showing black bars, so the target may not
  end up dead centre when it sits close to the frame edge.
- **GIF is exported in two passes.** One `palettegen` pass over the whole clip, then an
  encode through that palette (`stats_mode=diff` + `paletteuse=diff_mode=rectangle`, which
  is what makes a screen recording compress at all). The one-command version of this trick
  makes ffmpeg buffer every frame in memory before it can emit any; two passes cost a
  decode and stay flat regardless of clip length. The palette lands in the temp folder and
  is deleted afterwards, including when the encode fails.
- **Zoom and frame rate agree.** `zoompan` emits one frame per input, so its input cadence
  must match its declared output rate. Clip exports normalize both to the chosen rate;
  movies normalize each source to a common rate and thin animation frames after assembly.
- **The two formats spell "play once" differently.** GIF wants `-loop -1`, WebP wants
  `-loop 1`, and both use `0` for forever. Getting this backwards silently produces a
  one-shot animation.
- **WebP needs libwebp.** It is an optional ffmpeg build flag, so the app checks
  `ffmpeg -encoders` up front and explains itself instead of surfacing ffmpeg's
  "Unknown encoder 'libwebp'" after the export has already started.

## Local agents

A Codex or Claude session on the same Mac can edit the open project alongside you with
`build/yamvideoctl`: read the project, apply typed edits against the revision it read,
undo its own steps, render preview frames, analyze silence or motion, and export. Its
edits land on the real timeline as ordinary undo steps, and an edit planned against an
out-of-date revision is refused instead of overwriting yours. Everything stays on this
Mac: the app listens only on a private socket that other users cannot reach. See
[Tools/YamVideoCLI/README.md](Tools/YamVideoCLI/README.md), and run
`Tools/YamVideoCLI/demo.sh` with a recording open to watch two clients edit at once.

Everything in the editor is open to agents: sections, crop, blur areas, zooms,
whole-frame blur effects, markers, colour, the movie and export. An agent does not need
to know the app in advance. `yamvideoctl catalog` (the MCP tool `yamvideo_describe`)
returns every command with its fields, types, units, ranges and defaults, a worked
example, and the rules every request follows, straight from the app; the test suite keeps
it in step with what the app accepts. `preview --composed` renders a frame exactly as your
Preview shows it, so an agent can look at a zoom or an effect it just added, and `reveal`
selects something to show it to you.

## Layout

```
Sources/
  App.swift         @main, menu commands, Finder open-file handling
  AppModel.swift    queue, selection, preview, conversion driver
  ContentView.swift window layout: media list, picture and inspector over a full-width timeline
  InspectorView.swift selection-following inspector: section, zoom, blur area, effect, marker, recording
  ExportSheet.swift scope, format, quality, audio and destination for one Export button
  AgentActivityView.swift Local agents status, pause switch, activity and setup commands
  CropEditor.swift  crop/blur/zoom overlays, handle/resize maths, pixel fields
  FFmpeg.swift      locating the binaries, probing, thumbnails, export
  Models.swift      media info, export settings, geometry helpers
  Timeline.swift    ordered source ranges, snapping, selection and project serialization (schema v5)
  ColorLUT.swift    .cube parser and trilinear sampling
  ColorAdjustments.swift colour settings, the four adjustments and Auto's inference
  ColorPipeline.swift table store and the colour stage shared by ffmpeg and Core Image
  ColorEditing.swift / ColorInspector.swift colour actions and the Colour inspector
  VisualEffects.swift whole-frame blur and markers: timing, validation, remapping
  VisualEffectsEditing.swift / VisualEffectsView.swift effect and marker actions, lane and inspectors
  Graphics.swift    graphics data, validation, remapping, the move aside and the engine page
  GraphicsEditing.swift / GraphicsInspector.swift / GraphicsOverlay.swift graphics actions, inspector and preview layer
  AgentCatalog.swift every agent command described for agents, served by `catalog`
  EditCommands.swift typed edit commands and the pure, all-or-nothing reducer
  ProjectCommandDispatcher.swift revisions, gestures, shared undo, sessions, change feed
  AgentProtocol.swift wire types and socket helpers shared with yamvideoctl
  LocalAgentServer.swift private Unix-socket listener and discovery record
  AgentRequests.swift every agent request: state, apply, preview, jobs, save
  TimelineView.swift timeline, section trim handles and zoom blocks
  Playback.swift    native video/audio composition and live effects
  ProjectEditing.swift undo history, project files and session recovery
  Movie.swift       movie canvas and multi-source FFmpeg export graph
  MoviePlayback.swift native compositor for differently oriented recordings
  MovieEditing.swift movie actions and atomic export publishing
  MovieView.swift   assembly preview, inclusion and order controls
  ZoomSuggestions.swift local motion analysis and suggestion review
  AudioAnalysis.swift audio waveform, silence detection and reviewable cuts
  Shell.swift       process runner with streamed output
Tests/main.swift    end-to-end checks (./test.sh)
Tools/makeicon.swift  draws the app icon at build time
Tools/YamVideoCLI/    yamvideoctl, its guide and the two-client demo
Tools/AgentBridge/    MCP server for Claude Code and Codex, with setup and a smoke test
Tools/Snapshot/       renders the real window offscreen to PNGs for layout checks
Tools/Graphics/       writes HyperFrames pages from graphics JSON (graphics track, phase G0)
Resources/Graphics/   graphics engine: kinds, glass and ink looks, pinned GSAP and fonts
```

## Implementation plans

The [local co-editing plan](docs/plans/local-coediting.md) coordinates the next editor
work: a simpler selection inspector, shared local edits from Codex/Claude, and a
[beginner Pocket 3 D-Log M colour workflow](docs/plans/pocket-3-colour.md). It reconciles
the earlier [timeline navigation](docs/plans/timeline-navigation.md) and
[whole-frame blur](docs/plans/full-frame-blur-effects.md) plans. Its foundation and
shared-command phases (project identity, one edit path with revisions and gestures, the
local socket and `yamvideoctl`) are implemented; the remaining phases describe planned
work, not features available in this build.

The [graphics track plan](docs/plans/graphics-track.md) is the layer design that the
co-editing plan asks for: timed motion graphics over a recording, in a glass-card look or
an ink look (handwriting over a soft haze), plus ink clips drawn on an iPad. Its first
phase, the template engine in `Resources/Graphics/` with `Tools/Graphics/assemble.mjs`,
runs outside the app today; the app phases wait for co-editing phase 5.
