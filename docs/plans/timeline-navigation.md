# Timeline navigation — research and implementation plan

**Status:** Planned. Section 4 is approved for implementation; sections 5 and 6 are
research notes held for later review.
**Research date:** 2026-09-06.
**Baseline inspected:** `cd431a3` (published `main`, HDR tone mapping and burned-in
subtitles) merged with the local timeline/movie/silence-removal workspace. Suite result
at the time of writing: 391/393. The two failures are an ffmpeg 9 fixture defect
described in section 7, not a product defect.

**Reference studied:** Wondershare Filmora's user guide (panel layout, timeline and
track management, magnetic timeline, auto-ripple, split/trim, speed points, markers,
selection tools, compound clips, keyboard shortcuts). Filmora is a general-purpose NLE;
YamVideo is a screen-recording tool. This plan deliberately borrows Filmora's
*navigation and selection* model and rejects most of its *structural* model. The
reasoning is in section 5.

## 1. What Filmora does

### 1.1 Panel layout

Four panels, resizable by dragging their borders, with six preset arrangements
(Default, Organize, Edit, Short Video, Classic, Dual):

- **Media panel** — imported files, plus stock media, titles, transitions, effects,
  stickers and templates.
- **Player panel** — preview. Mark-in and mark-out happen *here*, on a clip in the
  media library, before it ever reaches the timeline. Also holds snapshot and playback
  quality.
- **Property panel** — the *selected clip's* video, audio, colour and speed properties.
  Added in Filmora 12 and described in the guide as the headline layout change.
- **Timeline panel** — full width along the bottom, with its own toolbar above it.

The division that matters: the right-hand panel is a **selection inspector**, not
project settings. Export is a terminal action, not a persistent panel.

### 1.2 Timeline and tracks

- Unlimited video and audio tracks. Video and audio always occupy separate tracks.
- Per-track **eye** (hide), **speaker** (mute) and **lock** controls in a track header
  on the left, plus an adjustable track height.
- **Magnetic timeline** — a toggle that closes gaps as clips are moved.
- **Auto-ripple** — a separate toggle that ripples subsequent clips during edits.
  Manual equivalents: click the `X` badge on a gap, right-click → Ripple Delete, or
  `Shift+Del`.
- **Split** rides on the playhead as a button drawn on the playhead itself. With no
  track selected it splits every track under the playhead; with one selected it splits
  only that track. A separate "Quick Split Mode" turns clicks into cuts.
- **Speed points** — right-click → Speed → Add Speed Point subdivides a clip into
  segments, each with its own speed, set from presets or a typed value. **Freeze frame**
  inserts a still segment defaulting to 5 seconds. "Clear Clip Speed" collapses back to
  a single 1× segment.
- **Markers** in two kinds. *Media markers* are attached to a source clip and only
  become visible once it is on the timeline. *Timeline markers* belong to the project.
  Eight colours (`Alt+1`…`Alt+8`), navigation by `Shift+Up` / `Shift+Down`, and
  select-all-clips-sharing-a-colour.
- **Zoom** four ways: `Ctrl+=` / `Ctrl+-`, **zoom-to-fit `Shift+Z`**, dragging
  horizontally on the time ruler (the cursor becomes a two-way arrow), and a slider.
- **Selection**: select mode `V`, range selection `X` (cancel `Shift+X`), and
  **select-all-forward** / **select-all-backward** from the playhead across all tracks.
- **Compound clips** — a selection collapsed into one block that opens as a nested
  timeline in its own tab, with a dual-timeline view and per-timeline export.
- Enable/disable clip (per-clip eye, distinct from per-track), group editing, and
  copy/paste of *effects* separately from clips.

### 1.3 Shortcuts worth noting

| Action | Filmora |
|---|---|
| Split | `Ctrl+B` |
| Ripple delete | `Shift+Del` |
| Trim start / end to playhead | `Alt+[` / `Alt+]` |
| Zoom in / out / fit | `Ctrl+=` / `Ctrl+-` / `Shift+Z` |
| Add marker / edit marker | `M` / `Shift+M` |
| Previous / next marker | `Shift+Up` / `Shift+Down` |
| Selected clip start / end | `Shift+Home` / `Shift+End` |
| Select previous / next clip | `Ctrl+Left` / `Ctrl+Right` |
| Freeze frame | `Alt+F` |
| Add keyframe | `Alt+Left Click` |

## 2. Where YamVideo already matches

Several Filmora features already exist here under different names, and must not be
rebuilt:

