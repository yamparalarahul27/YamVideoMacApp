# YamVideo

A small native macOS app for cropping video, blurring out parts of it, adding Screen
Studio-style zooms, and converting it to MP4, animated GIF or animated WebP. Drop in a
`.mov` (or almost anything else ffmpeg reads), edit on the frame, hit Convert.

Built as a plain SwiftUI app that drives `ffmpeg` — no Xcode project, no dependencies to
vendor, and the exact command it runs is always visible in the sidebar.

## Requirements

- macOS 14 or later
- `ffmpeg` and `ffprobe`: `brew install ffmpeg`

The app looks in `/opt/homebrew/bin`, `/usr/local/bin`, `/opt/local/bin` and `/usr/bin`
(a GUI app doesn't inherit your shell `PATH`). If yours lives somewhere else, the banner
at the top of the window has a **Locate ffmpeg…** button.

WebP export additionally needs an ffmpeg built with `libwebp`, and Homebrew's plain
`ffmpeg` is now a slim build without it — the everything-included one is a separate
formula:

```sh
brew install ffmpeg-full
```

It is keg-only, so it stays out of `bin`; the app looks in
`/opt/homebrew/opt/ffmpeg-full/bin` (and the `/usr/local` equivalent) before the usual
places and picks it up on its own. Check what yours has with
`ffmpeg -encoders | grep libwebp`. The app runs that check itself on launch and says so in
the Format section rather than failing at the end of an export. GIF and MP4 need nothing
extra.

## Build and run

```sh
./build.sh
open build/YamVideo.app
```

To keep it around, drag `build/YamVideo.app` to `/Applications` — or:

```sh
cp -R build/YamVideo.app /Applications/
```

Run the checks with `./test.sh` (200 assertions, including real encodes and frame-by-frame
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
| **Make a GIF or WebP** | Pick the format in the settings pane. Everything else — crop, blur, zoom — works exactly the same |
| **Convert** | ⌘R for the whole queue, or **Convert Selected** in the toolbar. ⌘. stops |

Output lands next to each source file as `<name>-converted.<ext>` (`.mp4`, `.gif` or
`.webp`, following the format) unless you choose another folder. Existing files are never
overwritten and the source is never clobbered.

### Settings

- **Format** — **MP4 video**, **Animated GIF**, or **Animated WebP**. GIF and WebP are
  silent and looping; the encoder, speed and audio controls are replaced by the options
  that actually apply to them
- **Encoder** (MP4) — H.264 via x264 (best quality per byte), H.264 via VideoToolbox (much
  faster, hardware), or HEVC via VideoToolbox (smallest, tagged `hvc1` so QuickTime plays it)
- **Quality** — one slider; the CRF, VideoToolbox `q` or libwebp quality it maps to is
  shown next to it
- **Scale** — optionally cap the long side (4K/2560/1080p/720p/480p/640/480). Never upscales
- **Blur areas** — **Blur** (soft gaussian), **Pixelate** (chunky mosaic), or **Black box**
  (solid fill, nothing recoverable), plus a strength/block-size slider
- **Audio** (MP4) — re-encode to AAC 192k (default), copy the original stream, or drop it

For GIF and WebP:

- **Frame rate** — 24/20/15/12/10 fps, or leave the source rate alone. 15 fps is the
  default and halves the file against 30 fps for very little visible cost. It never pads a
  slow source *up* to a higher rate
- **Loop** — forever (default) or play once
- **Colours** (GIF) — 256/128/64/32. Screen recordings are mostly flat UI colour and
  usually survive 64 with no visible difference
- **Dither** (GIF) — **Ordered** (a fixed pattern, so it compresses well between frames),
  **Diffusion** (best gradients, noisier and bigger), or **None** (hard edges, ideal for
  text and flat UI)
- **Lossless** (WebP) — pixel-exact and much larger; worth it for text-heavy captures

Zooms are per-clip and set in the editor rather than here: level, start and hold length.
The ease is fixed at 0.5s in and out — a consistent ease is most of what makes these look
deliberate rather than homemade.

Every MP4 gets `+faststart` so it streams and scrubs properly on the web.

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
- **GIF is exported in two passes.** One `palettegen` pass over the whole clip, then an
  encode through that palette (`stats_mode=diff` + `paletteuse=diff_mode=rectangle`, which
  is what makes a screen recording compress at all). The one-command version of this trick
  makes ffmpeg buffer every frame in memory before it can emit any; two passes cost a
  decode and stay flat regardless of clip length. The palette lands in the temp folder and
  is deleted afterwards, including when the encode fails.
- **Frame thinning happens after the zoom.** `zoompan` re-times to whatever rate it is
  given, so an `fps` filter placed before it would simply be undone.
- **The two formats spell "play once" differently.** GIF wants `-loop -1`, WebP wants
  `-loop 1`, and both use `0` for forever. Getting this backwards silently produces a
  one-shot animation.
- **WebP needs libwebp.** It is an optional ffmpeg build flag, so the app checks
  `ffmpeg -encoders` up front and explains itself instead of surfacing ffmpeg's
  "Unknown encoder 'libwebp'" after the export has already started.

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
