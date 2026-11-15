# Mosaic text with drawn ink

Reusable native graphics template: `namePlate`, `props.variant: "inkStory"`.
Available in the preview and export renderer. No external images or panel background.

All wording uses the existing Mosaic tile/glyph classes and stepped reveal. Icons
and curved arrows are SVG paths drawn over time. Positions are absolute canvas
pixels, and each row's `at` is relative to the graphic start. Up to three rows fit
the default 650px layout; keep clear of the speaker and screen.

```json
{
  "kind": "namePlate", "start": 0, "end": 10,
  "props": {
    "variant": "inkStory", "title": "TWO TOOLS, DIFFERENT ROLES",
    "x": 40, "y": 105, "width": 650, "fontSize": 40,
    "headingSize": 36, "ink": "#fffbed",
    "rows": [
      {"label": "Codex", "detail": "Iteration", "icon": "code", "at": 0},
      {"label": "Claude", "detail": "Building", "icon": "spark", "at": 6}
    ]
  }
}
```

Ink symbols: `code`, `spark`, `database`, `phone`, `canvas`. They are illustrative
symbols, not official brand logo reproductions. Add SVG paths to the renderer's
symbol map to extend the set. Keep text in the chips rather than SVG or images.
