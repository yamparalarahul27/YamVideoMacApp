# Graphics gallery, the Paper look and Pills (plan)

Status: part 1 is built (21 Oct 2026, PR #85). Part 2 is built (21 Oct 2026, branch `claude/paper-look-d7af28`). Parts 3 and 4
are not started.
Mock-up: [docs/prototypes/graphics-gallery.html](../prototypes/graphics-gallery.html) (open it from a local web server, so
the pictures and fonts load). Its Glass and Ink pictures are real renders of the graphics engine over a
neutral backdrop. The Paper look and Pills are drawn in the page as proposals.

## Why

The owner, 21 Oct 2026 (Tradl edit): "those are all styling of video cards … where I can see what we have
already created as style … is there any place like that or we need to create that?" They shared two
references and want both as options in the app:

1. A taped paper title card (scrapbook style): an off-white card with a strip of washi tape, an eyebrow in
   small caps, a heavy display serif title with an italic second line, and a tilted label sticker in a
   handwritten font.
2. Pill tags with icons: fully rounded flat-colour pills, a bold filled icon and one or two words, the text
   in a darker or lighter tone of the pill's colour.

## What the app has today

- Style.md (Go → Style…, ⌘3): the channel's rules as text. No pictures.
- Studio → left panel → Graphics: five kinds as a list (name plate, title card, kinetic text, section card,
  end screen), each with an icon and one line. No previews, and the other kinds (feature list, link card,
  checklist, rule, logo badge…) show only to agents.
- The recording's graphics style (look glass, ink or mix; accent; size) is in the inspector.

## The plan, in four parts

### Part 1: the gallery

- The Graphics tab shows every kind a person can add as a tile with a preview picture (16:9), grouped:
  Cards, Full screen, Panels, Tags. Each tile has a name and one short line; long help goes in a tooltip.
- A **Look** switch above the tiles: Glass, Ink, Paper. It changes the previews only. To use a look, the
  owner sets it for the recording (the inspector's style) or for one graphic.
- The previews use the recording's accent and size, and the frame at the playhead behind them (a neutral
  backdrop when there is no recording). The engine draws them offscreen (`GraphicsSnapshot`, a beat time per
  kind where the graphic is complete), cached by style, kind and look.
- Click a tile: the Preview shows that graphic large, over the frame, without a change to the project.
  **Add at playhead** adds it (one undo step). **Replace selected** gives a selected graphic that kind's look.
- Later (not part 1): a hover plays the graphic's motion in its tile.

**What part 1 has** (`Sources/GraphicsGallery.swift`, the Media panel's Graphics tab):

- Seven tiles in four groups: Cards (name plate, title card, feature list), Full screen (kinetic text,
  section card), Panels (checklist) and End (end screen). Feature list and checklist are new in the
  Media panel. Tags come with Pills (part 3).
- The Look switch has Glass and Ink. Ink changes the panel kinds only. Paper comes in part 2.
- The engine draws each tile at 1280×720 over a neutral backdrop, and the tile shows the part of the
  frame around the graphic, so a card reads at tile size. The pictures are kept in
  `Caches/YamVideo/Gallery`, by engine, sample, style and look.
- A click shows the sample on the Preview at the playhead, with a bar: Add (Return) or Done (Esc). The
  picture moves aside for a panel, as for a panel in the project. An end screen draft does not move it.
- **+** on a tile adds the kind at the playhead, in the look the gallery shows, as one undo step.

**Not as planned:** the tiles use the neutral backdrop, not the frame at the playhead (one picture per
kind and look, and the Preview shows the frame). **Replace selected** is not in part 1.

### Part 2: the Paper look

- A third value of `look` (style and per graphic): `paper`, for the card kinds: name plate, title card,
  section card and panel title.
- The card: off-white (#F7F2E7), soft shadow, a small tilt; a strip of tape in the accent's family; the
  eyebrow (`kicker`) in small caps with wide spacing; the title in a display serif, with `detail` as an
  italic second line; an optional `label` (new prop): a tilted sticker with a handwritten font.
- Motion: the card drops in and settles its tilt, then the tape, then the label pops.
- **Fonts must be bundled.** The export draws with HyperFrames in Chrome, which has no Mac system fonts
  (New York), so preview and export would differ. Proposal: Fraunces (SIL OFL, a variable display serif with
  italics) from Fontsource, the same source as the bundled Inter. The label can use the bundled Virgil, or
  Caveat Brush (SIL OFL). A download needs the owner's yes.

**What part 2 has** (the owner said yes to Fraunces on 21 Oct 2026):

- `look: "paper"` for the style and for one graphic, project version 26. The card kinds have it
  (`GraphicKind.hasPaper`: name plate, title card, section card, panel title); the other kinds stay
  glass. `GraphicsTrack.look(of:)` and `lookOf` in graphics.js pick the same look (a check runs both
  for every kind and look).
- The card (`PAPER` in graphics.js, `.yg-pp` in graphics.css): #F7F2E7, a soft shadow, a tilt of
  0.8–2° to the left (0.4–1° for the section card and the panel title) from the graphic's ID, and
  see-through tape in a lighter tone of the accent. The eyebrow is in small capitals (Inter 700,
  upper case, wide spacing; Fraunces has no small-caps feature) in a darker tone of the accent that
  reads on the paper (4.5:1 or more). The title is Fraunces Black, `detail` Fraunces Bold Italic.
  `label` (one line, 32 characters or fewer) is a tilted sticker in Virgil, in the accent, with ink
  or white on it. The section card puts its seek bar on the paper, in the eyebrow's colour.
- Motion: the card drops in and settles its tilt (0.85 s), the tape comes in at 0.45 s, the label
  pops at 0.8 s. The exit is the smooth one of PR #79 (a 0.5 s glide through a blur; covers lift
  out). The paper panel title uses that exit too, not the panel's short fade, so its last frame is
  clear.
- Fonts: `Fraunces-900-latin.woff2` and `Fraunces-700-italic-latin.woff2` from Fontsource 5.3.0,
  with `Fraunces-OFL.txt`. The preview (WebKit) and the export (HyperFrames' Chrome) draw the same
  card: a check renders it both ways and compares them.
- The gallery's Look switch has Paper; the name plate, title card and section card tiles draw in
  it, and the title card's sample shows a label. The inspector's style and the graphic's Look offer
  Paper, and a Paper card without a label shows a Label field.
- Agents: `look: "paper"` in addGraphic, updateGraphic and setGraphicsStyle, `label` in props; the
  catalog and the Agents Manual (4.5) say so.

**Not as planned:** the label uses the bundled Virgil, so Caveat Brush is not downloaded. A gallery
draft sits at the template's place, so in a Screen part with the bubble at the top right it can
cover the bubble, as in part 1 (PR #78 moves column cards in the project, not drafts).

### Part 3: Pills

- A new kind `pills` in the column (top right, as the feature list): props `pills`, one to six
  `{text, icon, colour, at}`. Each pill pops in at its `at`.
- Colours: a fixed palette of pairs (fill and text), taken from the reference: deep green, slate, orange,
  pink, coral, yellow, light blue, lime, lavender. Text stays readable on each (contrast 4.5:1 or more).
- Icons: a small set of filled icons drawn as inline SVG in `graphics.js` (check, bolt, heart, chart,
  leaf, box, star, clock, lock, user, sparkle, flag), or a subset of Lucide (ISC licence).
- Sound cue `pill.pop`, as the logo badge's pop. In a Short, pills sit in the column's Short place.

### Part 4: agents, Shorts and checks

- Catalog and Agents Manual (4.5): the `paper` look, the `label` prop and the `pills` kind.
- Project format bump for the `pills` kind (the Paper look took 26 in part 2).
- Checks: each kind's preview draws; paper and pills render the same in the preview and in a HyperFrames
  export (frame parity); pill colours pass contrast; a Short places them in the clear area.

## Open questions for the owner

1. Answered (21 Oct 2026): yes to Fraunces from Fontsource. The label uses the bundled Virgil.
2. Can wait: the gallery in the Graphics tab (recommended), or a separate Gallery sheet?
3. Can wait: the eyebrow, tape and label colours from the recording's accent (recommended), or fixed as in
   the reference (orange and yellow)?
4. Can wait: Pills in the column at the top right (recommended), or as a lower third?
