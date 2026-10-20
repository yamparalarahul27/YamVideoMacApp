# Callout graphic — plan (2026-10-20)

Status: approved by the owner on 2026-10-20 (one callout at a time; the label moves with
the dot). Built on branch `claude/hungry-kepler-07efb9`. The default look waits for the
owner's pick (section 5).

## 1. Goal

The Tradl, Sahi (S1–S4) and 915 by Groww plans review real app UIs from screen
recordings. They name the UI pattern next to the element: "Empty state", "Thumb zone",
"Custom keypad", "Market depth". Today the plans use `kineticText` with a dim background.
It hides the UI for 2–3 s. A column card covers the screen in Side by side.

A **callout** is a short label (1–4 words) with a thin line to a point on the screen
recording. The point is in screen-recording pixels, so the callout stays on the same UI
element when a screen zoom changes or a layout moves the screen. It must read on a phone
and it must not cover the speaker's face or bubble.

## 2. Data

A new `GraphicKind.callout` in a new zone, `GraphicZone.callout`. No project version
change: the covers PR (#45) added kinds the same way.

| Prop | Type | Rule |
|---|---|---|
| `text` | string | 1–4 words, 28 characters or fewer, one line. |
| `point` | {x, y} | Screen-recording pixels (the full file, as screen zoom targets), inside the screen's crop. |
| `side` | string | `auto` (default), `left`, `right`, `up` or `down`: where the label goes from the point. |

The look comes from the graphics look system, not from a prop: `ink` or `glass` for the
callout alone, else the style's look. The `mix` look writes callouts in ink, as the
panels (section 5).

The app writes `place` into the props when it draws (as `spot` for logo badges and
`progress` for section cards). The project never stores it, and an agent never sends it.

```
place: {
  side: "right",                  // the side the app chose
  lines: ["Custom", "keypad"],    // one or two lines
  path: [[t, ax, ay, lx, ly, o], …]
}
```

- `t`: seconds after the callout's start.
- `ax, ay`: the point on the canvas, in design pixels (1920×1080, or 1080×1920 in a Short).
- `lx, ly`: where the line meets the label (the middle of its near edge).
- `o`: 0–1, how much of the callout shows (see section 4).

Timing: from 1.5 s to 10 s. The dot pops at 0 and one ring pulses out, the line draws
from 0.1 s, the label comes in from 0.35 s (ink writes it from 0.45 s). Everything fades
over the last 0.3 s. No beat props in v1.

## 3. Where it sits

**Words.** The *speaker box* is the speaker's place in the layout at that time, made 24 px
larger on each side. The *clear area* is the title-safe area (96–1824 × 54–1026) on the
16:9 video, and YouTube's clear area (`ShortFormat.clearArea`) on a Short.

The label must stay in the clear area and out of the speaker box.

| Layout | Speaker box | Where the label goes |
|---|---|---|
| Speaker | — | The screen does not show, so the callout does not show. |
| Screen | The bubble | Over the screen, next to the point, on the side away from the bubble. |
| Side by side | The tall panel on the left | In the free space beside the screen when it has room (a phone recording); else over the screen, next to the point. |
| Ink | The speaker's part on the right | Next to the point, over the ink area. |
| Short, screen on top | The speaker, and the caption band above it | Over the screen, next to the point. |
| Short, no screen | — | The Short does not show the callout. |

**How the app chooses the side** (`side: auto`). The app tries these places in order:

1. **Beside the screen**, on one line, then on two. Only when the screen leaves a band
   of free space at its side (Side by side with a phone recording): the label's near
   edge is 32 px from the screen's edge, at the height of the point.
2. **Next to the point, on one line.** Across first: the label's near edge is 140 px
   from the point, on the side toward the middle of the clear area, then the other
   side. Then up and down: 110 px above the point, then below.
3. **Next to the point, on two lines**, in the same order.

The app uses the first place where the label stays in the clear area and out of the
speaker box at every moment that the callout shows. If no place is good, the app uses the
place with the smallest overlap. A `side` other than `auto` sets the side.

At each moment, the app moves the label as little as necessary to keep it inside the
clear area (as `LogoSpot.kept`). The line always goes from the dot to the label.

**Two lines.** A label that does not fit on one line breaks at the space nearest the
middle. The app gives the lines to the engine, so the two always agree. Example: Side by
side with a phone recording leaves about 300 px of clear area beside the phone. "Custom
keypad" is about 500 px on one line, so it goes on two lines (about 260 px).

**Label size.** The app uses an estimate: 0.6 em for each character (Inter and Virgil
alike), the same rule as the logo badge labels. The engine draws the real text and puts the label's near edge on
`lx, ly`, so a small error changes only the far edge.

## 4. How it follows the screen

The app samples the callout at each frame of its time. For each sample it uses the same
sums as the preview and the export:

1. `ScreenTrack.state(at:geometry:endScreen:)`: the screen's place now, also while a
   layout change eases.
2. `ScreenTrack.zoomWindow(at:)`: the part of the screen recording that shows now.
3. The point on the frame: `place.minX + (point.x − picture.minX − window.minX) /
   window.width × place.width`, and the same down. This is the inverse of
   `ScreenTrack.screenPoint`, which aims screen zooms.

The callout shows (`o` = 1) when all of these are true:

- The layout shows the screen.
- The point is inside the zoom window.
- The speaker's picture is not on top of the point. (In Ink the lines are on top of the
  speaker, so this does not apply there.)

The layout the picture is in, or moving to, decides the first and the last item, and the
speaker box. So a layout change fades the callout once, and the speaker's picture that
sweeps past during the change does not make it flicker.

