# Graphics engine tools

`Resources/Graphics/` holds the graphics engine: one JavaScript file that builds motion
graphics from JSON data, one stylesheet, a pinned GSAP and the Inter font. The plan is
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
- `style.look` is `glass` (cards), `ink` (handwriting over a soft haze) or `mix` (panel
  graphics in ink, the rest as cards). One graphic can override it with its own `look`.
- `style.edge` is the soft edge of the shade next to the speaker, in pixels (default 170).

The kinds and their props are in section 3 of the plan.
