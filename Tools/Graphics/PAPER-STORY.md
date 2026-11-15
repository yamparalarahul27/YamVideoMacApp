# Mosaic + Paper Assets

A separate reusable graphic in YamVideo’s Mosaic gallery. Add it from Media, then
edit the title and each row’s image, label, detail and reveal time in the inspector.
Drag it onto another recording to use the same composition in a future video.

This is `namePlate` with `props.variant: "paperStory"`. It deliberately bypasses
the existing Paper/notebook card look. The actual image retains its colours and
silhouette; an SVG alpha dilation creates a warm white die-cut edge. The asset
lands with a slight tilt, the text builds in Mosaic tiles, and a curved ink arrow
draws between the label and its meaning. There is no overall paper surface.

```json
{"kind":"namePlate","start":0,"end":8,"props":{
  "variant":"paperStory","title":"Two tools, different roles",
  "x":40,"y":105,"width":650,
  "rows":[
    {"image":"/absolute/path/Codex.png","label":"Codex","detail":"Iteration","at":0,"rotation":-5},
    {"image":"/absolute/path/Claude.png","label":"Claude","detail":"Building","at":3,"rotation":4}
  ]
}}
```

Use transparent PNG assets for a contour cut-out. Opaque images keep their image
boundary. Omit `image` for text-only connections. Up to three rows are supported.
At 1920×1080 the default visible area is x40–690, y105–535. All row times are
seconds after the graphic starts. `ink`, `fontSize` and `headingSize` are optional.

## Free diagram layout

Use `nodes` instead of `rows` for a flow, a grid, a hub-and-spoke diagram or a
wireframe. Each node has `x`, `y`, `width`, `label`, optional `detail`, `image`,
`imageSize`, `fontSize`, `detailSize`, `rotation`, and `at`. Coordinates are local
to the graphic. An image sits above its Mosaic label. `links` is an array of
`{d, at, duration?, color?, strokeWidth?}`; `d` is an SVG path in a 650×480 local
canvas. Ink paths animate their length, independent of word and image timings.
Keep the default content within 650×480 and avoid the speaker's frame.

The Stack & Workflow video contains examples of role rows, branching mobile
platforms, a four-part prompt grid, a split-screen wireframe, and design handoff.

`contentScale` scales the complete composition (text, assets and ink together) from its local top-left; default 1. Set 1.1 for a 10% increase and adjust x/y to retain clearance.
