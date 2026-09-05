# Amendments and follow-on features drawn from `browser-use/video-use`

**Status:** Documentation only. Amends [`full-frame-blur-effects.md`](./full-frame-blur-effects.md);
implements nothing and does not lift that plan's pause.
**Source reviewed:** `browser-use/video-use` @ `9575612` (2026-08-30, MIT). Read in full:
`SKILL.md`, `helpers/{render,grade,transcribe,transcribe_batch,pack_transcripts,timeline_view}.py`.
**Baseline:** YamVideo `01afdb1`.

`video-use` is an agent skill, not an app: an LLM reads a word-level transcript and emits an
EDL, and ~2,100 lines of Python drive ffmpeg from it. Its editorial half does not apply here.
Its ffmpeg half was written against the same failure modes YamVideo documents in
*Notes on correctness*, and in three places it is ahead of where the blur plan currently stands.

Sections 1–4 amend the blur plan. Section 5 is a separate roadmap. Section 6 records what was
looked at and rejected, so it is not re-proposed later.

---

## 1. Amendment to §7 gate 3 — kernel parity is not one scalar

The plan says: *"Calibrate the two blur kernels here; do not assume equal numeric radius values
produce equal images."* That is right, but it frames the gap as a scale factor. Three of the
four divergences below are **not** scalars and cannot be absorbed by calibrating `amount`.
This matters because §8 requires central-patch variance within 15% and clean edges, and because
today the app has no second renderer at all — every preview frame is produced by the same
ffmpeg graph as the export (`FFmpeg.thumbnail`, no Core Image anywhere in `Sources/`). The
prerequisite `Playback.swift` work is what introduces the two-renderer problem; this feature is
the first to have a tolerance riding on it.

| # | Divergence | Why it is not a scalar | Check at gate 3 |
|---|---|---|---|
| 1 | **Transfer function.** `CIContext` works in extended **linear** sRGB by default, so `CIGaussianBlur` averages linear-light values. `gblur` averages whatever samples the frame holds — gamma-encoded Y'CbCr. | Linear-light blur pulls highlights outward; gamma blur does not. The error is signal-dependent: near-invisible on flat UI, obvious on a bright window against a dark desktop. | Render the same frame both ways with a white-on-black high-contrast fixture and diff. Expect the halo, not a brightness offset. |
| 2 | **Chroma subsampling.** `gblur` applies `sigma` in each plane's own pixel units and its `planes` default is all planes. On `yuv420p` the chroma planes are half-resolution, so colour is blurred roughly **twice as far** as luma. Core Image blurs RGB, where there is no such asymmetry. | A luma-only variance metric will not see it; colour bleeds past the luma edge. | Measure chroma variance separately from luma, on a saturated colour-block fixture. |
| 3 | **Kernel shape.** `gblur` is a recursive (IIR) Gaussian approximation whose accuracy is set by `steps` (default `1`). Core Image uses a true separable Gaussian. | A one-step IIR at large sigma is measurably not Gaussian in the tails. | Compare 1-D edge-spread functions, not just a variance number. |
| 4 | **Radius units.** `CIGaussianBlur.inputRadius` is not a standard deviation. | This one *is* a scalar — the only one. | Fit the constant once, after 1–3 are closed. |

The `gblur` behaviours in rows 2 and 3 (`planes` defaulting to every plane, `steps`
defaulting to `1`, and the recursive rather than convolved kernel) are stated from reading
the filter's documentation, not measured here — no ffmpeg was available while writing this.
Confirm them against the installed build with `ffmpeg -h filter=gblur` before relying on the
resolution below; the divergences themselves stand either way, only their magnitudes move.

**Proposed resolution, to be validated rather than assumed.** Give the effect stage its own
colour contract instead of inheriting the delivery format:

```text
[geometry] → zscale=t=linear:npl=100 → format=gbrpf32le
          → gblur=sigma=<σ>:steps=3
          → zscale=t=<source transfer> → [delivery]
```

`format=gbrpf32le` closes #2 (no subsampled planes) and #1 together with the `zscale` pair;
`steps=3` closes #3. This is the same shape as `video-use`'s tone-map chain
(`helpers/render.py:111-119`), used there for a different reason, and it is why that chain
converts to `gbrpf32le` before doing any per-pixel work.

Cost is real: float RGB planes are ~6× the memory of `yuv420p` and `zscale` is not free. Gate 3
should record throughput for both this chain and the naive `gblur` on `yuv420p`, and the plan
should then choose explicitly. If the cheap chain is chosen, §8's tolerance has to move and the
README must say the preview approximates the export — the plan should not carry a tolerance it
did not measure.

Amend §5 (*Rendering contract*) to state the effect stage's pixel format and transfer
explicitly, and amend §8 (*Image behavior*) to require luma and chroma variance separately plus
an edge-spread comparison.

