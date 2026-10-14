# Native scaffold (reference)

A parallel take on YamVideo, built August 2026, preserved here for reference. It is a
**native AVFoundation** three-tab app (Record / Export / Edit) — where YamVideo drives
ffmpeg for everything, this one uses ffmpeg only where it genuinely wins (GIF palettes,
lossless concat) and Apple's media stack for the rest.

Self-contained Swift package; nothing in the main app depends on it.

## What's here and why it's worth keeping

- **`Sources/YamparalaVideo/Capture/`** — working ScreenCaptureKit + AVCaptureSession
  capture code (from the Pen-Fight-Stream app), including Continuity Camera discovery
  and a Metal-backed Core Image compositor with rounded-corner camera masking. This is
  the foundation for a future **Record** feature: screen + iPhone camera written as two
  files on one clock → perfectly synced takes, no alignment step.
- **`Sources/YVCore/`** — UI-free pipeline library: `MediaInfo` probing,
  **lossless MOV→MP4 remux** via passthrough `AVAssetExportSession` (instant, no
  re-encode — a fast path YamVideo's transcode-everything flow could adopt), export
  presets, GIF/concat ffmpeg arg builders, and the `EditDoc` JSON document model.
- **`docs/PLAN.md`** — the full product plan: timeline interaction spec (trim/cut/snap,
  keyframe-aware snapping), privacy-blur design, synced-take recording design, animated
  facecam frame approach, risks, and ffmpeg/AVFoundation recipes.
- **Working Export tab** (SwiftUI): drop files → remux-or-transcode with per-file
  lossless/transcode badges, presets, batch, GIF with palette optimization.

## Build & test

```sh
cd native-scaffold
swift test              # 7 tests: probe, remux, transcode, naming, GIF args, EditDoc
./scripts/build-app.sh  # assembles build/Yamparala Video.app (signed)
```

Requires macOS 15+ and Xcode command line tools. ffmpeg (`brew install ffmpeg`) is only
needed for GIF export; everything else is dependency-free.

## Status when parked

Phases 0–1 of `docs/PLAN.md` complete: scaffold, probing, Export tab, tests. Edit and
Record tabs are placeholders. Development continued in the repo root (YamVideo) instead;
this folder is the donor for Record/sync/remux work when that lands on the roadmap.
