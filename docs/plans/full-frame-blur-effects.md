# Whole-frame blur effects — implementation plan

**Status:** Planned only; implementation is paused pending the owner's review.
**Scope confirmed by the owner:** Whole-frame blur for visual effects, with editable controls.
**Planning date:** 2026-09-05.

This PR adds this document only. It does not implement an effect or change the app.
The defaults and interaction rules below are implementation proposals for review.

**See also:** [`video-use-enhancements.md`](./video-use-enhancements.md) proposes amendments
to sections 5, 7 and 8 of this plan (renderer parity, effect-stage pixel format, `blend`
cost, HDR sources) and a follow-on feature list. It is an addendum for review, not an
approved change to this document.

## 1. Prerequisite and repository baseline

The published `main` baseline inspected for this plan is `6cd0440`. It contains the
original crop/area-blur/zoom editor and GIF/WebP export. The local editing workspace
also contains completed but uncommitted timeline, native playback, project saving,
movie assembly, waveform, silence-removal and section-speed work. Its last completed
suite passed 326 checks; that is a prerequisite result, not validation of this feature.

**Before implementation:** commit/review the existing editor work separately and merge
it into the implementation branch. Reconcile the symbols below against that resulting
commit. Do not silently include that existing work in this documentation PR. Several
files listed below are local prerequisite files and are absent from published `main`.

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

Use **project version 3** when any blur effect exists, including a disabled effect.
Otherwise retain current version selection: v2 for speed edits, v1 for older edits.
Accept versions 1, 2 and 3; older builds must reject v3 rather than silently export
without its effects. Do not emit a nonempty effects field in v1/v2 output. On loading,
reject nonempty effects in a file claiming v1/v2.

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
source orientation → timeline cuts/speed → existing area obscuring → crop → zoom
→ whole-frame visual blur → output scaling / Movie fitting and letterbox
→ GIF palette or final encoder
```

Apply visual blur after crop and zoom, so it covers the visible recording. Movie bars
remain solid; the effect blurs the recording, not empty space around it. With cropped
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
| `Sources/Timeline.swift` — local prerequisite | ProjectClip persistence, v3 validation and defaults |
| `Sources/ProjectEditing.swift` — local prerequisite | Version selection, history selection, remap on every timeline edit |
| `Sources/TimelineView.swift` — local prerequisite | Effects lane, selection and drag routing; adapt playhead height |
| `Sources/ContentView.swift` | Effects mode/inspector, native preview activation, delete routing |
| `Sources/CropEditor.swift` | Handle the new enum case without drawing a crop/area/zoom handle over Effects preview |
| `Sources/Playback.swift` — local prerequisite | Shared full-frame rendering and cache/interaction behavior |
| `Sources/MoviePlayback.swift` — local prerequisite | Pass clip effects and local time into the shared renderer |
| `Sources/FFmpeg.swift` | Geometry/delivery separation, timed blend graph and all export entry points |
| `Sources/Movie.swift` — local prerequisite | Insert effect before fit/pad; namespace labels and retain audio |
| `Tests/main.swift`, `test.sh` | New tests; include non-UI helper source files in the CLI test build |
| `README.md` | Explain visual blur controls, timing rules, v3 compatibility and preview limits |

`build.sh` already compiles `Sources/*.swift`; no Xcode project or new package dependency
is needed. Avoid unrelated icon, encoder, audio-analysis or video-track changes.

## 7. Implementation sequence and gates

1. **Establish prerequisite baseline.** Review/merge the existing editor work and record
   its commit. Run its existing suite before changing effect behavior.
2. **Model and math.** Add serialization, validation, boundary snapping, remapping and
   weight tests. Gate: old projects round-trip, and v3 cannot be silently misread.
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
