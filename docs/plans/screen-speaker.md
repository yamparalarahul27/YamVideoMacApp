# Screen + speaker — implementation plan

**Updated:** 2026-10-15. **Status:** part 1 (sections 3 to 9) and zooms on the screen
(section 12, the first item of part 2) are implemented on the `screen-speaker` branch. The
rest of part 2 (section 10) is not started.

## 1. Goal

The owner records two files for a walkthrough video:

- a headshot from the Pocket 3, with the only audio (the Lark mic), and
- a screen recording from macOS, with no audio.

The two files start at different times. The owner wants one edit: the headshot's cuts,
captions and graphics, with the screen next to the speaker or in place of the speaker.

Example: the YamDrive design system video of 2026-10-15. The headshot is 8:51, the screen
recording is 12:29, and screen time = headshot time + 142.5 s.

## 2. Decisions

1. **The speaker is the master.** The screen recording attaches to the headshot's
   recording as its *screen*. The headshot keeps its audio, transcript, sections, zooms,
   effects, graphics, Shorts and publish data. Every cut on the timeline cuts the screen
   at the same moment, because the screen follows the speaker's source time.
2. **One number syncs the two files:** `offset`, the screen time at speaker source time 0.
   Screen time = speaker source time + `offset`. File dates do not give it: on the example
   files the Pocket 3 clock was 14.5 s off, and its metadata time zone was 30 min off. The
   owner or an agent sets it. A frame of the screen outside its file holds the nearest
   frame (the first or the last).
3. **Three layouts.** *Speaker* (the speaker fills the frame), *Screen* (the screen fills
   the frame, the speaker in a round bubble in a corner) and *Side by side* (the speaker
   in a tall panel on the left, the screen on the right). A **base layout** applies
   everywhere. **Layout spans** (start, end, layout) in edited-recording seconds change it
   for a part of the video, like whole-frame blur effects. A change of layout eases over
   0.4 s from the start of the span or of the gap after it.
4. **The speaker is always on top.** In the Speaker layout it covers the screen, so a
   change to or from Speaker needs no fade: the speaker grows or shrinks, and the screen
   under it does not move. Between Screen and Side by side, both pictures move.
5. **No distortion.** A layout gives each picture a place on the frame (a rectangle with a
   corner radius) and a window into the picture. While a change eases, the window keeps the
   aspect of the place. The bubble's window is a square on the speaker's face. Apple Vision
   finds the face, as for Shorts.
6. **The frame size is the speaker's crop.** The screen fits inside it with a margin, over a
   blurred, darker copy of the screen (the fill of the move aside).
7. **Preview and export share one geometry.** `ScreenTrack.state(at:frame:)` gives the
   places for one time. The preview draws them with Core Image in a custom
   `AVVideoCompositing` compositor (two video tracks). The export draws them with ffmpeg:
   held runs share one chain, and each frame of a change has its own chain, as the end
   screen's move does. A recording without a screen keeps the existing paths unchanged.
8. **Order of stages.** Speaker: colour, blur areas, crop, zoom, whole-frame effects. Then
   the layout stage puts the screen and the speaker together. Then the graphics' move aside
   (and the end screen), the size limit, the graphics and the captions. So graphics and
   captions sit over the whole frame, not over the speaker only.
9. **The end screen wins.** From the end screen's start, the layout is Speaker, so the end
   screen moves the speaker (not the screen) into its frame.
10. **Agents get typed commands,** like every other edit: `setScreen`, `updateScreen`,
    `removeScreen`, `addLayout`, `updateLayout`, `removeLayout` and `replaceLayouts`.
    State shows the screen, its offset and the spans. `preview --composed` shows the
    layouts, because it uses the preview's player item.

## 3. Data (schema version 14)

