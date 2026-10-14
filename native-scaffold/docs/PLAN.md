# Yamparala Video — Plan

A personal macOS app for recording, editing, and exporting screen + facecam videos
for R2 / the web.

Status: **building** — Phase 0 done, Phase 1 done except GIF validation (needs ffmpeg).
Last updated: 2026-08-20 — **v3: pivoted to native SwiftUI on the Pen-Fight-Stream
foundation; app restructured into Record / Export / Edit tabs; added Blur.**

> **v3 supersedes the Tauri + React decision from v1/v2.** The reversal and its
> reasoning are in §2.1. Everything conceptual survives (EditDoc, timeline spec, GIF
> approach, phases); the implementation substrate changes.

---

## 1. Goals

The app has **three tabs**, mapping to your workflow stages:

| Tab | What it does | Your items |
|---|---|---|
| **Record** | Screen + iPhone (Continuity Camera) + mic capture, perfectly synced | #4, #5 (capture half) |
| **Export** | MOV → MP4 (remux or transcode), GIF | #1, #8 |
| **Edit** | Timeline (trim, cut, snap, combine), crop, **blur**, facecam composite, animated frame | #2, #3, #5, #6, #7, #9 |

Full item list, ranked by build order:

| # | Ask | Where |
|---|---|---|
| 1 | `.mov` → `.mp4`, keep quality, cut size | Export tab, Phase 1 |
| 8 | Export video → GIF | Export tab, Phase 1 |
| 2 | Trim, mute recorded audio, crop aspect | Edit tab, Phase 2 |
| 9 | **Blur** *(added 2026-08-20)* | Edit tab, Phase 2 |
| 7 | Timeline editing — trim, cut, snap | Edit tab, Phases 2–3, spec §3.2 |
| 3 | Cut & combine clips | Edit tab, Phase 3 |
| 4 | Record screen + webcam/iPhone | Record tab, Phase 4 — **now in scope**, see §2.3 |
| 5 | Composite screen + face cam | Edit tab, Phase 5 |
| 6 | Face cam rounded square + animated border frame | Edit tab, Phase 5 |

Item #4 was previously deferred ("keep using QuickTime"). That decision assumed
building capture from scratch. **Pen-Fight-Stream changes the math**: you already wrote
a working ScreenCaptureKit + AVCaptureSession + AVAssetWriter recorder with Continuity
Camera support. Adapting it is far cheaper than writing it, and owning capture buys the
single biggest win in the whole plan — **perfect screen/facecam sync for free** (§2.3).

### Non-goals