- **Speed points** are `TimelineSegment.speed` plus `ClipTimeline.split`. Splitting a
  section and setting its speed is the same operation Filmora reaches via speed points.
  `Timeline.swift` already rounds cumulative frame boundaries so repeated fractional
  speed edits do not accumulate drift.
- **Magnetic timeline / auto-ripple** are structurally unnecessary. Sections are
  exported through `concat`, so the timeline cannot contain a gap. There is nothing to
  ripple. This is a genuine advantage of the model and should be preserved, not traded
  away for free positioning.
- **Trim to playhead** exists as `AppModel.trimToPlayhead(start:)`, bound to `⇧⌘[` and
  `⇧⌘]` in the Timeline menu.
- **Split at playhead** exists (`⌘B`), matching Filmora's `Ctrl+B`.
- **Enable/disable clip** exists as `VideoItem.includedInMovie`, scoped to movie
  assembly.
- **Frame stepping** exists (`stepFrame`), with an accessibility adjustable action on
  the ruler.

## 3. Defects and gaps found in the current timeline

Read from `Sources/TimelineView.swift` at the baseline above.

1. **The ruler does not densify when zoomed.** `ruler(width:)` draws exactly nine ticks
   with `ForEach(0...8)`, positioned at `width * tick / 8`, where `width` is already
   multiplied by `scale`. At 8× magnification the same nine labels are spread eight
   times further apart, so most of the visible timeline carries no time reference. Tick
   count must derive from pixels-per-second, not from a constant.
2. **Zoom is slider-only and anchored at x=0.** There is no zoom-to-fit, no keyboard
   zoom, and no scroll-wheel zoom. Because the `ScrollView` offset is not adjusted,
   zooming moves the playhead off screen.
3. **No snapping.** Section drags, trims and zoom-shot edits are free-floating. There is
   no attraction to section boundaries, the playhead, clip start/end, or zoom shots.
4. **The playhead height is hardcoded** — `height: overview == nil ? 104 : 137`, with
   the container at `108`/`141` and the outer frame at `120`/`153`. Five magic numbers
   encode the same layout. Any new lane requires editing all of them.
5. **No markers of any kind.**
6. **Selection is single-section only.** `selectedSegmentID` is one optional `UUID`.
   There is no range selection, no select-forward/backward, and no keyboard traversal
   between sections.
7. **No lane headers.** The waveform and zoom lanes cannot be hidden, muted or locked,
   and their heights are fixed.

## 4. Approved scope — timeline navigation

This phase changes navigation, selection and the ruler. It does not change the edit
model, the export graph, or the project file format, except where noted for markers.

### 4.1 Adaptive ruler

Choose a tick interval from pixels-per-second so that labelled ticks stay between
roughly 80 and 200 points apart, selecting from a fixed ladder of human intervals:

    0.04s (1 frame at 25fps), 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600s

Draw minor ticks unlabelled at one fifth of the chosen interval when they exceed 6
points of separation. Label format follows the interval: below one second show
`m:ss.ff`, otherwise `m:ss`. `timelineTime` in `Timeline.swift` is the existing
formatter and should gain a frames variant rather than being duplicated.

Ticks are generated from the visible scroll range, not the whole timeline, so a long
recording at high magnification does not build thousands of views.

**Implemented 2026-09-06, with two deferrals to 4.2.** At the current `1...8` ceiling
the 80-point minimum bounds the tick count on its own — a 60-minute recording at 8×
draws 61 labels and 301 minor ticks — so ticks are currently generated across the whole
width and culling was not needed. Both deferrals bite only when the ceiling rises:

- **Culling.** At 60× a 60-minute recording wants 361 labels and 1,801 minor ticks.
  Visible-range generation must land with the zoom work, which needs the scroll offset
  tracked anyway to anchor zooming. On macOS 14 that means a `GeometryReader` in a named
  coordinate space; `onScrollGeometryChange` is macOS 15.
- **The ladder's bottom rung is not frame-aware.** `0.04` is one frame at 25fps. On a
  30fps clip it is 1.2 frames, so labels round to frames 1, 2, 4 — skipping 3. Reachable
  only above 2000 px/s, which `1...8` cannot produce. When the ceiling rises, the rungs
  below one second should derive from the clip: `1/fps`, `2/fps`, `5/fps`.

### 4.2 Zoom