```swift
struct ScreenTrack: Codable, Equatable {
    var url: URL                  // the screen recording, local
    var info: MediaInfo           // probed
    var offset: Double            // screen seconds at speaker source second 0
    var crop: CGRect?             // the part of the screen recording to show, nil = all
    var layout: ScreenLayout      // the base layout, default .screen
    var spans: [LayoutSpan]       // sorted, half-open, may touch, may not overlap
    var bubble: SpeakerBubble     // corner, size (fraction of the frame height), face
}
enum ScreenLayout: String { case speaker, screen, split }
struct LayoutSpan: Identifiable { var id; var start: Double; var end: Double; var layout: ScreenLayout }
```

`VideoItem.screen` and `ProjectClip.screen` (nil when there is no screen). A file of version
13 or older with a screen is refused. Cuts move the spans as they move blur effects: each
span follows the frame it starts on and keeps its length; a span whose footage is gone goes.

## 4. Geometry

In design pixels of a 1920×1080 frame, scaled to the real frame:

| Layout | Speaker | Screen |
| --- | --- | --- |
| Speaker | the whole frame, radius 0 | as in the layout it comes from or goes to |
| Screen | a circle, diameter 30 % of the frame height, 40 px from the corner | fitted inside the frame with a 48 px margin, radius 16 |
| Side by side | a panel 29 % of the width at the left, as tall as the screen, radius 16 | fitted in the rest, 40 px margin, 32 px gap, radius 16 |

The bubble's window is a square 60 % of the speaker picture's height, centred on the face.
A panel's window is as tall as possible, centred on the face. Places are whole pixels and
even sizes, so ffmpeg and Core Image put the same pixels in the same place.

## 5. Preview

- `PlaybackController.makeItem` adds a second video track when the recording has a screen.
  For each section, it inserts the screen's matching range (speaker range + `offset`),
  scaled for speed like the speaker. Parts outside the screen file hold its first or last
  frame.
- `ScreenCompositor` (an `AVVideoCompositing`) gets both frames. It draws the speaker
  with the existing `renderFrame` (colour, blur areas, crop, zoom, effects), puts the two
  together with `composeLayout`, then applies the move aside, as `renderFrame` does now.
- The agent's `preview --composed` and the thumbnail use the same item, so they follow.

## 6. Export

- The screen recording is one more ffmpeg input, after the palette and before the graphics.
- The screen stream: its timestamps moved by `offset`, made constant-rate on the speaker's
  frame grid (`fps=…:start_time=0:round=up`, so each output frame shows the screen frame
  current at that moment), the last frame held, converted to Rec.709, cropped and scaled
  once to its size in the Screen layout. Then the same trims as the speaker's sections, so
  both have the same frames.
- The layout stage reads `[lyin]` (the speaker after effects) and the screen stream. It cuts
  the video into runs by frame: one chain per held layout, one per frame of a change. Each
  chain: the fill from the screen, the screen scaled and masked with rounded corners, the
  speaker's window scaled and masked (circle or rounded corners), laid over in that order.
- With a screen the export is always tagged Rec.709, as with effects.

## 7. The app

- **Inspector, Screen section:** Add Screen Recording…, the file, the offset (with −1 s,
  −1 frame, +1 frame, +1 s), "Screen time at playhead" (type the screen recording's time
  that matches this moment and the offset follows), base layout, bubble corner and size,
  Find Speaker (Vision), and Remove Screen.
- **Timeline, Layout lane:** the spans as blocks; click to select, drag to move, drag an
  edge to trim. The inspector edits the selected span. Add Layout at Playhead adds a span
  of the other layout from the playhead, 5 s or to the next span.

## 8. Agent protocol

| Command | Fields |
| --- | --- |
| `setScreen` | clipID, path, offset? — attaches (or replaces) the screen recording; it is probed first |
| `updateScreen` | clipID, screen: {offset?, crop?, layout?, bubble: {corner?, size?, face?}} — face "speaker" asks Vision |
| `removeScreen` | clipID |
| `addLayout` | clipID, layout: {id?, start, end, layout} |
| `updateLayout` | clipID, layoutID, layout: {start?, end?, layout?} |
| `removeLayout` | clipID, layoutID |
| `replaceLayouts` | clipID, layouts: [{start, end, layout}] — every span at once, for a plan from the transcript |