- A general-purpose NLE. No multi-track free-form timeline, no keyframed effects, no grading.
- Titles, captions, transitions, music beds.
- Windows/Linux. Cloud rendering. Streaming (Pen-Fight's live-stream concerns stay behind).

---

## 2. Decisions

### 2.1 Stack: native SwiftUI, built on Pen-Fight-Stream — *reverses v1's Tauri choice*

[Pen-Fight-Stream](https://github.com/yamparalarahul27/Pen-Fight-Stream) is a native
Swift app: SwiftUI + ScreenCaptureKit + AVFoundation + a Metal-backed Core Image
compositor, ~2,100 lines, and the code quality is genuinely good. Three things follow:

1. **The Record tab cannot live in a webview.** ScreenCaptureKit, AVCaptureSession,
   and Continuity Camera are native APIs; WKWebView has no usable `getDisplayMedia`.
   Reusing your recorder means a native shell — full stop.

2. **Going native dissolves most of the old plan's machinery.** AVFoundation natively
   covers nearly everything we were going to shell out to ffmpeg for:

   | Need | Native API |
   |---|---|
   | MOV → MP4 remux | `AVAssetExportSession` passthrough preset, `.mp4` output |
   | Web-ready output | `shouldOptimizeForNetworkUse = true` (≙ `+faststart`) |
   | Transcode H.264/HEVC | export presets / `AVAssetWriter` — VideoToolbox, hardware |
   | Trim without re-encode | passthrough export with `timeRange` |
   | Exact cut & concat | `AVMutableComposition` + re-encode export |
   | Crop, blur | `AVMutableVideoComposition` + Core Image filters |
   | Facecam composite | your `FrameCompositor`, run offline — same CIImage code |
   | **Animated border** | `AVVideoCompositionCoreAnimationTool` — CALayer animations burned into the export; *the* purpose-built API for this |
   | Metadata, keyframes | `AVAsset`, `AVSampleCursor` |
   | Waveforms, thumbnails | `AVAssetReader`, `AVAssetImageGenerator` |

   ffmpeg's role shrinks from "the entire engine" to two jobs where it is genuinely
   better (§2.5).

3. **The "progressive for distribution" argument that picked Tauri is weaker than it
   looked.** R2 upload from Swift is a solved problem (S3-compatible PUT + SigV4 —
   [Soto](https://github.com/soto-project/soto) or ~150 hand-rolled lines). Social
   auto-posting is REST + OAuth, tedious but fine in Swift. What we give up is web-code
   sharing with your site and faster UI iteration; what we gain is your existing
   recorder, dramatically less pipeline code, native preview/export parity (§2.2), and
   a real Mac app with zero runtime baggage.

**Reuse inventory** (from the repo, adapted into this project):

| File | Fate |
|---|---|
| `CameraController.swift` | ~verbatim — already discovers `.continuityCamera`, preview layer, frame/mic taps |
| `Compositor.swift` (`FrameCompositor`) | ~verbatim — aspect fill/fit, rounded/circle masks, Metal CIContext; reused live (Record) *and* offline (Edit) |
| `CameraPlacement.swift` | ~verbatim — becomes the EditDoc `facecam` block; it's already `Codable` |
| `Recorder.swift` | adapted — capture target becomes any display/window (§2.3); camera stops being burned in |
| `AudioUtil`, `Diagnostics`, `FramingGuide` | verbatim |
| `GameWebView`, game-specific `LiveState`/`StudioModel`/`ContentView` | left behind / rewritten |

The app stays SPM-based with `scripts/build-app.sh`, like Pen-Fight-Stream — no
`.xcodeproj` to babysit.

### 2.2 One rendering path — now literally one object

v1 solved preview/export mismatch with a shared canvas-drawing module. Native gives us
something strictly better: **`AVVideoComposition` is accepted by both
`AVPlayerItem.videoComposition` (preview) and `AVAssetExportSession.videoComposition`
(export).** The Edit tab's player shows cuts, crop, blur, and the facecam composite
through the *same object* the export uses. Parity is structural, not disciplined.

### 2.3 Record tab: separate synced files, not burn-in

Pen-Fight-Stream composites the camera into the recording live — right for streaming,
wrong for editing: a burned-in camera can never be repositioned, restyled, or removed.

The Record tab instead writes a **take** — a folder:

```
Take 2026-08-20 10.31.42/
├── screen.mov     # display/window video + system audio
├── camera.mov     # iPhone/webcam video + microphone audio
└── take.json      # devices, start PTS, display info
```

The key property: both writers live in one process and both streams are timestamped by
the same host clock, so both `AVAssetWriter` sessions start at the **same source time**
→ the files are aligned by construction. The v1 plan's alignment machinery (waveform
drag UI, cross-correlation) is no longer needed for takes recorded here — it survives
only as a fallback for pairs recorded outside the app (§7.5).

Capture target changes from "our own window" to a picker: any display or any window
(`SCContentSharingPicker` on macOS 14+, manual `SCShareableContent` list as fallback).
Camera preview + framing ghost (`FramingGuide`) carry over so you can see yourself
while recording.

A later "quick mode" can re-enable live burn-in (record → done, no edit pass) — cheap
to add since `FrameCompositor` still does both.

### 2.4 Export default: 1080p H.264 MP4

Unchanged from v1: H.264 + AAC + faststart is the safe web default; HEVC and a
quality/archive preset in the list. Hardware-encoded via VideoToolbox — which is what
`AVAssetWriter`/export presets use natively. One synergy worth noting: recordings made
by *our* Record tab are already H.264 (your `Recorder.swift` writes H.264 at 14 Mbps),
so their MOV → MP4 export is a **remux — instant and lossless**.

### 2.5 ffmpeg: two jobs only — GIF and lossless concat

- **GIF** (§2.6): ffmpeg's `palettegen`/`paletteuse` has no native equal
  (`CGImageDestination` GIFs use naive palettes and look muddy).
- **Lossless multi-segment export**: passthrough-exporting an `AVMutableComposition`
  with edits produces edit-list-heavy MP4s that some players mishandle; ffmpeg's concat
  demuxer (`-c copy`) is the proven path when you want cut+combine *without*
  re-encoding. (Re-encoded concat stays fully native.)

Still resolved from disk (`/opt/homebrew/bin`, `$PATH`), still not bundled — same
reasoning as v1: Homebrew's ffmpeg is dynamically linked and bundling needs a static
build; not worth it until the app is distributed. Missing ffmpeg = GIF and
lossless-concat buttons explain how to install (`brew install ffmpeg`); everything else
works without it.

### 2.6 GIF is an output *format*, not a preset

Unchanged from v2. GIF reuses the whole upstream pipeline (timeline, crop, blur,
composite) — only the final encode differs, so it's `output.format: "gif"` in the
EditDoc. Two-pass palette (`stats_mode=diff` — suits screencasts' static backgrounds),
defaults 15 fps / 800 px / loop forever / Bayer dither, no audio (say so in the UI),
size estimate before export, warning past ~30 s — GIF has no real inter-frame
compression and can outweigh its source MP4. For your own site prefer a looping muted
`<video>`; GIF is for READMEs, docs, chat. Recipes: §7.4.

When exporting GIF from an *edited* timeline, the pipeline renders the composition to a
temp MP4 first (native), then runs the ffmpeg palette pass on that.

### 2.7 Blur — *new in v3*

Privacy blur for screen recordings: hide tokens, emails, customer data. Modeled as
regions attached to **source time** (not output time), so a blur stays glued to its
content when segments are trimmed or reordered:

- Rect (normalized 0–1 coordinates, resolution-independent) + time range + radius
- Multiple regions per source; whole-take range as the common default
- Rendered with `CIGaussianBlur` masked to the rect, inside the shared
  `AVVideoComposition` — previewed live, identical in export (§2.2)
- UI: drag a rect on the player, adjust its range on the timeline (a thin strip under
  the segment), like a minimal version of a caption track

---

## 3. Architecture

The v1 rule survives translation: **the pipeline is a library, the app is a client.**

```
Yamparala-Video/
├── docs/PLAN.md
├── Package.swift                      # SPM app, like Pen-Fight-Stream
├── Resources/Info.plist               # camera/mic/screen usage strings
├── scripts/build-app.sh               # adapted from Pen-Fight-Stream
└── Sources/
    ├── YVCore/                        # NO UI. EditDoc (Codable), render planning,
    │   ├── EditDoc.swift              #   probe/keyframes, waveform extraction,
    │   ├── RenderPlan.swift           #   AVComposition/VideoComposition builders,
    │   ├── Exporter.swift             #   ffmpeg arg builders (GIF, concat)
    │   └── ...
    └── YamparalaVideo/                # SwiftUI app shell: three tabs
        ├── Capture/                   # CameraController, FrameCompositor, CameraPlacement,
        │                              #   AudioUtil, FramingGuide — from Pen-Fight, verbatim.
        │                              #   (Inside the app target rather than a separate module:
        │                              #   splitting it out would mean `public`-annotating all of
        │                              #   your code for zero benefit — the CLI never captures.)
        ├── RecordTab/
        ├── ExportTab/
        └── EditTab/                   # player, timeline, inspector
```

`YVCore` never imports SwiftUI. A later `yv` CLI target (`yv render project.json`)
depends on `YVCore` alone — the "render → upload → post, unattended" future needs no
restructuring, exactly as in v1.

### 3.1 The EditDoc

Same concept as v1 — a `Codable` document; every render is a pure function of it.
Notable changes: `facecam` *is* `CameraPlacement` (already `Codable` in your repo) plus
the frame-pack block; `blurs` added; `sources` gains take-awareness.

```jsonc
{
  "version": 3,
  "output": {
    "format": "mp4",                   // mp4 | gif
    "width": 1920, "height": 1080, "fps": 30,
    "preset": "web-safe-h264",         // web-safe-h264 | web-small-hevc | archive-quality
    "gif": { "fps": 15, "width": 800, "loop": true, "dither": "bayer" }
  },
  "sources": [
    { "id": "screen", "path": "…/Take …/screen.mov", "role": "screen" },
    { "id": "face",   "path": "…/Take …/camera.mov", "role": "facecam",
      "offsetMs": 0 }                  // 0 by construction for our takes (§2.3);
  ],                                   // nonzero only for externally recorded pairs
  "timeline": [
    { "sourceId": "screen", "inMs": 3500, "outMs": 80000 },
    { "sourceId": "screen", "inMs": 95000, "outMs": 120000 }
  ],
  "screen": {
    "crop": { "mode": "aspect", "aspect": "16:9" },   // aspect | rect | none
    "muteAudio": true
  },
  "blurs": [                           // §2.7 — source-time, normalized rects
    { "sourceId": "screen", "rect": { "x": 0.62, "y": 0.08, "w": 0.3, "h": 0.06 },
      "fromMs": 0, "toMs": null, "radius": 24 }
  ],
  "facecam": {
    "enabled": true,
    "placement": {                     // == CameraPlacement, verbatim
      "fillMode": "Fill", "corner": "Bottom right",
      "sizeFraction": 0.28, "offset": 0, "shape": "Rounded"
    },
    "frame": { "pack": "neon-lines", "params": { "speed": 1.0, "hue": 190 } },
    "audio": { "enabled": true, "gainDb": 0 }
  }
}
```

### 3.2 Timeline: model and interactions

*(Carried from v2 nearly intact — the spec was UI-framework-agnostic on purpose.)*

The timeline UI is a **view over `timeline[]` in the EditDoc** — every interaction
below is a pure edit of that array, which keeps undo/redo trivial (snapshot the array —
SwiftUI's `UndoManager` registration wraps it) and keeps the render path ignorant of
the UI.

**Model.** One track. Segments laid end to end in output order — no "gap" concept,
because the output is a concat of segments, not an absolute-time composition. This is
the difference between this tool and a real NLE, and it removes ~80% of timeline
complexity (no collision detection, no empty space, no z-order).

```
        ┌──────────────┬───────┬──────────────────┐
track   │  seg A       │ seg B │  seg C           │   ▶ output order
        └──────────────┴───────┴──────────────────┘
        ▲ trim handles at every edge   ▲ playhead anywhere
```

**Interactions.**

| Action | Gesture / key | EditDoc effect |
|---|---|---|
| Trim | drag a segment's left/right edge | change that segment's `inMs`/`outMs` |
| Cut (blade) | `S` or `⌘K` at playhead | split segment into two at playhead time |
| Delete | select + `⌫` | remove segment; the rest close up (ripple) |
| Reorder | drag segment horizontally | reorder `timeline[]` |
| Navigate | `Space`, `J`/`K`/`L`, `←`/`→` frame-step, `Home`/`End` | playhead only |
| Zoom | `⌘+`/`⌘-`/pinch, `⇧Z` fit-all | view state only, not in EditDoc |

**Snapping.** Magnetic within ±8 *screen* points (zoom controls how sticky snapping
feels in time units — zoomed in = finer). Hold `⌥` to disable while dragging. Targets,
in priority order when several are in range:

1. **Playhead** — park it where you want the cut, drag an edge to it
2. **Segment boundaries** — gapless joins after reorder
3. **Keyframes** of the source (via `AVSampleCursor` sync-sample stepping), drawn as
   ticks on the segment — snapping an edge to a keyframe is what makes a **Fast**
   (no-re-encode) cut land exactly where you see it instead of drifting to the nearest
   keyframe at render time. Visible and steerable, not a surprise.
4. **Whole seconds** on the ruler

When a snap engages: edge highlight, a vertical guide through the target, and the drag
position holds at the target until the pointer escapes the threshold.

**Waveform & thumbnails.** Per-segment audio waveform (`AVAssetReader` PCM decimation)
and sparse thumbnails (`AVAssetImageGenerator`), cached per-source keyed by file hash,
generated once on import.

**Blur strip.** Blur regions (§2.7) render as a thin bar under the segment spans they
cover; dragging its ends adjusts `fromMs`/`toMs` with the same snapping.

---

## 4. Build phases

Each phase ends at something you'd use daily.

### Phase 0 — Scaffold ✅ (2026-08-20)

- [ ] `brew install ffmpeg` — **user action needed** (installer wants an admin password)
- [x] SPM project per §3; capture sources copied verbatim from Pen-Fight-Stream
      (CameraController, FrameCompositor, CameraPlacement, AudioUtil, Diagnostics,
      FramingGuide, LiveState); `build-app.sh` + `Info.plist` adapted; new app icon
- [x] Tab shell: Record / Export / Edit (Record/Edit are placeholders naming their phase)
- [x] `YVCore`: EditDoc (Codable, round-trip tested), `MediaInfo.probe` via `AVAsset`
- [x] Verified: builds clean, launches, signed with the machine's Apple Development
      identity (the Developer ID from Pen-Fight's script isn't on this Mac — permissions
      still persist across builds, which is what matters)

### Phase 1 — Export tab ✅ code / ⏳ GIF validation

- [x] Probe → remux/transcode branch (`AVAssetExportSession.compatibleFileTypes`);
      passthrough + `shouldOptimizeForNetworkUse`; per-row "remux (lossless)" vs
      "transcode" badge before you convert
- [x] Presets: Web Safe H.264 1080p / Web Small HEVC 1080p / Archive highest;
      "Remux when possible" toggle to force re-encode
- [x] Batch: drop several files, Convert All (serial — one VideoToolbox encode at a time)
- [x] Before/after size + % saved; Show in Finder; collision-safe output names
- [x] GIF: single-pass palette args, fps/width/dither controls, range fields,
      heuristic size estimate on the button, install guidance when ffmpeg is missing
- [ ] GIF validated end-to-end — **blocked on ffmpeg install**
- [x] Tests: 7 passing — probe, remux, forced transcode, naming, GIF args, EditDoc
      round-trip, against a synthesized H.264 movie (real VideoToolbox, no mocks)

**Phase 1 done when:** drop a `.mov`, get a web-ready `.mp4` in seconds — or a GIF of a
range. *(MP4 path: done and tested. GIF: code ready, awaiting ffmpeg.)*

### Phase 2 — Edit tab v1: timeline, trim, crop, blur (items #2, #9, #7)

Single-clip timeline per §3.2 — one source, one segment, trim handles.

- [ ] `AVPlayer` preview with frame-step, timecode, `J`/`K`/`L`
- [ ] Timeline strip: segment, trim handles, playhead, zoom
- [ ] Snapping v1: playhead, keyframe ticks, whole seconds
- [ ] Keyframe extraction (`AVSampleCursor`), waveform + thumbnails, cached by file hash
- [ ] Trim modes, honestly labelled: **Fast** (passthrough, lands on keyframes) vs
      **Exact** (re-encode, frame-accurate)
- [ ] Mute toggle (drop audio track from export)
- [ ] Crop: aspect presets (16:9, 1:1, 9:16, 4:5) + freeform rect, drag overlay on the
      player; letterbox alternative (`AVMutableVideoComposition` render-size + transform)
- [ ] **Blur** (§2.7): drag-rect on player, multiple regions, time-range strip on the
      timeline, live in preview via the shared `AVVideoComposition`

**Done when:** open a recording, trim with snapping, blur a token, crop to 1:1, export.

### Phase 3 — Edit tab v2: cut & combine (items #3, #7)

- [ ] Blade (`S` / `⌘K`), ripple delete, drag-reorder with segment-boundary snapping
- [ ] Multiple segments, multiple sources per project
- [ ] Undo/redo as EditDoc snapshots
- [ ] Export paths: **Exact** = `AVMutableComposition` re-encode (native);
      **Fast** = per-segment passthrough trims → ffmpeg concat demuxer `-c copy` (§2.5)
- [ ] Total-duration readout

**Done when:** blade out the boring middle, pull in a chunk from another file, reorder,
export one MP4.

### Phase 4 — Record tab (item #4)

Adaptation of your `Recorder.swift`, per §2.3:

- [ ] Capture-target picker: any display / any window (`SCContentSharingPicker`,
      macOS 14+)
- [ ] Camera: `CameraController` as-is (Continuity Camera included) + preview +
      `FramingGuide` ghost
- [ ] Two writers, one clock: `screen.mov` (display + system audio), `camera.mov`
      (camera + mic), sessions started at the same source time → zero-offset take
- [ ] Take folder + `take.json`; "Open in Edit" button on the finished take
- [ ] Mic/system gain sliders + level meters (`AudioUtil` reused), elapsed/size ticker
- [ ] Permission flows carried over (screen-recording guidance text already written)

**Done when:** record a take, click "Open in Edit", and the facecam is already in sync.

### Phase 5 — Facecam composite + animated frame (items #5, #6) — *needs your reference*

- [ ] Facecam as a second layer in the Edit preview + export: `FrameCompositor` logic
      re-hosted in the shared `AVVideoComposition` (custom compositor); placement UI =
      Pen-Fight's controls (corner, size, fill/fit, shape, mirror)
- [ ] External pairs (recorded outside the app): manual waveform-drag alignment sets
      `offsetMs` (§7.5)
- [ ] **Frame packs**: parameterized `CALayer` trees with `CAAnimation`s
      (`beginTime = AVCoreAnimationBeginTimeAtZero`), burned in via
      `AVVideoCompositionCoreAnimationTool` on export, same layer live over the preview
- [ ] Frame designer panel: sliders for pack params, live over a paused frame
- [ ] First pack modelled on your reference video
- [ ] Audio routing: facecam mic by default, screen audio muted, per-track gain

**Done when:** screen + face in, one polished video out — rounded facecam, animated
border, lips in sync.

### Phase 6 — R2 upload

- [ ] S3-compatible PUT to R2: Soto, or minimal hand-rolled SigV4; credentials in Keychain
- [ ] Post-export upload with progress; multipart for large files
- [ ] Correct `Content-Type`/`Cache-Control`; copy public URL to clipboard

### Phase 7 — Later

- `yv render project.json` CLI (YVCore is already UI-free)
- Auto-post to YouTube / X / LinkedIn after upload
- Quick mode: live burn-in recording (record → done, no edit pass)
- Auto cross-correlation alignment for external pairs (§7.5's manual UI, automated)
- **Auto-zoom on clicks** — now genuinely reachable: we own capture, so a global event
  monitor can log cursor/click positions into `take.json` during recording
- Bundled static ffmpeg + signing/notarization, if the app is ever distributed

---

## 5. Sequencing

Phases 1–3 replace your current manual work fastest and carry no capture risk.
Phase 4 is mostly *your existing code* being re-aimed — it can be pulled earlier if you
want the sync win sooner; nothing in 1–3 depends on it. Phase 5 is the taste-driven
phase and iterates; it's blocked on your reference video either way. Phase 6 is small
and can slot in anywhere after Phase 1.

---

## 6. Risks

| Risk | Mitigation |
|---|---|
| **Passthrough export of edited compositions** produces MP4s some players mishandle (edit lists) | Fast multi-segment path goes through ffmpeg concat instead (§2.5); single-range passthrough trims are safe. Validate both on Safari/Chrome early in Phase 3. |
| **`AVVideoCompositionCoreAnimationTool` quirks** — offline animation timing, layer timing bugs are a known rough edge | Prototype the border burn-in in Phase 5 week 1 on a 10 s clip before building the designer UI. Fallback: render the border with `FrameCompositor`-style CIImage drawing per frame (same pack params). |
| **Same-clock assumption for takes** (§2.3) — SCK and AVCapture PTS should share the host clock, but verify | Phase 4 acceptance test: clap on camera while clicking on screen; inspect offset. If nonzero-but-constant, record the delta in `take.json` and apply it invisibly. |
| **VideoToolbox quality at a given bitrate** trails software x264 | Archive/quality preset re-checks against a real recording in Phase 1; pick defaults from evidence. |
| **Fast trim lands on keyframes** and surprises | Keyframe ticks + snapping make it visible (§3.2); Exact mode one click away. |
| **GIF sizes explode** — 256 colours, no real inter-frame compression | Conservative defaults, pre-export estimate, >30 s warning (§2.6); nudge toward looping muted MP4 for the site. |
| **Snapping feels wrong** — too sticky fights precision, too loose is useless | Threshold in screen points so zoom controls stickiness; `⌥` always disables. Tune in Phase 2. |
| **Blur that misses a frame** leaks the secret | Default blur range = whole take; range-narrowing is the deliberate act. Preview scrub near range edges before export. |
| Scope creep into a real NLE | §1 non-goals is the contract. |

---

## 7. Pipeline recipes

### 7.1 Native export sketches

Remux MOV → MP4 (Phase 1 fast path):

```swift
let session = AVAssetExportSession(asset: asset,
                                   presetName: AVAssetExportPresetPassthrough)!
session.outputFileType = .mp4
session.outputURL = out
session.shouldOptimizeForNetworkUse = true      // == +faststart
// trim (Fast mode): session.timeRange = CMTimeRange(...)  — lands on sync samples
await session.export()
```

Crop + blur share one `AVMutableVideoComposition` built from the EditDoc
(`AVVideoComposition(asset:applyingCIFiltersWithHandler:)` for the simple cases; a
custom `AVVideoCompositing` once the facecam layer joins in Phase 5). The same object
goes to `AVPlayerItem.videoComposition` for preview — §2.2.

Keyframe ticks (Phase 2): `track.makeSampleCursor(presentationTimeStamp: .zero)` then
`stepInPresentationOrder(byCount:)` over sync samples; cache the PTS list.

### 7.2 Take recording (Phase 4)

Two `AVAssetWriter`s, sessions started at the same source time:

```swift
// First screen frame arrives with pts P0 (host clock).
screenWriter.startSession(atSourceTime: P0)
cameraWriter.startSession(atSourceTime: P0)     // same clock domain → zero offset
```

`take.json` records `P0`, device names, display size, and (Phase 7) cursor events.

### 7.3 ffmpeg: lossless concat (Phase 3 Fast path)

```bash
# each segment first passthrough-trimmed natively to seg-N.mp4, then:
# list.txt:  file '/abs/seg-0.mp4' …
ffmpeg -f concat -safe 0 -i list.txt -c copy -movflags +faststart out.mp4
```

Requires identical codec/resolution/fps across segments — guaranteed when they come
from one source; when they don't, the Exact (native re-encode) path applies.

### 7.4 ffmpeg: GIF (Phase 1)

Two-pass palette — pass 1 learns the best 256 colours from the actual footage:

```bash
ffmpeg -ss 5 -to 15 -i in.mp4 \
  -vf "fps=15,scale=800:-1:flags=lanczos,palettegen=stats_mode=diff" palette.png

ffmpeg -ss 5 -to 15 -i in.mp4 -i palette.png \
  -lavfi "fps=15,scale=800:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 out.gif
```

Single-pass equivalent (what the app ships — no temp palette file):

```bash
ffmpeg -ss 5 -to 15 -i in.mp4 \
  -vf "fps=15,scale=800:-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle" \
  -loop 0 out.gif
```

- `-loop 0` = forever; `diff_mode=rectangle` re-encodes only the changed region —
  big savings on screencasts; `bayer` = smaller/crosshatch, `sierra2_4a` = smoother/larger.

### 7.5 Alignment — external pairs only

For screen+face pairs recorded *outside* the app (your existing files): extract mono
PCM from both (`AVAssetReader`, 8 kHz), draw stacked waveforms, drag to align →
`offsetMs`. Phase 7 automates via FFT cross-correlation over the same buffers. Takes
recorded in the app never need this (§2.3).

Workflow note until Phase 4 ships: keep recording the screen audio you intend to mute —
it's the alignment reference. Mute happens at export.

---

## 8. Open questions

1. **Record target:** full display, or a single window? (Both will exist — asking what
   the *default* should be for your workflow.)
2. **What do you typically blur** — small regions like tokens/emails (the §2.7 design),
   or ever a whole-window/background blur?
3. **Facecam ever full-frame** (intro/outro)? Cheap to model per-segment now, awkward later.
4. **Your existing recordings** — resolution and typical length? (Codec question is
   half-answered: Record-tab takes will be H.264 by construction; this is about your
   back catalog.)

## 9. What I need from you

- **The reference video** for the animated border — Phase 5 is blocked on it. A capture
  of it *animating* beats a still; the motion is the point.
- **One short sample pair** — a screen recording `.mov` + an iPhone facecam `.mov` from
  your current workflow, to validate the Edit pipeline against real files.
- **A green light on §2.1** — it reverses the earlier Tauri decision. The plan assumes
  yes (your repo is the reason), but say so explicitly and Phase 0 starts.

---

## Sources

- [Pen-Fight-Stream](https://github.com/yamparalarahul27/Pen-Fight-Stream) — your repo; the Record tab's foundation
- [LosslessCut](https://losslesscut.app/) — ffmpeg concat/trim patterns (GPL-2.0)
- [Tauri sidecar dylib issues](https://github.com/orgs/tauri-apps/discussions/9029) — why ffmpeg stays unbundled
- [Soto](https://github.com/soto-project/soto) — Swift AWS/S3 client, for R2
- [FFmpeg palette recipes](https://ffmpeg-api.com/learn/ffmpeg/recipe/picture-in-picture), [alpha masking notes](https://curiosalon.github.io/blog/ffmpeg-alpha-masking/) — retained from v1 research
- Historical (v1/v2): [Cap](https://github.com/CapSoftware/Cap) and [OpenScreen](https://github.com/siddharthvaddem/openscreen) evaluated as fork bases, rejected — Cap is AGPLv3 SaaS-shaped, OpenScreen archived June 2026
