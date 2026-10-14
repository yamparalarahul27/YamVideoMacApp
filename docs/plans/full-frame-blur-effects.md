# Whole-frame blur effects — implementation plan

**Status:** Implemented in phase 5 of the co-editing plan (2026-10-14). See section 10.
**Scope confirmed by the owner:** Whole-frame blur for visual effects, with editable controls.
**Planning date:** 2026-09-05. **Reconciled:** 2026-10-13.
**Coordinating plan:** [Local co-editing](local-coediting.md) takes precedence for
implementation order, inspector layout, shared mutations and schema versioning. Colour
normalization from the [Pocket 3 plan](pocket-3-colour.md) precedes creative blur.

This is a documentation-only plan. It does not implement an effect or change the app.
The defaults and interaction rules below are implementation proposals for review.

**See also:** [`video-use-enhancements.md`](./video-use-enhancements.md) proposes amendments
to sections 5, 7 and 8 of this plan (renderer parity, effect-stage pixel format, `blend`
cost, HDR sources) and a follow-on feature list. It is an addendum for review, not an
approved change to this document.

## 1. Prerequisite and repository baseline

The original plan inspected main at `6cd0440`. The current implementation baseline is
`timeline-editing` at `98a6789`, with timeline/native playback/project/movie/audio work now
committed in `a07829c`, plus navigation improvements. Published main is `cd431a3`; it has
HDR tone mapping, loudness normalization and subtitles. Integrate/review the editor branch
before implementation. Old suite counts are historical, not validation of this feature.

Then complete the shared command/undo foundation and Pocket 3 colour phase in the
coordinating plan. Blur UI and agent operations must use that same dispatcher and gesture
transactions; do not add a second history/coalescing system. Files formerly described as
local prerequisites below are committed on the editor branch, but absent from main.

The current area blur is `BlurRegion { id, rect }`, controlled by shared
`ExportSettings.blurStyle` and `blurStrength`. Keep it intact. A visual blur with fades
must have its own model; converting existing obscured areas into fading effects would
change their behavior.

## 2. User-visible behavior

1. Add an **Effects** mode alongside Crop, Blur and Zoom in the Recording workspace.
   Its first effect is **Full-frame Blur**. Existing Blur mode continues to edit areas.
2. **Add Blur Effect** adds a block at the edited playhead, with a default duration of
   3 seconds or the available remaining time, whichever is shorter.
3. Select the block to edit **Start**, **End**, **Amount**, **Mix**, **Fade In**,
   **Fade Out** and **Enabled**. Include **Jump to Effect**, **Delete**, and an empty
   state that explains how to add an effect. Full-frame effects have no position or
   resize rectangle.
4. The effects lane is separate from video, waveform and zoom lanes. Drag a block to
   move it; drag either edge to trim it. Numeric timing controls offer the same edits.
5. Effects mode opens the composed preview automatically. Paused parameter changes
   update that frame; playback demonstrates the fades. Keep the playhead stable while
   changing parameters. Crop/area editing can still show the source frame, but must
   clearly retain the existing **Edit frame** versus **Preview** distinction.
6. An effect belongs to one recording and also renders wherever that recording appears
   in a Movie export. It cannot extend onto a different recording.
7. Every action is undoable. A drag or continuous slider adjustment is one undo step,
   even if the gesture lasts longer than the existing 0.6-second coalescing window.

For the first release, permit multiple non-overlapping full-frame blur blocks on a
recording. Disabled blocks retain their reserved interval. Adjacent blocks may touch.
Moving or extending a block stops at a neighbor instead of silently changing it.
This is one effect lane, not stacked video tracks or a blend-mode editor.

### Proposed controls and defaults

| Control | Representation and bounds | Default |
|---|---|---|
| Start / End | Edited recording seconds; half-open interval `[start, end)` | Playhead to playhead + 3 s, clamped |
| Amount | Gaussian radius expressed at a 1080-pixel long edge; 0…80 | 24 |
| Mix | Original-to-blurred interpolation; 0…1, displayed as 0…100% | 1 |
| Fade In / Out | Seconds; each ≥ 0 and their sum ≤ effect duration | 0.25 s each, reduced to fit |
| Enabled | Boolean bypass without deleting the block | true |

