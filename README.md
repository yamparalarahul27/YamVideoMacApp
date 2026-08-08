# YamVideo

A small native macOS app for cropping video, blurring out parts of it, adding Screen
Studio-style zooms, and converting it to MP4. Drop in a `.mov` (or almost anything else
ffmpeg reads), edit on the frame, hit Convert.

Built as a plain SwiftUI app that drives `ffmpeg` — no Xcode project, no dependencies to
vendor, and the exact command it runs is always visible in the sidebar.

## Requirements

- macOS 14 or later
- `ffmpeg` and `ffprobe`: `brew install ffmpeg`

The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`
(a GUI app doesn't inherit your shell `PATH`). If yours lives somewhere else, the banner
at the top of the window has a **Locate ffmpeg…** button.

## Build and run

```sh
./build.sh
open build/YamVideo.app
```

To keep it around, drag `build/YamVideo.app` to `/Applications` — or:

```sh
cp -R build/YamVideo.app /Applications/
```

Run the checks with `./test.sh` (152 assertions, including real encodes and frame-by-frame
verification that blurs actually remove detail and zooms land where they should).

## Using it

| | |
|---|---|
| **Add clips** | Drop files (or a folder) onto the window, press ⌘O, or open a video with the app from Finder |
| **Crop** | Drag inside the rectangle to move it, drag any of the 8 handles to resize, or drag on the dimmed area to draw a new one. Type exact pixel values in the X/Y/W/H fields |
| **Lock a shape** | Pick an aspect preset (16:9, 9:16, 1:1, 4:5, 4:3, 2.39:1) and resizing keeps that ratio |
| **Blur an area** | Switch the editor to **Blur Areas** and drag over anything you want hidden — a face, a name, a URL. Add as many areas as you like; drag or resize them the same way as the crop. **Add Area** drops one in the middle if you'd rather not draw |
| **Zoom in** | Switch to **Zoom**, scrub to the moment, then click the spot. The video eases in, holds still, and eases back out. Pick 1.5×/2×/3× and how long it holds; drag the marker to re-aim it |
| **Pick the frame you work against** | Drag the scrubber under the preview |
| **Reuse your work** | **Apply to All** copies the crop, blur areas *and* zooms to every other queued clip with the same dimensions |
| **Convert** | ⌘R for the whole queue, or **Convert Selected** in the toolbar. ⌘. stops |

Output lands next to each source file as `<name>-converted.mp4` unless you choose another
folder. Existing files are never overwritten and the source is never clobbered.

### Settings

- **Encoder** — H.264 via x264 (best quality per byte), H.264 via VideoToolbox (much
  faster, hardware), or HEVC via VideoToolbox (smallest, tagged `hvc1` so QuickTime plays it)
- **Quality** — one slider; the CRF or VideoToolbox `q` value it maps to is shown next to it
- **Scale** — optionally cap the long side (4K/2560/1080p/720p/480p). Never upscales
- **Blur areas** — **Blur** (soft gaussian), **Pixelate** (chunky mosaic), or **Black box**
  (solid fill, nothing recoverable), plus a strength/block-size slider
- **Audio** — re-encode to AAC 192k (default), copy the original stream, or drop it

Zooms are per-clip and set in the editor rather than here: level, start and hold length.
The ease is fixed at 0.5s in and out — a consistent ease is most of what makes these look
deliberate rather than homemade.

Every output gets `+faststart` so it streams and scrubs properly on the web.

## Notes on correctness

A few things this handles that are easy to get wrong:

- **Rotated footage.** iPhone and screen-recorded MOVs carry a rotation matrix. ffmpeg
  applies it before filters, so crop and blur rectangles are expressed against the
  *displayed* frame — what you see in the preview is what you get.
- **Blur runs before the crop.** Blur areas live in full-frame coordinates, so moving the
  crop doesn't drag them along with it. The preview bakes the blur in using the same graph
  builder the export uses, so preview and output can't drift apart.
- **`-filter_complex` breaks stream selection.** Blurring needs a filter graph rather than a
  simple chain, which silently drops audio unless every stream is mapped explicitly. There's
  a test for exactly that.
- **Even dimensions.** `yuv420p` needs even width, height, and offsets, so crop values
  snap to even numbers rather than failing at encode time.
- **Audio copying.** ffmpeg will happily copy PCM audio into MP4 as `ipcm`, producing a
  file QuickTime and Safari can't decode. The app warns when the selected clip's audio
  isn't MP4-compatible and Copy is chosen.
- **Progress and cancelling.** Progress is parsed from ffmpeg's `-progress` stream;
  cancelled or failed encodes delete their partial output instead of leaving a stub.
- **Zoom keeps the exact frame rate.** `zoompan` re-times to whatever rate you give it, so
  rounding 29.97 to 30 shortens a clip by ~1ms/s and drifts audio out of sync. The rate is
  carried through verbatim as `30000/1001`.
- **Zooming upscales.** A 2× zoom on 1080p shows 540p worth of pixels stretched back up, so
  it looks softer. Record at 4K (or Retina) and export to 1080p and zooms cost nothing.
- **Zooms near an edge clamp inward** rather than showing black bars, so the target may not
  end up dead centre when it sits close to the frame edge.

## Layout

```
Sources/
  App.swift         @main, menu commands, Finder open-file handling
  AppModel.swift    queue, selection, preview, conversion driver
  ContentView.swift window layout: queue sidebar, editor, settings pane
  CropEditor.swift  crop/blur/zoom overlays, handle/resize maths, pixel fields
  FFmpeg.swift      locating the binaries, probing, thumbnails, export
  Models.swift      media info, export settings, geometry helpers
  Shell.swift       process runner with streamed output
Tests/main.swift    end-to-end checks (./test.sh)
Tools/makeicon.swift  draws the app icon at build time
```