- **Zoom to fit** — `⇧Z`, sets `scale` to 1 and scrolls to 0.
- **Zoom in / out** — `⌘=` and `⌘-`, one ladder step per press.
- **Scroll-wheel and pinch zoom** over the timeline body.
- Raise the range from `1...8` to `1...60` on a geometric ladder so a 30-minute
  recording can be cut to the frame. The slider maps to `log(scale)`, not `scale`.
- **All four paths keep a fixed anchor.** The anchor is the playhead when it is
  visible, otherwise the pointer, otherwise the viewport centre. This requires driving
  the horizontal offset explicitly — a `ScrollViewReader`, or replacing the `ScrollView`
  with a manually offset content view. The current implementation cannot express it.

**Implemented 2026-09-06.** The `ScrollView` is gone. `TimelineViewport` holds the slice
on screen (`start`, `visible`, `total`) and every lane draws exactly that slice across
the width it is given, so there is no scroll offset to chase after a zoom and off-screen
footage is never built. The viewport lives on `AppModel` so the menu commands reach it.
Trackpad scroll and pinch arrive through a small `NSViewRepresentable` that installs a
local event monitor and never takes part in hit testing; SwiftUI on macOS 14 surfaces
neither event. This also settled both 4.1 deferrals: culling is inherent, and the ruler
ladder is now frame-derived below half a second.

**A layout trap worth knowing before adding a lane.** A lane positions its contents with
`.offset()`, but sizes them with `.frame(width:)` — and once zoomed in, a section is far
wider than the viewport. SwiftUI sizes a `ZStack` to its widest child, so that one wide
child sized the whole lane stack, and the outer `.frame(width:)` then *centred* it: with
a 25-second clip the ruler measured 14,250,000 points wide and its ticks were positioned
around x = −7,000,000. The flexible background still filled the visible width, so the
lane looked present but empty, and only above 1× — at 1× the widest child is exactly the
view width, so nothing overflows and it renders correctly. Every lane is therefore pinned
with `.frame(width: width, alignment: .leading)` and clipped. Any new lane must do the
same. This is a rendering fault the headless suite cannot see; it was found by
screenshotting the running app.

### 4.3 Snapping

A single `snap(_ time: Double, excluding: UUID?) -> Double` helper, applied to section
drags, section trims, zoom-shot moves and resizes, and playhead scrubbing.

Candidates, in priority order when several are within range: the playhead, section
boundaries, zoom-shot edges, markers, and 0 / total duration.

The threshold is a **fixed 8 points in screen space**, converted to seconds through
pixels-per-second, so snapping weakens as you zoom in and disappears at frame level.
Hold `⌥` to suspend snapping for the duration of a gesture. A snapped edge draws a
1-point accent guide for as long as it holds.

### 4.4 Markers

A new `Marker { id: UUID, time: Double, label: String, colour: MarkerColour }` stored on
`VideoItem` and persisted in `ProjectClip`. Times are in **edited-timeline space**, and
must be remapped by the same mechanism `ClipTimeline.remap` already uses for zoom shots
whenever sections are split, trimmed, reordered, deleted or retimed.

- `M` adds a marker at the playhead. `⇧M` renames the selected one.
- `⇧↑` / `⇧↓` jump to the previous and next marker.
- Markers draw as narrow flags in the ruler, not as a separate lane.
- Six colours are enough; Filmora's eight is inventory, not utility.

**This changes the project format.** Bump `VideoProject.version` and add the usual
round-trip and rejection checks alongside the existing speed-edit version-2 tests.

### 4.5 Selection

Widen `selectedSegmentID: UUID?` to an ordered `Set<UUID>` behind a computed
single-selection accessor so existing call sites keep working.

- Click selects one section. `⇧`-click extends the range. `⌘`-click toggles one.
- `⌘←` / `⌘→` select the previous and next section.
- `⇧Home` / `⇧End` move the playhead to the selected section's start and end.
- `⌘A` selects every section in the clip.
- Delete acts on the whole selection as one undo step.
- Speed applies to every selected section as one undo step.

### 4.6 Layout arithmetic

Replace the five hardcoded heights with a single lane description — an array of
`(kind, height)` computed once — so the playhead, container and outer frame all derive
from the same value and a new lane is one line. This is a prerequisite for 4.1 and 4.4,
not optional cleanup.

### 4.7 Proposed shortcut assignments