Timing drags and typed values snap to the recording's rational frame cadence. Minimum
block duration is one frame. At the end of a recording, clamp Add to the last complete
frame interval; if no free interval of at least one frame exists, leave the project
unchanged and explain why. Trim changes clamp timing first, then proportionally reduce
fades if their sum no longer fits. Editing one fade clamps it to duration minus the
other fade. Amount/Mix zero and Enabled off are exact visual bypasses.

### Shared local editing integration (2026-10-13)

Expose add/update/remove/toggle effect commands by clip/effect ID through the parent
plan's dispatcher. Use revision checks, dry-run, remap-loss reporting and one transaction
per batch/gesture. Effects controls live in the selection inspector. An agent can request
an effect preview, adjust amount/fades, and have the human continue on the same block.
Do not steal the human's selection or playhead when an agent edits an effect.

## 3. Model, validation and project compatibility

Add `Sources/VisualEffects.swift` with a dedicated value type:

```swift
struct VideoBlurEffect: Identifiable, Codable, Equatable {
    var id: UUID
    var start: Double
    var end: Double
    var amount: Double
    var mix: Double
    var fadeIn: Double
    var fadeOut: Double
    var isEnabled: Bool
}
```

Add `VideoItem.blurEffects: [VideoBlurEffect] = []`. Extend `ProjectClip` with an optional
serialized `blurEffects` property; missing fields decode to an empty runtime array.
`ProjectClip.init(_:)` and `item()` must copy every value. Cache comparisons, recovery,
and history snapshots then include effect changes through `ProjectClip` equality.
Add the selected effect ID to `AppModel` and `EditHistory`, restoring it only if the
corresponding effect still exists.

Use the **next schema version after the colour phase**, assigned in the coordinating
plan's migration registry. The earlier independent v3 reservation is superseded: v3
belongs to document/agent foundations and v4 to colour. Migrate supported older files,
but write the current schema; never downgrade an edited project merely because it has
no active blur. Older builds must reject the effect-bearing schema rather than silently
export without effects. Reject nonempty effect fields in a file claiming a schema that
does not support them.

Validation must reject nonfinite values, duplicate IDs, negative timing, an end beyond
the edited duration, duration below one frame (with the existing numeric tolerance),
out-of-range amount/mix, negative fades, fade sums exceeding duration, overlapping
intervals, or effects whose media information is unavailable. Run these checks before
restoring a project. UI edits clamp ordinary input; corrupt files produce an error.

## 4. Timing contract, cuts and speed changes

All effect times are local to the **edited recording**, after section reordering,
trimming and speed changes. They are neither source timestamps nor global Movie time.

Use one pure `weight(at:)` evaluator and an equivalent FFmpeg expression generator:

```text
D = end - start
inside = isEnabled AND start <= t < end
uIn  = 1 when fadeIn  == 0, otherwise clamp((t - start) / fadeIn,  0, 1)
uOut = 1 when fadeOut == 0, otherwise clamp((end - t)   / fadeOut, 0, 1)
smooth(u) = u*u*(3 - 2*u)
w(t) = inside ? mix * smooth(min(uIn, uOut)) : 0
output(t) = original(t) * (1 - w(t)) + blurred(t) * w(t)
```

The blur radius stays fixed during a fade; only its contribution changes. The half-open
interval prevents adjacent effects from both being active at the boundary. Do not
introduce an expression that divides by a zero fade duration.

Integrate effect remapping into `AppModel.commitTimeline` alongside zoom remapping:

- Resolve the old effect's start to a source frame using `old.location(at:)`.
- Map that frame into the new timeline with `time(forSource:)`. If removed, remove the
  effect and include it in the edit's removal status message.
- Preserve the effect's duration in playback seconds, clamped to the new recording end.
  Rescale fades proportionally only if necessary. Remove blocks that cannot fit one
  frame. Splitting without changing footage leaves effects unchanged.
- Sort by start, breaking ties by ID. If reordering causes a collision, keep the first
  block and drop the later one with a status message. Undo restores all dropped blocks.
- Speed changes follow the same rule: the start follows its source frame, while duration
  and fades remain playback seconds. Test source-to-edited conversion for slow sections.
