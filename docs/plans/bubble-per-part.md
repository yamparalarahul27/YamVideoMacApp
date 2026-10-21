# A bubble for each layout part — plan

**Date:** 2026-10-21. **Status:** built (the owner said yes to this plan on 2026-10-21). Section 9 has the
notes from the build.

## 1. Goal

In the Screen layout the speaker shows in a bubble. Today the bubble (corner, size, shape,
corners) is one setting for the whole video. The owner asked on 21 Oct 2026 (Tradl edit):
"can't I have different positions for different sections of the video?"

After this change, a Screen part on the Layout lane can have its own bubble. Example: the
bubble is at the bottom right for most of the video, and at the top left for the 40 s
where the screen shows a menu at the bottom right.

## 2. Decisions

1. **An optional bubble on a layout part.** `LayoutSpan.bubble` is nil (the part uses the
   base bubble, `ScreenTrack.bubble`) or a `SpanBubble` with four optional keys: `corner`,
   `size`, `shape` and `corners`. A key that the part does not set follows the base
   bubble. Thus a change to the base size still reaches a part that sets only its corner.
2. **The face stays one setting.** The face is a point in the speaker's recording, not a
   choice of the part. Find Speaker keeps one face for the video.
3. **Only the Screen layout uses it.** A part in Speaker, Side by side or Ink keeps its
   bubble but does not show it. Thus a switch from Screen to Speaker and back keeps the
   part's bubble.
4. **The bubble moves as a layout changes.** Where two touching Screen parts (or a part
   and the base) have different bubbles, the bubble eases from one place to the other over
   0.4 s from the change, with the same smoothstep. Its corners and size ease too. The
   window on the face does not change, so the face does not jump. A diagonal move crosses
   the screen in 0.4 s; the frames in section 6 show it.
5. **Preview and export stay one geometry.** `ScreenTrack.state(at:)` gives the bubble's
   place at each frame. `composeLayout` (preview) and `FFmpeg.layoutStage` (export) draw
   that place already, so they agree to the frame. Each frame of a bubble move gets its own
   ffmpeg chain, as each frame of a layout change does now (about 12 chains for each move).
6. **What follows the bubble without more work.** Logo badges read `state(at:)`, so they
   sit beside the part's bubble. The brand finder does not put a badge across a bubble
   move, because a bubble move counts as a change. Shorts do not change: a Short with the
   screen stacks the speaker under the screen and has no bubble.

## 3. Data (project version 24)

```swift
struct SpanBubble: Codable, Equatable {
    var corner: SpeakerBubble.Corner?
    var size: Double?               // 0.15–0.5 of the frame height, as the base
    var shape: SpeakerBubble.Shape?
    var corners: Double?            // 0.05–0.45 of the side, as the base
}
struct LayoutSpan { …; var bubble: SpanBubble? }   // nil when the part sets no key
```

- `ScreenTrack.bubble(at:endScreen:)` gives the bubble that shows at a time: the part's
  keys over the base bubble.
- `ScreenTrack.changes(endScreen:)` also gives a change where the layout stays Screen and
  the bubble changes.
- `LayoutGeometry.held(_:bubble:)` and `speakerPlace(_:bubble:)` take the bubble to use.
- `ScreenTrack.problem` refuses a part's size or corners outside the base ranges.
- Cuts move the parts as now; a part keeps its bubble.
- `VideoProject.currentVersion` goes from 23 to 24. A file of version 23 or older with a
  part's bubble is refused. A file without one writes no new key.

## 4. The app

**Layout inspector** (a selected Screen part on the Layout lane). One short label for each
row; the help is in tooltips:

| Row | Control | Tooltip |
| --- | --- | --- |
| Bubble | menu: Base, Top left, Top right, Bottom left, Bottom right | Where the bubble sits in this part. Base uses the Screen section's corner. |
| Size | slider, %, and a ↺ button when the part has its own size | ↺: Use the base size again. |
| Shape | menu: Base, Circle, Rounded square | The bubble's shape in this part. |
| Corners | slider, %, ↺ (only for a rounded square) | How round the corners are in this part. |

The sliders start at the base value. A move of a slider sets the part's own value.

**Screen section.** The four bubble controls stay. Their tooltips say that they set the base
bubble, and that a Screen part can have its own.

**Layout lane.** A Screen block with its own corner shows a corner symbol
(`rectangle.inset.topleft.filled` and the other three) in place of the screen symbol. Its
tooltip and accessibility label name the corner.

## 5. Agents

| Command | Change |
| --- | --- |
| `addLayout`, `replaceLayouts` | the layout object takes `bubble`: `{corner?, size?, shape?, corners?}` |
| `updateLayout` | `bubble` keys merge into the part's bubble; a key set to null follows the base again; `bubble: null` removes the part's bubble |

- Unknown bubble keys, bad corner or shape names, and values out of range are refused, with
  the same messages as `updateScreen`.
- `state.clips[].screen.layouts[]` shows `bubble` (only the part's own keys; left out when
  there are none) and, for a Screen part, `bubbleBox`: the bubble's box in design pixels of
  the 1920×1080 frame.
- The catalog's layout keys and the Agents Manual (section 4.4, step 3) tell agents to move
  the bubble for one part when a part of the screen needs the corner. They tell agents to
  check each graphic against that part's `bubbleBox`.

## 6. Checks (`./test.sh screen`)

- Geometry: a part's corner moves the bubble; the keys it leaves out follow the base; a
  Speaker or Side by side part ignores its bubble; two touching Screen parts with
  different bubbles make one change, with the same bubble none; during the move the place
  is in whole pixels and the window keeps its aspect; the end screen still gives Speaker.
- Data: a round trip keeps the part's bubble; a version 23 file with one is refused; a file
  without one has no `bubble` key; sizes and corners out of range are refused; a cut keeps
  the bubble on the part that follows its footage.
- Agents: add, merge, null keys, `bubble: null`, unknown keys, and `state`.
- Logo badges: a badge in a part with its own corner sits beside that bubble.
- Parity: preview and export of a bottom-right base and a top-left part, at held frames of
  each and at three frames of the move, within 3/255.
- Frames for the owner: about 640 px wide, the two held places and the move, from
  `preview --composed` on test footage (no owner footage in the repository).

## 7. PR #78 (graphics clear of the bubble)

PR #78 is open. Its `bubbleBox` uses the base bubble for the whole video. When the second
of the two PRs merges, `bubbleBox` must use the bubble at the card's time
(`ScreenTrack.bubble(at:)`): the place of the bubble when the card is fully in. The
`overBubble` check must test each bubble place that shows with the card.

## 8. Not in this change

- A quick "move the bubble from here" action. Now: Add Layout, set it to Screen, pick a
  corner.
- A bubble at any point (not a corner), and a drag of the bubble on the Preview.
- A pop (shrink and grow) in place of the glide, if the frames show that the glide is too
  fast.

## 9. Notes from the build

- `ScreenTrack.state(at:)` now eases to a held state with the bubble of the change
  (`changes` gives it). `composeLayout` and `FFmpeg.layoutStage` did not change: they draw
  the places that `state(at:)` gives.
- Parity on test footage (`./test.sh screen`): whole frame 2.0, bubble 2.8 of 255, at
  held frames and during both moves.
- Frames from the Tradl project (read only, not in the repository): a move from the top
  right to the bottom right, and one from the top right to the bottom left. Each glides
  on the smoothstep curve. The face stays in the middle of the bubble during the move.