Chosen to avoid the existing bindings in `App.swift` (`⌘N`, `⇧⌘O`, `⌘S`, `⇧⌘S`, `⌘Z`,
`⇧⌘Z`, `⌘B`, `⇧⌘[`, `⇧⌘]`, `⌦`, `⌘O`, `⌘R`, `⌘.`, `⇧⌘0`) and to follow Mac convention
rather than Filmora's Windows `Alt`-heavy scheme:

| Action | Proposed |
|---|---|
| Zoom in / out | `⌘=` / `⌘-` |
| Zoom to fit | `⇧Z` |
| Add marker | `M` |
| Rename marker | `⇧M` |
| Previous / next marker | `⇧↑` / `⇧↓` |
| Select previous / next section | `⌘←` / `⌘→` |
| Selected section start / end | `⇧Home` / `⇧End` |
| Select all sections | `⌘A` |
| Suspend snapping | hold `⌥` |

### 4.8 Test coverage

Every item below is a headless check in `Tests/main.swift`, following the existing
style — no UI harness:

- Tick interval selection returns a ladder value for a representative span of
  pixels-per-second, and labelled ticks never fall closer than the minimum.
- Zoom anchoring: for a given anchor time, scale change and viewport width, the
  computed offset keeps that time at the same screen x.
- Snapping: a time just inside the threshold snaps to the nearest candidate; just
  outside it does not; `⌥` suspends it; the threshold in seconds shrinks as
  pixels-per-second rises.
- Markers survive a project round trip, are rejected when out of range or malformed,
  and are remapped correctly across split, trim, reorder, delete and speed change —
  mirroring the existing zoom-shot remap checks.
- Marker navigation from an arbitrary playhead finds the correct neighbour, and stops
  at the ends rather than wrapping.
- Range selection over a reordered timeline selects by timeline order, not insertion
  order.
- Multi-section delete and multi-section speed change are each a single undo step.

## 5. Rejected for this phase, with reasons

- **Multi-track video.** The export path builds one `concat` chain per clip. Layered
  tracks require compositing, a canvas model, per-track transforms and z-order — a
  rewrite of `editedFilterGraph`, not an addition to it. Worth doing when there is a
  concrete need (webcam picture-in-picture is the likely one); not worth doing to
  resemble an NLE.
- **Magnetic timeline and auto-ripple toggles.** Meaningless in a gapless model. See
  section 2.
- **Compound clips.** The Movie workspace already fills the composition role. Nesting
  is a solution to track-count sprawl, which does not exist here.
- **Transitions at cuts.** Genuinely useful and a likely next phase, but it is an
  export-graph change (`xfade`/`acrossfade` between sections), not navigation, and it
  interacts with the frame-accurate boundary rounding already in `Timeline.swift`.
- **Keyframes and the graph editor.** Zoom shots already have eased push-ins. General
  keyframing is a much larger surface with no current demand.

## 6. Held for review — layout

Filmora's clearest structural lesson is the **property panel**: the right-hand pane
inspects the *selection*, and project-level export settings are separate. YamVideo
currently gives the right pane entirely to `SettingsPane` (export settings) and squeezes
section properties into a 24-point control strip below the timeline
(`TimelineView.sectionControls`), which cannot grow to hold marker, snapping or
multi-selection state.

Proposed for a later phase, not approved here: split the right pane into an **Inspector**
tab (selected section or zoom shot: in, out, speed, duration, marker, crop, blur) and a
**Export** tab (the current `SettingsPane`), with the tab following selection
automatically. This subsumes `sectionControls` and gives sections 4.4 and 4.5 somewhere
to put their controls. It should be decided before 4.4 lands, since marker editing needs
a home.

## 7. Prerequisite defect

Two HDR checks fail at the baseline: "an HLG source is detected as HDR" and "HLG is
named for the UI". This is a **test fixture defect, not a product defect**. The fixture
is encoded with `-color_trc arib-std-b67 -colorspace bt2020nc -color_primaries bt2020`;
ffmpeg 9.0.1's libx264 does not write those container-level flags into the stream, so
ffprobe reports no `color_transfer` and `MediaInfo.isHDR` is correctly `false`. The
fixture asserts nothing.

Verified fix — encode with x264 parameters instead:

    -c:v libx264 -pix_fmt yuv420p \
      -x264-params "transfer=arib-std-b67:colorprim=bt2020:colormatrix=bt2020nc"

Confirmed by ffprobe to produce `color_space=bt2020nc, color_transfer=arib-std-b67`.
The neighbouring PQ fixture needs the same treatment with `transfer=smpte2084`. Fix this
before starting section 4 so the suite is green and regressions are attributable.