- Effects may cross cuts within their recording. They never cross a Movie clip boundary.

Whole-frame effects are not implicitly copied by the existing **Apply to All** command,
which currently copies crop/area-blur/zoom edits. Do not change that command's scope in
this feature.

## 5. Rendering contract

The shared order is:

```text
source orientation / input colour normalization → timeline cuts/speed
→ per-recording colour adjustments → existing area obscuring → crop → zoom
→ whole-frame visual blur → output scaling / Movie fitting and letterbox
→ subtitles / titles → GIF palette or final encoder
```

Use the Pocket 3 plan's explicit colour contract and the addendum's renderer-parity
checks; D-Log M correction and HLG/PQ tone mapping are distinct input paths. Keep
subtitles after blur. Apply visual blur after crop and zoom, so it covers the visible
recording. Movie bars remain solid; the effect blurs the recording, not empty space around it. With cropped
frame size `(W, H)`, use `sigma = amount * max(W, H) / 1080`. Apply blur before final
scaling so changing export resolution preserves its apparent strength.

### Native preview

Extend the shared `renderFrame` path in `Playback.swift` with `blurEffects` and the
recording-local time. After crop/zoom, crop to the visible bounds, clamp edge pixels,
apply `CIGaussianBlur`, and crop back to those exact bounds. Interpolate the original
and blurred images using `w(t)` in a shared helper. Never blend with the unobscured
source image: existing area redaction must remain in both branches.

`PlaybackController.makeItem` supplies recording-local composition time.
`MovieCompositor` already subtracts its instruction start; pass that local value and
the instruction clip's effects into the same renderer. Do not use global Movie time.

While editing Effects, keep composed preview active. Add explicit begin/end interaction
handling for undo and debounce composition rebuilds during slider movement (target
80–120 ms, with a final immediate update on release). Cancel obsolete builds and seek
to the latest requested time. Selection/deletion/settings edits must invalidate the
cached item. Do not encode a temporary movie for every preview adjustment.

### FFmpeg export

Refactor the current combined tail into geometry and delivery stages, with the visual
effect graph inserted between them. Thread `blurEffects: [VideoBlurEffect] = []` through
`exportArguments`, `paletteArguments`, `exportCommands`, `export`, and the edited-graph
builder. Keep existing no-effect signatures source-compatible and behavior unchanged.
`AppModel` export execution and displayed commands must both pass the actual effects.

Proposed graph for one active effect, after geometry and before delivery:

```text
[geometry]split=2[original][blurInput];
[blurInput]gblur=sigma=<scaled amount>[blurred];
[original][blurred]blend=all_expr='A*(1-(<w(T)>))+B*(<w(T)>)':shortest=1[effectOut]
```

`<w(T)>` is generated numeric syntax, not a literal FFmpeg variable. The first stream
is original and the second blurred. Use collision-free labels for every effect; Movie
input namespacing must include all new labels. Multiple non-overlapping blocks may be
processed sequentially with the same bypass rule. No-effect/disabled/zero-contribution
cases should bypass unnecessary processing.