## 2. Amendment to §5 — `blend=all_expr` cost, and the hold region that needs no blend

`blend=all_expr` evaluates its expression **per pixel, per plane, per frame** through ffmpeg's
expression interpreter — about 3.1M evaluations per 1080p frame on `yuv420p`, more on
`gbrpf32le`. Nothing else in YamVideo's graph is per-pixel-interpreted, so this stage is likely
to dominate export time and it should be measured at gate 3 before the graph is settled.

Two reductions, both of which preserve the plan's `w(t)` contract exactly:

1. **The hold region does not need `blend` at all.** Where `w(t) == mix == 1` the output is the
   blurred branch verbatim. Only the two fade windows need a crossfade. Gate the branches with
   `enable='between(t,…)'` so the interpreter runs for `fadeIn + fadeOut` seconds instead of the
   whole block. On the proposed defaults (0.25 s each, 3 s block) that is ~17% of the frames.
2. **`mix < 1` holds are a constant.** `w` is uniform in space and constant in time across the
   hold, so that window is one static opacity, not an expression.

Neither changes `w(t)`; both change how many frames pay for it. If gate 3 shows the cost is
tolerable, keep the single-expression form for simplicity and record the number.

Worth writing down as a rejected alternative: ramping `gblur`'s `sigma` over time via `sendcmd`
avoids the per-pixel expression entirely, but it is a **different effect** — a focus pull rather
than a dissolve — and it contradicts §4's *"the blur radius stays fixed during a fade"*. It is
also harder to match in Core Image. Not recommended; noted so it is not re-litigated.

## 3. New subsection for §5 — HDR sources reach the blur stage untone-mapped

`video-use` probes `color_transfer` and prepends a tone-map chain when it finds PQ or HLG
(`helpers/render.py:104-160`). YamVideo does not: `Sources/FFmpeg.swift` never reads
`color_transfer`, `color_primaries` or `colorspace`, so an HLG source is blurred in HLG,
converted to 8-bit `yuv420p`, and written out still carrying HLG transfer metadata. Players that
honour the tag show it blown out; QuickTime on the capture machine can hide this locally.

This is pre-existing and independent of the blur feature — iPhone camera video defaults to HLG,
and macOS screen capture on an HDR display can produce it. But it lands on this plan for two
reasons: a Gaussian blur in a non-linear HDR transfer is the worst case for divergence #1 above,
and Core Image and ffmpeg will not agree on what HLG even means. The parity gate will fail on
HDR fixtures for reasons that have nothing to do with the blur.

Minimum for this plan: add one HLG fixture to §8, and if tone mapping is out of scope, state in
§5 that the effect stage assumes an SDR Rec.709 input and detect-and-warn on anything else —
the same shape as the existing `libwebp`/PCM-audio pre-flight warnings. The full fix (probe
`color_transfer`, insert `zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,
tonemap=tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv` at the head of the geometry stage,
and tag the output Rec.709) belongs in its own change — see §5.5 below.

## 4. Addition to §8 — a boundary contact sheet, not just numbers

`video-use`'s strongest idea is procedural: before showing a render to anyone, it re-samples the
**rendered output** at every cut boundary and inspects it, capped at three passes
(`SKILL.md`, step 7). YamVideo's equivalent already exists in spirit — `./test.sh` does
frame-by-frame verification — but §8's effect checks are all scalar assertions, and the failures
most likely here are ones a variance number will pass: a black or transparent halo at the frame
edge where the blur kernel ran out of pixels, a one-frame flash at `start` from an off-by-one in
the half-open interval, chroma bleeding past a luma edge.

Add to `Tools/` a small frame-dump helper that, given a rendered file and an effect, writes a
labelled contact sheet at `start-1f`, `start`, fade-in midpoint, hold, fade-out midpoint,
`end-1f`, `end`, `end+1f`, for the native and ffmpeg renders side by side. Make it the artifact
attached to gate 3 and gate 5, alongside the numbers. It costs an afternoon and it is the only
thing that will catch an edge halo before a user does.

The frame set is deliberately the plan's own §8 sample list — this adds a viewer, not new
criteria.

---

## 5. Candidate features after the blur, ranked by fit

The blur plan's §9 defers a long list. These are the ones `video-use` argues for, judged against
what YamVideo already is: a deterministic, local, ffmpeg-driven editor for screen recordings.

### 5.1 Cut-edge audio fades on silence removal — highest value, smallest change

`video-use` makes this Hard Rule 3: **30 ms `afade` at both edges of every segment**, without
exception (`helpers/render.py:271-272`). Concatenating segments on exact sample boundaries puts a
step discontinuity in the waveform at every cut, which is audible as a click. The plan's §1
notes silence-removal work already exists locally. If that path concatenates without per-segment
fades, it clicks at every cut, and it will click more the more aggressive the threshold is.

