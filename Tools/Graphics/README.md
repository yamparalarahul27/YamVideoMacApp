# Graphics engine tools

`Resources/Graphics/` holds the graphics engine: one JavaScript file that builds motion
graphics from JSON data, one stylesheet, a pinned GSAP and the fonts (Inter, Virgil and
Fraunces; see THIRD-PARTY.md). The plan is
[docs/plans/graphics-track.md](../../docs/plans/graphics-track.md). In phase G0 the engine
runs outside the app; phase G1 puts it in the app's preview and export.

The app's export draws graphics itself (Sources/GraphicsRender.swift): each unit on its
own page, rendered by a pinned HyperFrames to a cached PNG sequence and overlaid by ffmpeg.
In `unit` mode the page options may give `origin`, the data time shown at page time 0; the
app puts it on a frame so beats land on the frames the preview shows.

`assemble.mjs` writes a HyperFrames page from a graphics JSON file. It needs Node 18 or
later and nothing else.

```sh
# List the render units: one per graphic, plus one per panel span
node Tools/Graphics/assemble.mjs --graphics graphics.json --units

# Graphics over a video, with the video move and the frosted panel (for a full render)
node Tools/Graphics/assemble.mjs --graphics graphics.json --out page --mode full --video cut.mp4 --fill cut-960.mp4
npx hyperframes render page --fps 30000/1001 --quality delivery -o final.mp4

# One graphic on a transparent page, with its own time from 0 (the export unit)
node Tools/Graphics/assemble.mjs --graphics graphics.json --out unit --mode unit --unit rule-1
```

`--fill` is optional: a small copy of the video for the blurred fill behind a moved video.
Without it the fill decodes the full video a second time.

Image paths in the JSON are relative to the JSON file. The tool copies each image into the
page folder under a content-hash name, so the page has no paths outside its folder.

## The JSON

```json
{
  "version": 1,
  "duration": 275.6,
  "fps": "30000/1001",
  "style": { "accent": "#F5C42C", "panel": "shade", "moveVideo": true },
  "items": [
    { "id": "name-plate", "kind": "namePlate", "start": 0.3, "end": 4.3,
      "props": { "kicker": "Yamparala Media", "title": "Yamparala Rahul", "detail": "UX Design Engineer" } }
  ]
}
```

- `start` and `end` are seconds on the edited recording.
- `at` values inside `props` are seconds after the graphic's `start`.
- `style.panel` is `shade` (see-through, frosted) or `solid`.
- `style.moveVideo` slides the video to the left half while a panel shows. In `full` mode a
  blurred copy of the video fills the space it leaves.
- `style.look` is `glass` (cards), `ink` (handwriting over a soft haze), `mix` (panel
  graphics in ink, the rest as cards) or `weekly` (warm light cards, a compact progress checklist and demo placeholders, using the recording's accent), or `paper` (name plates, title cards, section cards
  and panel titles on an off-white card with tape, in Fraunces; the rest as cards). One
  graphic can override it with its own `look`. A paper card takes an optional `label` prop:
  a tilted sticker in Virgil under the card.
- `style.edge` is the soft edge of the shade next to the speaker, in pixels (default 170).
- `YamGraphics.thumbnail(data)` draws a still YouTube thumbnail on the stage (page mode
  `thumbnail`); the app's thumbnail maker fills in the frame, the cut-out and the text.
- An item's optional `transform` `{x, y, scale}` moves it on the picture, in pixels, and
  scales it from the top-left corner of its zone. The app sets it when a graphic is dragged
  in Preview.
- `endScreen` takes the whole screen for YouTube's last 5–20 seconds: a frame round the
  speaker and empty boxes where YouTube's Subscribe circle and video cards sit
  (`YamGraphics.endLayout(props)` gives the places). In the app the speaker moves into the
  frame natively; in `full` mode `#bg-video` does, over `#bg-fill`.
- `logoBadge` shows brand logos next to the speaker when the brand is said: `props.logos`
  is one to three `{image, label, at}` (each logo pops in `at` seconds after the start),
  and `props.tone` is `light` (white chips, the default) or `dark`. The app writes
  `props.spot` `{x, y, alignX, alignY, compact, vertical, widths}` when it draws the
  badge: the point that the badge's `alignX` and `alignY` edges (`start`, `middle` or
  `end`) go to, next to the speaker in the layout at that moment (`LogoSpot` in
  Sources/Logos.swift). `compact` (in a Short) shows the logos without their labels.
  `vertical` puts the logos one above the other. `widths`, when a logo is wider than
  tall, gives each logo's width in pixels from the image's own size: a logo is 100 px
  tall (96 compact) and up to 3 times as wide. Without `widths` each logo is square.
  Without a spot, the badge sits at the top right.