The official [FFmpeg blend documentation](https://ffmpeg.org/ffmpeg-filters.html#blend)
provides `all_expr`, per-frame seconds `T`, input samples `A/B`, and framesync options.
The exact graph, edge behavior and pixel format negotiation still require the prototype
checks below; documentation support is not proof of preview/export parity.

Both GIF passes must receive identical effects before palette generation/use. Preserve
current audio maps, AAC timing, rational frame rates, progress, cancellation and atomic
Movie publishing. Do not add another FPS stage after zoompan: local testing previously
found excessive EOF padding in that arrangement. The effect graph must not reset PTS,
change frame count or extend the stream.

## 6. File-by-file implementation map

Paths marked **local prerequisite** exist in the current workspace but are not present
at the published baseline described in section 1.

| File | Required work |
|---|---|
| `Sources/VisualEffects.swift` — new | Value type, timing/weight helpers, validation and deterministic remapping |
| `Sources/VisualEffectsEditing.swift` — new | Add/select/move/trim/update/delete/toggle actions, gesture-scoped undo, preview refresh |
| `Sources/VisualEffectsView.swift` — new | Inspector and accessible timeline block with both trim handles |
| `Sources/Models.swift` | Effect collection on VideoItem; Effects case/label in EditorMode |
| `Sources/AppModel.swift` | Selected effect ID; export argument propagation and displayed command parity |
| `Sources/Timeline.swift` — local prerequisite | ProjectClip persistence, effect-schema validation and defaults |
| `Sources/ProjectEditing.swift` — local prerequisite | Version selection, history selection, remap on every timeline edit |
| `Sources/TimelineView.swift` — local prerequisite | Effects lane, selection and drag routing; adapt playhead height |
| `Sources/ContentView.swift` | Effects mode/inspector, native preview activation, delete routing |
| `Sources/CropEditor.swift` | Handle the new enum case without drawing a crop/area/zoom handle over Effects preview |
| `Sources/Playback.swift` — local prerequisite | Shared full-frame rendering and cache/interaction behavior |
| `Sources/MoviePlayback.swift` — local prerequisite | Pass clip effects and local time into the shared renderer |
| `Sources/FFmpeg.swift` | Geometry/delivery separation, timed blend graph and all export entry points |
| `Sources/Movie.swift` — local prerequisite | Insert effect before fit/pad; namespace labels and retain audio |
| `Tests/main.swift`, `test.sh` | New tests; include non-UI helper source files in the CLI test build |
| `README.md` | Explain visual blur controls, timing rules, project compatibility and preview limits |

`build.sh` already compiles `Sources/*.swift`; no Xcode project or new package dependency
is needed. Avoid unrelated icon, encoder, audio-analysis or video-track changes.

## 7. Implementation sequence and gates

1. **Establish prerequisite baseline.** Review/merge the existing editor work and record
   its commit. Complete the coordinating plan's shared-command and colour prerequisites, then run
   the existing suite before changing effect behaviour.
2. **Model and math.** Add serialization, validation, boundary snapping, remapping and
   weight tests. Gate: old projects round-trip, and the new effect schema cannot be silently misread.
3. **Renderer prototype.** Implement one effect in native and FFmpeg render paths before
   adding the inspector. Gate: timing, edge handling, fades and frame counts pass on
   real rendered fixtures. Calibrate the two blur kernels here; do not assume equal
   numeric radius values produce equal images.
4. **Editor integration.** Add the lane, inspector, gestures, undo and composed-preview
   updates. Gate: a long drag is one undo step and rapid edits never show stale effects.
5. **Delivery.** Cover all exports, Movie offsets, recovery and manual UX checks; document
   any remaining kernel differences. Build and open a saved demo for owner review.

## 8. Acceptance checks

- **Timing math:** sample before start, exact start, fade midpoint, hold, end-minus-one
  frame, exact end and after end. Verify zero-length fades, disabled, Amount 0 and Mix 0.
  Invalid numbers and overlaps fail validation. Test 24, 30 and 30000/1001 fps snapping.
- **Editing:** add near clip end; move/trim against neighbors; shrink beneath fade sum;
  numeric edits; delete; toggling; long gestures; undo/redo; project save/open/recovery.
- **Timeline transforms:** split, trim, deletion, reorder, silence cuts, 0.25× and 4×
  sections. Check removed anchors, collision reporting, and exact undo restoration.
- **Image behavior:** use a generated high-frequency fixture and a constant-color edge
  fixture. At default amount/full mix, high-frequency luma variance in a central patch
  should fall below 25% of the original. Variance should decrease monotonically through
  fade-in and increase through fade-out; a Mix 0.5 hold should sit between the two.
- **Preview/export parity:** use matching timestamps and a lossless reference before
  lossy encoding. Require fade boundaries within one output frame; central-patch blur
  variance within 15% between native and FFmpeg results. Inspect edges separately for
  transparent/black halos and color shifts. If kernel calibration misses that tolerance,
  resolve or explicitly revise the plan before claiming parity.
- **Composition:** test crop + zoom + area redaction + visual blur together. Both blend
  branches must retain existing redaction. Include rotated portrait footage and a Movie
  where the affected recording is second; its fade must start at the correct local time.
- **Exports:** MP4, GIF and WebP when the installed encoder supports it; both GIF passes;
  silent sources and audio-bearing sources; many fractional speed sections. Effect-on
  and effect-off exports must have the same frame count, duration and audio alignment.
- **Lifecycle:** cancel export; preserve an existing Movie destination; rapid seeks and
  slider updates; leave/re-enter Effects; switch recordings; restore a missing source.
- **Performance:** compare the same 1080p/30 fps fixture with and without the effect,
  record preview responsiveness and peak export memory, and verify memory does not grow
  with every frame. Large-frame optimization must preserve the same normalized radius
  and be applied consistently to preview and export.
- **Final checks:** run `./test.sh`, `./build.sh`, and `git diff --check` after implementation;
  manually inspect the minimum-size window, keyboard focus, numeric fields and VoiceOver
  labels. Save a demo showing a timed blur fading in/out over an edited recording.

## 9. Explicitly deferred

Stacked video tracks and user-selectable blend modes; masks/face tracking; new animated
area-redaction behavior; motion/radial/lens blur; arbitrary keyframes; cross-recording
adjustment layers; third-party effect plugins. These are separate features. This plan
should not be used as approval to begin implementing them or the blur feature while
the owner has asked for work to remain paused.

## 10. Implementation status (2026-10-14)

The owner asked to start phase 5. Implemented as planned, with these measured decisions:

- **Model:** `VideoBlurEffect` and `TimelineMarker` (`VisualEffects.swift`), project schema v5
  shared with markers. Validation, frame snapping, remapping on every timeline edit (start
  follows its frame; duration and fades stay in playback seconds; fades shrink to fit;
  collisions keep the earlier block), and removal reporting alongside zooms.
- **Effect stage colour contract (addendum §1):** both renderers blur and mix on the
  frame's *encoded* values in float RGB, so there is no linear-versus-gamma divergence and
  no subsampled chroma blurred twice as far. ffmpeg converts from the frames' own matrix and
  range to `gbrpf32le`, uses `gblur … steps=3`, and returns to 10-bit BT.709. Core Image
  matches into the frame's decoding space, blurs with the edge clamped, and dissolves. The
  measured Core Image radius equals ffmpeg's sigma (`BlurCalibration.coreImageRadiusPerSigma = 1`).
- **Per-frame weight, not a per-pixel expression (addendum §2):** `blend=all_expr` cost 73 s
  for 6 s of 1080p. The app writes a `sendcmd` script setting each frame's `all_opacity`
  from `VideoBlurEffect.weight` (timed half a frame early so rounding cannot shift it), and
  gates `gblur`/`blend` to the effect's interval: 3.8 s for the same clip, against 1.3 s
  for the float round trip alone. The fade curve is the plan's smoothstep exactly.
- **Measured parity** (`./test.sh`, 1280×720 checkerboard and hard-edge clip, amount 24):
  both renderers' per-frame blur weight matches the timing maths within 0.06 at the frame
  before the start, the start, mid-fades, the hold, the last frame and the end; hold detail
  falls to under 1% of the sharp frame in both; the profile across a hard colour edge
  matches within 4.4/255 and the frame border within 0.8/255 (no halo). Effect-on and
  effect-off exports have the same frame count; both GIF passes carry the effect; a Movie
  times the second recording's effect from that recording's start.
- **HDR (addendum §3):** effects run after tone mapping. An HDR recording kept as HDR is
  refused with a reason, in export and in the inspector, rather than written blurred and
  tagged Rec.709.
- **Editing:** Effects mode shows the composed Preview; dragging a block or its edges shows
  the new place during the drag and commits one step on release, stopping at neighbours
  with snapping; sliders commit one step per drag and swap only the video composition, so
  playback is not rebuilt. Effect edges and markers are snap targets.
- **Agents:** add/update/remove effect and marker commands with defaults, chosen ids and
  movie time; state, selection, reveal and highlights include them; `preview` with
  `composed: true` renders the frame as Preview plays it. Every command is described in the
  `catalog` request.

Not done: the boundary contact-sheet tool (addendum §4) — its frame set is covered by the
automated timing checks instead; a 1080p peak-memory measurement; hands-on keyboard focus
and VoiceOver checks; a saved demo project for owner review.