Related, from the same source: `video-use` never cuts closer than 30 ms to speech and pads
30–200 ms at every edge, because ASR timestamps drift 50–100 ms. YamVideo detects silence from
the waveform rather than from ASR, so it has no drift to absorb — but it has the same *musical*
problem, which is that cutting at the exact threshold crossing clips word onsets and breath
tails. A pad parameter with a sane default is the fix, and it is worth stealing the reasoning
even though the measurement is different.

Cheap to add, hard to notice missing until someone wears headphones.

### 5.2 Loudness normalization as an export option

`video-use` normalizes to **-14 LUFS integrated, -1 dBTP, LRA 11** — the target YouTube,
Instagram, TikTok and LinkedIn all normalize toward — using a proper two-pass `loudnorm`
(measure, then apply with `measured_*` and `linear=true`; `helpers/render.py:493-590`). YamVideo
offers AAC / copy / drop and nothing else, so a quiet screen recording stays quiet and a loud one
gets turned down by the platform.

This fits the existing Audio section as a fourth mode. Two notes for whoever implements it:
the second pass must be a separate ffmpeg invocation, which means the progress and cancellation
handling has to cover two passes rather than one; and it composes badly with **Copy**, so the
control needs to be mutually exclusive with it in the same way the PCM warning already is.

A one-pass `loudnorm` is available and much faster but is a dynamic-range-altering approximation,
not a gain match. If a fast path is wanted for preview, take `video-use`'s split — one-pass for
preview, two-pass for final — but note it ships that switch wired to the wrong flag
(`helpers/render.py:763` passes `preview=args.draft`, so its own `--preview` mode pays for the
slow path). Wire it to the right one.

### 5.3 Burned-in subtitles

Natural for the screen-recording-to-social workflow YamVideo already serves, and the GIF/WebP
formats make burning-in the only option. `video-use`'s one genuinely non-obvious contribution
here is not the style, it is the **safe-zone argument**: platform chrome covers roughly the
bottom 25–30% of a 1080×1920 frame, libass scales against `PlayResY=288`, so `MarginV=90` clears
the UI at any aspect ratio (`helpers/render.py:42-56`). Anything near the bottom edge gets
covered by the caption and username overlays.

The blocker is that subtitles need a source. Options, cheapest first: import an existing
`.srt`/`.vtt`; type them against the timeline that already exists; local `SFSpeechRecognizer`;
a hosted ASR key. Only the last matches `video-use`'s word-level precision, and it means
uploading the user's audio to a third party — a different product than the one this app is.
Recommend import first.

If it ships: subtitles are applied **last**, after every other overlay
(`video-use` Hard Rule 1), or the blur effect from this plan will smear them.

### 5.4 One-click cleanup grade

`grade.py`'s auto mode samples N frames, computes mean brightness, RMS contrast and saturation,
and emits an `eq`/`curves` chain **bounded to ±8% on any axis** — explicitly "make it look clean
without looking graded". The bound is the interesting part and is what makes it safe to run
unattended. A single **Clean up** checkbox doing exactly this suits screen recordings, which are
usually flat and slightly under-contrasted.

Its creative presets (`warm_cinematic`'s teal/orange split) do not suit this app. Take the
analyzer and the ±8% clamp; leave the looks.

### 5.5 HDR → SDR tone mapping

Described in §3 above. Standalone value beyond the blur feature, since it fixes iPhone footage
today. Reproduce before building: `ffprobe -v error -select_streams v:0 -show_entries
stream=color_transfer -of default=nk=1:nw=1 <clip>` on an iPhone clip, convert it, and view the
result in a browser rather than QuickTime.

---

## 6. Looked at and not proposed

- **EDL-driven multi-take assembly, transcript-first editing, the `takes_packed.md` reading
  view, animation slots.** These exist to give an LLM a cheap surface to reason over. YamVideo
  has a human with a timeline in front of them; the surface is already there.
- **Hosted ASR as a dependency.** `video-use` requires an ElevenLabs key and rejects local
  Whisper outright. A local macOS app that silently uploads the user's screen recordings is a
  different product with a different privacy story.
- **Per-segment extract → `-c copy` concat as a general export strategy.** `video-use` states
  this as Hard Rule 2 to avoid double-encoding, but its own pipeline encodes each segment at
  CRF 20 and then re-encodes the whole concatenation at CRF 18 whenever there are overlays or
  subtitles — which is its default path — so it is two generations, and audio is AAC-encoded
  twice. YamVideo's single-graph export is already the better arrangement. The per-segment shape
  is worth revisiting only if incremental re-render of changed segments is ever wanted.
- **Its 1080p-only output.** `render.py` hard-codes a 1920 long edge with no override, while
  `SKILL.md` §*Output spec* tells the agent to pass a `--filter` flag that does not exist.
  YamVideo's scale control is already better; noted only as a reminder to keep the docs and the
  flags in sync.