`state.clips[].screen` shows the track, the screen's media, and `covers`: the edited times
where the screen file has footage.

## 9. Tests (`./test.sh`)

- Geometry: places in whole pixels inside the frame, the bubble a circle, no distortion
  while a change eases, the end screen forces Speaker.
- Reducer: add, update, remove, replace; overlap and range refusals; spans follow cuts; a
  version 13 file with a screen is refused; a round trip keeps the screen.
- Parity: two synthetic clips (different patterns and sizes). The preview and the export
  agree at held frames of each layout and during a change.
- Sync: a screen frame number burned in the screen clip lands on the expected speaker frame
  after cuts.
- Agents: the commands, refusals, state, and `preview --composed`.

## 10. Part 2 (later)

1. ~~Zooms on the screen, and Suggest Zooms on the screen recording.~~ Done: section 12.
2. Sync from sound when the screen recording has the microphone.
3. Movie and Shorts with the screen (a Short could show the screen above the speaker).
4. Layout suggestions from the transcript ("you can see my screen", "let's go one by one").
5. A ring or a shadow round the bubble.
6. A crop box for the screen on the picture (agents can set any crop now; the app has
   Crop Border only).

## 11. Notes from part 1

- The compositor reads and writes frames in Core Media's own 709 space
  (`ColorPipeline.videoSpace`). With the textbook 709 curve, preview and export differed
  by about 9/255 on saturated screen colours.
- Cuts: the screen rides under the speaker in one stacked frame through the section trims.
  Separate trims on the two streams round differently at a section's edge (the speaker's
  time base against the screen's frame grid) and drift a frame per cut.
- A long offset: the export seeks the screen recording with `-noaccurate_seek`, so the
  key frame before the seek point stays and the frame current at that moment is there.
  On the example (offset 142.5 s) a minute of footage exports in about 28 s.
- The layout stage's graph grows with each change (about 12 one-frame chains per change).
  A video with many dozens of changes could pass macOS's argument size limit; then the
  graph goes to a file (`-/filter_complex`).

## 12. Zooms on the screen

The screen's browser text is small at 1080p, so the screen has push-ins of its own.

- **Data.** `ScreenTrack.zooms: [ZoomShot]`: the same ease, hold and level as a recording's
  own zooms, in edited-recording seconds, with targets in the screen recording's pixels.
  They follow their footage through cuts (`removedZooms` reports the ones cut away). The
  file stays at schema version 14: an older file simply has none.
- **Geometry.** `ScreenTrack.zoomWindow(at:)` gives the part of the screen's picture shown,
  with the sums of `renderFrame` and `FFmpeg.zoomFilter`. `screenPoint(_:at:)` maps a point
  of the frame back to the screen recording, through the layout and the zoom.
- **Preview.** `composeLayout` cuts the window from the full-resolution screen picture, then
  places it as before; the fill behind the screen comes from the zoomed picture.
- **Export.** With zooms, the screen's stream keeps more of the recording's own detail: its
  place grown by the deepest zoom, never past the recording's pixels
  (`FFmpeg.streamSize`). A `zoompan` on the edited timeline, after the cuts, draws the zooms
  and scales to the place. `zoompan` works in 8 bits, so the stream goes back to 10 bits
  after it for the fill and the masks. Parity: held zooms within about 2/255, eases within
  about 4/255 (`zoompan` moves its window in whole pixels).
- **Suggest Zooms.** `ZoomAnalyzer.analyzeScreen` reads only the part of the screen
  recording the edit shows, finds local activity as for a recording, and times each
  suggestion at the edited moment its footage plays, at 2×. The review sheet is shared.
- **App.** Screen section: Add Zoom, Suggest, Clear. A Screen zooms lane. With a screen zoom
  selected, a click on the screen in the Preview aims it. With a screen, the Preview stays
  up after an edit, because only it shows the screen.
- **Agents.** `addScreenZoom`, `updateScreenZoom`, `removeScreenZoom`, `replaceScreenZooms`;
  `state.clips[].screen.zooms`; `analyze` with kind `screenZooms`.
