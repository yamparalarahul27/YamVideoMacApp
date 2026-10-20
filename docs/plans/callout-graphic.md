# Callout graphic — plan (2026-10-20)

Status: plan only. No code until the owner approves it.

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
| `tone` | string | `dark` (default): near-black pill, white text, accent outline. `accent`: accent pill, near-black text. |

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

Timing: from 1.5 s to 10 s. The dot pops at 0, the line draws from 0.1 s, the label
pops at 0.3 s. Everything fades over the last 0.3 s. No beat props in v1.

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

1. **Beside the screen.** Only when the screen leaves a band of free space at its side
   (Side by side with a phone recording): the label's near edge is 32 px from the
   screen's edge, at the height of the point.
2. **Next to the point, across.** The label's near edge is 140 px from the point, on the
   side toward the middle of the clear area. Then the other side.
3. **Next to the point, up and down.** The label's near edge is 110 px above the point,
   then below.

The app uses the first place where the label stays in the clear area and out of the
speaker box at every moment that the callout shows. If no place is good, the app uses the
place with the smallest overlap. A `side` other than `auto` sets the side.

At each moment, the app moves the label as little as necessary to keep it inside the
clear area (as `LogoSpot.kept`). The line always goes from the dot to the label.

**Two lines.** A label that does not fit on one line breaks at the space nearest the
middle. The app gives the lines to the engine, so the two always agree. Example: Side by
side with a phone recording leaves about 300 px of clear area beside the phone. "Custom
keypad" is about 500 px on one line, so it goes on two lines (about 260 px).

**Label size.** The app uses an estimate: 0.6 em for each character, the same rule as
the logo badge labels. The engine draws the real text and puts the label's near edge on
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

- Text: Inter Bold, **56 px** on the 16:9 canvas. At 640 px wide that is about 19 px,
  larger than the logo labels (46 px). In a Short, also 56 px on the 1080 px canvas
  (about 33 px at 640 px wide).
- Pill: 16 px top and bottom, 28 px at the sides, round ends, a soft shadow.
- Dot: 12 px across, accent fill, a 3 px near-black ring, and one pulse ring at the start.
- Line: 4 px accent over a 8 px near-black line, so it shows on light and dark UIs.
- The style's `size` does not change a callout. It has its own size, as logo badges do.

Before the PR, I look at frames at 640 px wide: Screen with a web page (Tradl), Side by
side with a phone recording (Sahi), and a Short. The PR includes these frames.

## 6. Rules (`GraphicsTrack.problem` and the clip check)

- `text`: 1–4 words, 1–28 characters, one line.
- `point`: needs `x` and `y`. A callout needs a screen recording (`setScreen` first),
  and the point must be inside the screen's crop. The clip check does this, because the
  track alone does not know the screen.
- `side` and `tone`: one of the values.
- Length: 1.5–10 s.
- It shows alone: no other graphic may show with it. Two callouts may not overlap. A panel
  must slide away first.
- It cannot move on the picture (`transform` refused): `side` takes that job.
- Through cuts: the callout stays on the frame where it starts, as all graphics do.
- A callout that does not show at all (for example, all of its time is in the Speaker
  layout) is allowed. `state` marks it `hidden: true`, and the inspector says so.

## 7. In the app

- **Inspector, Graphics:** a **Callout** button adds a 3 s callout at the playhead, at
  the middle of the screen. The callout section has Text, Side, Tone, and **Aim**: the
  next click on the screen in the Preview sets the point (the same path as **Aim** for
  screen zooms, `aimScreenZoom`).
- **Preview:** the selected callout shows its point as a small target, also outside its
  time.
- **Timeline:** callout blocks go in the graphics lane, with the callout's text.
- **Short viewer:** Hide and show work as for other graphics.

## 8. Agents

`addGraphic` / `updateGraphic` with `kind: "callout"`:

```json
{"type": "addGraphic", "clipID": "CLIP-ID", "graphic": {"kind": "callout", "start": 51.4, "end": 54.4,
  "props": {"text": "Empty state", "point": {"x": 960, "y": 540}}}}
```

- `AgentCatalog`: the kind, its props and rules in the graphic field's text.
- `state.clips[].graphics.items[]`: a callout also shows `hidden` when it never shows.
- `preview --composed` draws it, so an agent can check the place.
- Agents Manual 4.5: a short "Callouts" item: find the point in the screen recording's
  pixels (`preview` of the screen at that time), 1–4 words, 2–4 s, and check a frame
  at 640 px wide.
- `Tools/Graphics/README.md` and `docs/plans/graphics-track.md` section 3: the new kind.

## 9. Tests (`./test.sh callouts`)

New file `Tests/ChecksCallouts.swift`, a new feature in `test.sh`:

1. Rules: text, words, point, side, tone, length; alone; no transform; no screen.
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

## 11. Questions for the owner

1. **Label look:** dark pill with white text (default in this plan), or the accent
   (yellow) pill with dark text?
2. **One at a time:** is "a callout shows alone" good for v1?
3. **When a zoom moves the element:** the label moves with the dot (this plan), or the
   label stays still and only the line moves?
