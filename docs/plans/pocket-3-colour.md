# Pocket 3 colour for beginners — implementation plan

**Updated:** 2026-10-13. **Status:** Planned, no colour feature implemented by this PR.
**Owner context:** Newly purchased DJI Osmo Pocket 3; little colour-grading knowledge;
wants an understandable UI and help from local Codex/Claude sessions.
**Parent plan:** [Local co-editing](local-coediting.md). This colour phase precedes
whole-frame creative blur and uses the same commands, history and inspector.

## 1. Camera-specific facts and product boundary

Pocket 3 uses **D-Log M**, which is distinct from DJI D-Log. DJI supplies a Pocket 3
D-Log M → Rec.709 `.cube` conversion LUT. Use that specific technical conversion, not a
D-Log LUT from a different camera or a creative look pretending to be a conversion.
[DJI supported profiles](https://repair.dji.com/help/content?customId=01700007105&lang=en&paperDocType=ARTICLE&re=US&spaceId=17)
and [official Pocket 3 LUT](https://www.dji.com/downloads/softwares/osmo-pocket-3-dlog-to-rec709).

The app should explain: “D-Log M footage looks flat before correction. Natural colour
converts it for standard screens; then you can adjust the look.” Do not promise that Log
is always better, that a LUT fixes exposure mistakes, or that grading recovers clipped
highlights. Recording advice can acknowledge that Normal is simpler for ready-to-use
footage; this feature supports the owner's D-Log M workflow without requiring expertise.

First delivery targets **SDR Rec.709** output. HLG/PQ tone mapping is a separate input
path. Existing HDR pass-through remains available outside this SDR colour workflow, but
combining it with these SDR adjustments returns a clear unsupported combination rather
than silently producing a mislabeled export. Full HDR grading/output is deferred.

## 2. User flow and controls

1. Import footage normally. The Colour inspector shows **Recorded colour**: Auto,
   Standard / already corrected, DJI Pocket 3 D-Log M, or HDR (HLG/PQ).
2. Auto uses trusted metadata for known HDR/standard cases. Camera make, filename,
   low contrast and a generic Rec.709 container tag are insufficient proof of D-Log M.
   When uncertain show “Choose the colour mode used on your camera”; preserve the image
   until chosen. A remembered camera preference may suggest a choice but cannot apply
   a conversion to every future file silently.
3. For Pocket 3 D-Log M, offer **Natural colour**. On first use, show **Get DJI conversion**
   (opens the official download page) and **Import conversion file…**. Once available,
   applying Natural colour is one undoable action. Show “Pocket 3 correction applied”.
4. Show four beginner controls, each with reset: **Brightness**, **Warmth**, **Contrast**,
   **Colour strength**. No wheels, curves or vectorscope required in the default view.
5. Offer **Original / Corrected** and a split-view comparison at the same frame, crop,
   time and display transform. Original bypasses only colour correction/adjustments;
   area redaction remains active in both views. Comparison is view state, never export
   state. Reset Adjustments returns sliders to neutral while preserving the selected
   input conversion; Remove Correction also disables the technical transform explicitly.
6. **Copy colour…** lets the owner choose destination recordings. Copy basic adjustments
   by default; copying the recorded-colour interpretation/technical LUT is a separate,
   clearly labeled choice. Never apply the D-Log M transform to Standard or HLG sources
   just because their resolution or camera matches.

Do not give the technical transform an intensity slider: it is input interpretation.
Any later creative look has its own Mix control after correction. “Auto balance” and
creative presets are follow-ons, not buttons that imply capability in the first release.
A later Suggest Balance feature must show a reversible preview and numeric changes.

| Control | Stored value | Range / default | Meaning |
|---|---|---|---|
| Brightness | `exposureEV` | -2…2 / 0 | Multiply normalized linear RGB (BT.1886-decoded, see section 4) by `2^EV`. Display plain label with stops in Details. |
| Warmth | `warmth` | -1…1 / 0 | Gentle warm/cool creative adjustment, not a claim to recover camera Kelvin. |
| Contrast | `contrast` | 0.5…1.5 / 1 | Linear RGB contrast about 0.18, following exposure/warmth. |
| Colour strength | `saturation` | 0…2 / 1 | Interpolate each channel from Rec.709 linear luminance to its RGB value. |

For deterministic v1 warmth: gains `g=(2^(0.2*w), 1, 2^(-0.2*w))`, divided by
`0.2126*g.r + 0.7152*g.g + 0.0722*g.b` to preserve neutral-grey luminance. Contrast is
`0.18 + c*(RGB-0.18)`. Saturation uses `Y=0.2126R+0.7152G+0.0722B` and
`Y+s*(RGB-Y)`. Apply in table order; clamp only at the SDR delivery boundary. These are
proposed simple creative controls, not a scene-referred RAW grading system. If a review
changes their math, version the algorithm and refresh golden fixtures instead of silently
changing old projects' appearance.

## 3. Data, assets and agent commands

Add `Sources/ColorAdjustments.swift`:

```text
ClipColorSettings
  inputProfile: auto | standard | pocket3DLogM | hlg | pq
  technicalLUT: optional LUTAssetRef
  correctionEnabled: Bool
  exposureEV: Double = 0
  warmth: Double = 0
  contrast: Double = 1
  saturation: Double = 1
  algorithmVersion: Int = 1

LUTAssetRef
  id, sha256, originalName, relativeProjectPath, role
  role: pocket3DLogMToRec709
```

Persist per-recording settings on `VideoItem`/`ProjectClip` with v4 migration from the
parent plan's v3. Old files default to no new correction; retain existing HDR export
behaviour. Technical LUT identity is a content hash, not just a filename. Validate all
numbers, ranges, known algorithm/profile values and profile/LUT compatibility before
restore or commit. Include settings in preview/cache keys, MoviePlan inputs, history,
save/open and recovery. Changing profile invalidates incompatible technical LUT state.

Import through a local picker/CLI path. Parse a supported 3D `.cube` with finite values,
`LUT_3D_SIZE` 2…65, complete N³ rows, RGB order and declared domain bounds. Support comments
and TITLE; reject mixed 1D+3D/shaper formats in v1. Validate ordered finite domain limits,
reject malformed/oversize files (16 MiB cap), and preserve out-of-range output entries
until the final pipeline clamp. Never execute file contents. Verify the actual DJI file
fits this subset before freezing it; if not, extend the parser deliberately with fixtures.

Record the source URL and hash of the actual imported DJI conversion; do not accept a
same-name file as evidence of authenticity. A user-imported file may be identified as
custom until compared with a verified official hash. Do not bundle/rehost the DJI LUT
without establishing redistribution terms; first delivery uses the official download
link plus import, with no account or paid LUT requirement added by YamVideo.

For portability, copy imported LUT assets to `<project-name>.yamvideo-assets/luts/<hash>.cube`
when saving a named project. Use staging/recovery storage for an unsaved project. Save As
copies required assets before atomically writing the new project and stores relative
references; absolute original media paths retain today's behaviour. Missing or changed
LUTs require relink by hash and block corrected export, rather than silently bypassing.
Recovery must retain its staged LUTs. Delete unused assets only through an explicit later
cleanup operation, not while undo might still reference them.

Agent commands: `setInputProfile`, `importTechnicalLUT` (validated asset result),
`setColorAdjustments`, `resetColorAdjustments`, and `copyColorAdjustments`. All require IDs
and expected revision; batch copy is one transaction. State reports explicit versus
inferred profile and evidence, correction availability, adjustment values and LUT hash.
Agents can request original/corrected preview pairs with the same revision/timestamp,
explain proposed adjustments, and apply them without editing the project file directly.
No new permission dialog for ordinary bounded adjustments.

## 4. Shared rendering contract

```text
Decode with explicit range/matrix and orientation
  -> exactly one input normalization:
       Standard: identity to normalized Rec.709
       Pocket 3 D-Log M: official technical LUT -> Rec.709
       HLG/PQ: existing HDR -> SDR tone mapping, reconciled in both renderers
  -> linear Rec.709 exposure / warmth / contrast / saturation
  -> area obscuring -> crop -> zoom -> whole-frame visual blur (when implemented)
  -> output scaling / Movie fit and letterbox
  -> subtitle or later title overlay
  -> explicit SDR transfer, range, pixel format, Rec.709 tags and encoder
```

This specifies logical colour stages, not permission to move existing filters blindly.
Record exact conversion points, working format and transfer for each actual renderer.
D-Log M is not HLG/PQ: do not run both the technical LUT and HDR tone mapping. Keep full
source precision through normalization/adjustments (float RGB working values); final
8-bit H.264 output may remain an option, but no early 8-bit intermediate may discard the
source's precision. Existing HEVC availability does not itself prove 10-bit output.

For the technical LUT, decode RGB values representing the camera's encoded signal,
without an implicit sRGB/linear conversion before LUT lookup. Resolve limited/full range
and YCbCr matrix from verified metadata/fixtures; do not infer transfer solely from codec
tags. Linearize the LUT's Rec.709 output with the BT.1886 reference EOTF (pure 2.4 power,
black 0, normalized white 1) and re-encode with its exact inverse after the adjustments, so
neutral settings round-trip exactly and the 0.18 contrast pivot sits near mid-grey. Do not
use the inverse Rec.709 OETF, the sRGB curve or an implied display gamma in either renderer;
compute decode → adjust → encode once in the shared transform baked for both paths, never
through renderer colour management. If review chooses another curve, change it in that one
place and bump `algorithmVersion` with refreshed fixtures. Core Image's implicit colour
management is a parity risk: explicitly configure source/intermediate/output spaces and
prove the decoder delivers the intended LUT input. Preview must not double-transform it.

Use one validated LUT parser and cube data in the app. FFmpeg may use `lut3d` with explicit
trilinear interpolation; native rendering must match that interpolation (a shared sampled
cube/kernel if the available Core Image filter cannot meet the gate). Generate/bake the
same adjustment transform for both paths rather than choosing unrelated native and FFmpeg
contrast/temperature filters with superficially similar names. Cache compiled transforms
by input profile, LUT hash, algorithm version and adjustments, never per frame.

Do a renderer spike before shipping the controls. The current native `renderFrame` does
not receive the full colour export contract; `MovieCompositor` also uses a device RGB
output space. Extend both, the FFmpeg thumbnail and recording/Movie export paths. Retain
existing redaction in comparison images. Keep letterbox bars neutral and captions ungraded.
Subtitles and whole-frame blur must use the new agreed pipeline ordering.

## 5. Implementation map and gates

| File | Work |
|---|---|
| `Sources/ColorAdjustments.swift` (new) | Versioned state, parameter math, validation and migration defaults. |
| `Sources/ColorLUT.swift` (new) | Cube parser/domain/interpolation, asset hashes and cache. |
| `Sources/ColorPipeline.swift` (new) | Explicit colour transforms and shared renderer parameters. |
| `Sources/ColorInspector.swift` (new) | Source mode, Natural colour, simple controls, comparison/reset/copy. |
| `Sources/Models.swift`, `Timeline.swift`, `ProjectEditing.swift` | Per-recording state, v4 persistence, sidecar assets, history and recovery. |
| Shared command/protocol files from parent plan | Human + agent colour commands, dry-run and revision checks. |
| `Sources/Playback.swift`, `MoviePlayback.swift`, `FFmpeg.swift`, `Movie.swift` | Native/thumbnail/export parity, capabilities, colour tags, render order. |
| `Tests/main.swift`, `test.sh`, `Tools/` | Parser/math fixtures, paired frame dumps, export and persistence checks. |

Implementation order: (1) validate actual DJI LUT and source metadata; (2) establish
native/FFmpeg transform parity on one frame; (3) persist/settings/commands; (4) inspector
and comparison; (5) Movie/export/recovery/performance coverage. Missing real Pocket 3
footage does not block planning or synthetic tests, but real-camera acceptance remains
unverified until representative owner footage is available.

Acceptance:

- Neutral/identity cube produces neutral ramps; channel-order and domain fixtures catch
  swapped RGB axes, range clipping and unexpected transfer conversion. Malformed cubes
  fail without changing project state. Identity settings bypass new adjustments exactly.
- Normal footage stays unchanged; D-Log M gets exactly one chosen correction; HLG/PQ uses
  its own path. A mixed Movie applies each clip's own interpretation at clip-local time.
- Compare native and FFmpeg lossless RGB outputs after matching transfer/range: target
  mean absolute channel error <= 2/255 and 99th percentile <= 6/255 on chart/ramp/skin-tone
  fixtures away from resampling edges. This is a proposed release gate, not a measured
  result. Investigate errors instead of loosening the threshold without documenting why.
- Check real Pocket 3 D-Log M daylight, indoor skin tones, bright highlights and low light,
  plus Normal and HLG controls. Inspect gradients for banding, neutral greys and clipping;
  save original/corrected/native/export contact sheets. Synthetic tests alone don't prove
  camera decoding or a pleasing grade.
- Every slider is one gesture/undo step; reset, multi-clip copy and agent batches round-trip
  through save/open/recovery. Save As carries LUT assets; missing/hash-changed LUTs surface
  clearly. Preview results from older slider revisions never replace the latest frame.
- MP4/GIF/WebP, rotated/cropped/zoomed clips and later blur preserve timing/frame count and
  privacy redaction. SDR exports carry matching Rec.709 tags. Unsupported filter/runtime
  capabilities return actionable errors, never uncorrected “successful” output.
- Measure 4K preview and export on the owner's Mac, with cached transforms and bounded
  memory. Slider feedback should appear within 150 ms for an already decoded preview
  frame; record cold decode separately and show progress. Do not claim 4K realtime playback
  until measured. Run build/tests and manually inspect the actual before/after UI.

Later: assisted exposure/balance suggestions, reusable personal looks, shot matching,
advanced highlights/shadows, optional scopes and 10-bit HDR delivery. None is required to
make the first D-Log M correction understandable and usable.