When one of these changes, `o` goes to 0 or back to 1 over 0.25 s, so the callout fades
and does not jump.

The app then removes each sample that a straight line between its two neighbours gives
to within 0.5 px and 0.01 of `o`. A callout with no zoom and no layout change keeps only
two samples. The engine moves between samples in a straight line.

A screen zoom that starts or ends during a callout moves the dot with the UI element.
The label moves with the dot, on the same side.

**Not with panels.** A panel moves the whole picture aside. A callout may not show while
a panel shows, or in the 0.8 s while it slides away (the cover rule).

## 5. Look, and the phone

The owner asked for a look that matches the video and its theme, not a plain dark pill.
Two looks are built, and the owner picks the one that `mix` uses. The owner saw both
on 20 Oct in frames at 640 px wide from the Tradl and Sahi footage (not in the repo:
they show unreleased footage):

- **A, ink:** the label in white Virgil, 60 px, written left to right on a soft dark
  haze; a white hand-drawn line with a dark edge.
- **B, glass:** the label as a tag in the accent colour with near-black Inter Bold, 54
  px, as the thumbnails' highlighted words; a straight accent line with a dark edge.

Both:

- Dot: 18 px across, accent fill, a near-black ring, and one ring that pulses out at
  the start.
- The line and the dot have a dark edge, so they show on light and dark UIs.
- No backdrop blur: the export draws graphics on a clear background, so a blur of the
  picture under the label would show in the Preview only. The haze is a plain
  see-through shade with a soft edge.
- At 640 px wide the label is about 18–20 px high, larger than the logo labels (46 px
  at full size).
- The style's `size` does not change a callout. It has its own size, as logo badges do.

## 6. Rules (`GraphicsTrack.problem` and the clip check)

- `text`: 1–4 words, 1–28 characters, one line.
- `point`: needs `x` and `y`. A callout needs a screen recording (`setScreen` first),
  and the point must be inside the screen's crop. The clip check does this, because the
  track alone does not know the screen.
- `side`: one of the values.
- Length: 1.5–10 s.
- It shows alone: no other graphic may show with it. Two callouts may not overlap. A panel
  must slide away first.
- It cannot move on the picture (`transform` refused): `side` takes that job.
- Through cuts: the callout stays on the frame where it starts, as all graphics do.
- A callout that does not show at all (for example, all of its time is in the Speaker
  layout) is allowed. `state` marks it `hidden: true`, and the inspector says so.

## 7. In the app

- **Media, Graphics:** a **Callout** entry (when the recording has a screen) adds a 3 s
  callout at the playhead, at the middle of the screen, and starts Aim.
- **Inspector:** the callout section has **Aim** (the next click on the screen in the
  Preview sets the point, the same path as Aim for screen zooms) and **Side**. Text and
  point are in the fields below. "Not on the picture" shows when the point never shows.
- **Timeline:** callout blocks go in the graphics lane, in yellow, with the callout's
  text.
- **Short viewer:** Hide and show work as for other graphics.

## 8. Agents

`addGraphic` / `updateGraphic` with `kind: "callout"`:

```json
{"type": "addGraphic", "clipID": "CLIP-ID", "graphic": {"kind": "callout", "start": 51.4, "end": 54.4,
  "props": {"text": "Empty state", "point": {"x": 960, "y": 540}}}}
```

- `AgentCatalog`: the kind, its props and rules in the graphic field's text.
- `state.clips[].screen.hiddenCallouts`: the callouts whose point never shows.
- `preview --composed` draws it, so an agent can check the place.
- Agents Manual 4.5: a short "Callouts" item: find the point in the screen recording's
  pixels (`preview` of the screen at that time), 1–4 words, 2–4 s, and check a frame
  at 640 px wide.
- `Tools/Graphics/README.md` and `docs/plans/graphics-track.md` section 3: the new kind.

## 9. Tests (`./test.sh callouts`)

New file `Tests/ChecksCallouts.swift`, a new feature in `test.sh`:

1. Rules: text, words, point, side, length; alone; no transform; no screen.
2. Inverse: for points on the screen, `screenPoint(framePoint(p)) == p` in Screen, Side
   by side and Ink, with and without a zoom.
3. A zoom: the dot moves with the zoom target, and the label keeps its side.
4. A layout change from Screen to Side by side: the dot moves with the screen.
5. `o`: 0 in Speaker, 0 when the zoom window does not include the point, and 0.25 s fades.
6. Place: bubble bottom right and a point near it, so the label goes left or up. Side by
   side with a portrait screen, so the label goes in the free space beside it. A Short
   with the screen on top, so the label stays in the clear area and out of the caption
   band.
7. Path: a still callout keeps two samples.
8. Engine (WKWebView, as the graphics checks): at a time, the drawn dot is on `ax, ay`,
   the label box does not touch the speaker box, and `bounds()` measures it.
9. Through cuts, and in a Short (shown with the screen on top, not shown without).

Then I run the related features: `./test.sh callouts graphics covers logos shorts screen
agents`. Before a full run, I check `ps -Ao pid,command | grep yamvideo-tests`.

## 10. Not in v1

- Two callouts at the same time.
- A label that the owner drags on the picture.
- Callouts on the speaker's own picture (no screen recording).
- An `analyze` kind that finds UI elements.

## 11. The owner's answers (2026-10-20)

1. **Label look:** not a plain dark pill; a look that matches the video. Two looks to
   pick from (section 5).
2. **One at a time:** yes.
3. **When a zoom moves the element:** the label moves with the dot.