- A column card (`namePlate`, `featureList`, `titleCard`, `phoneScreens`, `route`, `link`,
  `endCard`) can have `props.clear` `{x, y, w, h, side}`: the speaker's bubble in the
  Screen layout, in pixels. The app writes it (Sources/BubbleClear.swift) while the bubble
  shows with the card. When the card's drawn box meets that box, the engine moves the card
  below it (`side` `below`) or above it (`above`), 24 px from it (`clearMove`). When that
  leaves the title-safe area, the card moves beside the bubble, towards the middle. An
  item's own `transform` wins. `YamGraphics.bounds()` gives the move as `cx`, `cy`.

The kinds and their props are in section 3 of the plan.

## Weekly look

Set `style.look` to `weekly`. The Look menus and gallery keep it alongside Glass, Ink and Paper.
Column cards and section cards share warm cream surfaces, readable dark text and the video's
accent. Ink diagrams, logos and end screens keep their original templates. A graphic may
choose `look: "weekly"` on its own. Projects using Weekly require format 27 or later.

A title card with `props.variant: "weeklyProgress"` takes `title`, `completed`, `total`
and `items: [{text, state}]`, where `state` is `done`, `current` or `next`. In Weekly it
looks like a bound paper notepad: ruled lines, a red margin, layered paper edges and a
handwritten heading, while the rows keep clear sans-serif lettering. The saved
Weekly look applies the selected accent to the checks and current row. Use the graphic's
transform to place it beside the speaker. A title card with
`props.variant: "demoPlaceholder"` takes `title` and `detail` and fills the picture with
a clearly labelled stand-in for a later screen recording.

A progress card may set `fullPage: true` to show the current point as a full notebook
page. Set `pip: true` when paired with the native Screen layout: the graphics leave the
background transparent and clear space on the right for the live speaker. The Screen
track supplies the canvas, rounded speaker window and 0.4 s layout transitions.
`titleCard` variant `referenceCredit` takes `author`, `title`, `source`, `kicker` and an
`image` path to show a credited reference; it also supports `pip: true`.

Detail pages keep a fixed 620 px width and wrap their text. `pageTurn: true` turns the
page once from its top binding (0.62 s, after the camera starts shrinking). The GSAP
timeline owns the turn, so seeking and export show the same frame. Keep app interface
views on the native Screen track behind the notepad; use genuine footage or screenshots
for each app, and preserve the live speaker's clear corner.

Weekly detail cards can set `presentation: "notebookToScreen"` with `visuals: [{image, label, url, at, portrait?}]`. The fixed-width notebook introduces the topic, folds away at `screenAt` (default 2.1 seconds), and the real screen expands from the right into the main area. The middle-left native speaker stays clear. Later visuals enter at the expanded size. Optional `beats: [{text, at, end}]` put short spoken phrases below the screen. All times are seconds after the graphic starts; motion is on the shared deterministic timeline.

For a flat video backdrop behind Weekly cards, set the native screen track `fullBleed: true` through `updateScreen`. This removes its inset margin and rounded frame in both native playback and export; keep false for ordinary framed screen recordings.

### Mosaic templates

The native gallery offers Mosaic caption and Mosaic image alongside Ink, Paper and Weekly. Glass stays supported for reading old projects but is no longer a visible choice. `MediaAsset.mosaicCaption` and `.mosaicImage` share their defaults with `MosaicTemplates`, including drag insertion. A Mosaic caption uses the native namePlate kind with `variant: asideCaption`, `motion: mosaic`. A Mosaic image uses logoBadge with `variant: mosaicScreens`; each logos entry accepts image, x, y, width, height, imageHeight and label. Images reveal in 24 tiles and settle into one seamless image; labels use individually fitted ink-and-paper words. Named Mosaic variants dispatch independently of the underlying Paper look, preserving saved custom compositions.


### Mosaic screenshot entrances and thumbnail

A `logoBadge` with `variant: screenshotCorners` uses `logos` entries with `image`,
`x`, `y`, `width`, `height` and `imageHeight`. Four squares open from the centre along
curved paths while a clip mask reveals the image. `squareSize` defaults to 26;
`revealDuration` is adjustable up to 1.1 seconds; `settled: true` keeps an already
visible image from replaying its entrance after a cut. `cream` (legacy primary-colour
key) and `green` set the two corner colours; the Mosaic pair is `#d7ef63` / `#203329`.
Place over clean footage for the entire entrance, not over a previously baked image.

A native thumbnail design with `place: mosaic` uses the real video portrait, a dense
word field, cream/lime title tiles, the `tag` and an optional product `image`. It is
available in the thumbnail maker's Place menu and saved in the project like the other
layouts. The assembled-movie exporter renders recording graphics before fitting and
joining the clips, using the same local timing and graphics cache as recording export.
