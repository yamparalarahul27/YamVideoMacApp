# Background music

**Status (2026-10-20):** The owner confirmed the plan and the order on 2026-10-19. Part 1
(music bed from a file) is built, in its own PR. Parts 2 to 4 come after it, one at a time.
**Source:** the backlog item of 2026-10-17, and the owner's choice for the design video
format (Juxtopposed's "I Redesigned VLC" has its own music bed): a quiet music bed under
the voice, from open-source tools or AI music models, lower under speech.

Each part is one PR. Each new tool is also an agent command, in the catalog and in the
Agents Manual (a new recipe, 4.15 Background music). `./test.sh` passes in full before each
PR, with new checks in `Tests/ChecksMusic.swift`. The owner tries each part in the built app
on a copy of the AgentUX project.

## What the app does now

- The voice is the recording's own sound. The export cuts it with the same ranges as the
  picture, with a 12 ms fade at each cut (`editedFilterGraph`, `[timelinea]`).
- **Loudness** (the Audio tab, on by default in Auto Edit) normalises the export to
  −14 LUFS and −1 dBTP in two passes. The first pass measures the whole source file
  (`loudnessArguments`). The second applies one gain (`loudnorm … linear=true`).
- The preview plays an `AVMutableComposition` of the edited timeline, with an `AVAudioMix`
  for the fades at cuts (`Playback.makeItem`). The mute on the Audio row mutes the whole
  player.
- The transcript has the start and end of each word, in source seconds.
  `ClipTimeline.time(forSource:)` gives the time in the edited video.
- `AudioAnalyzer` gives the sound level each 50 ms. Review Silence uses it.
- The movie export joins the `[timelinea]` of each recording and normalises in one pass.
- The app does not use the sound of the screen recording. The app has no music.

## Decisions

1. **The music sits on the edited timeline, not on the source.** Jump cuts do not cut the
   music. (Tight cuts give 150 cuts or more in one video. Music cut with the voice jumps at
   each cut.) When the edit changes, a piece of music follows the frame where it starts, as
   graphics do.
2. **The app lowers the music with gain points from the transcript, not with a sidechain
   compressor.** The words tell where speech starts, so the music can go down before the
   first word. The preview (`AVAudioMix` volume ramps) and the export (the ffmpeg `volume`
   filter) use the same points, so the owner hears what YouTube gets. A sidechain
   compressor (`sidechaincompress`) goes down only after the voice starts. It also goes
   down for breaths and room noise, and the preview cannot play it. With no transcript,
   the points come from the sound levels (the same levels as Review Silence).
3. **Levels are in LU under the voice.** The app measures the loudness of the voice and of
   each music file one time. Thus a loud track and a quiet track sit at the same level under
   the voice. Then Loudness normalises the mix (voice and music) to −14 LUFS.
4. **The music comes from a file first.** The owner can get a track from the YouTube Audio
   Library now. A music library (part 3) and music made on this Mac (part 4) come after.
5. **Each piece keeps its licence.** Export for YouTube writes the credit lines, and stops
   a licence that a monetised video cannot use.

## The order

1. **Music bed from a file** (project version 20). It gives the most value first: a
   licensed track under the voice, at the correct level, in the preview and the export.
2. **Duck.** The music goes down under speech and up in pauses (version 21). It changes the
   gain of part 1.
3. **Music library.** It keeps tracks and their licences for the next videos.
4. **Make music on this Mac.** It writes new tracks into the library, and it needs a large
   download that the owner must agree to. So it comes last.

If the owner wants AI music sooner, parts 3 and 4 can become one part after part 1.

## Part 1: music bed from a file

What the owner sees:
- A **Music** row on the timeline, under **Audio**. When it is empty, it folds to a thin row
  with **+** (Add Music…).
- **Add Music…** opens a sound file (M4A, MP3, WAV, AIFF or FLAC). The piece starts at the
  playhead and goes to the end of the video. When the file is shorter, it plays again with a
  2 s crossfade (**Loop** on).
- Each piece is a bar with the name of the track and its waveform. Drag the bar to move it.
  Drag an end to trim it. Pieces do not overlap. The lock works as on the other rows. A
  speaker button mutes the music in the preview only.
- The Audio tab of the inspector gets a **Music** section for the selected piece: the name,
  **Level** (−30 to −6 LU, default −20), **Fade in** (default 2 s), **Fade out** (default
  3 s), **Loop**, **Licence** (a menu), **Credit** (the line for the description),
  **Replace…** and **Remove**. Tooltips give the long help, for example "How loud the music
  is under the voice. −20 LU is quiet; −10 LU is loud."
- **Music** is one more change that you can switch off in the inspector (kept, but not in
  the video).
- The preview plays the music with the video, at the level of the export.
- MP4 exports and the movie mix the music under the voice. Then Loudness normalises the mix.
  GIF and WebP have no sound, as now. Shorts keep only the voice (see "Not in this plan").
- **Export for YouTube:** the text file gets a MUSIC section with each track, its licence and
  its credit, and the JSON gets `music`. When the licence needs a credit, the line goes at
  the end of the description (if the description does not have it). A piece with no licence
  gives a warning. A licence that a monetised video cannot use (CC BY-NC, CC BY-ND,
  CC BY-SA) stops the export.

How it works (`Sources/Music.swift`, `Sources/MusicExport.swift`):
- `MusicPiece.plays(fileDuration:videoDuration:)` gives each play of the file: its place on
  the edited timeline, the part of the file and its fades (a loop crosses over 2 s). The
  preview and the export use the same plays.
- The gain of a piece, in dB, is the voice loudness + Level − the music loudness. The app
  measures the two with the `loudnorm` pass that exports use now: the voice one time, when
  the first piece goes on, and each file when it goes on.
- Preview: each play goes on one of two audio tracks of the composition. (The two tracks
  alternate, so a crossfade has two tracks.) Volume ramps give the gain and the fades.
- Export: each music file is one more ffmpeg input, after the graphics. Each play is
  `atrim`, `aresample=48000`, `afade`, `volume` and `adelay`. Then `amix` (`normalize=0`)
  adds the plays to `[timelinea]`. With music, the sound always goes through the filter
  graph. The loudness pass measures this mix on the edited timeline (now it measures the
  source file), so the −14 LUFS is correct for the mix. The movie uses the mix of each
  recording.
- After an edit, a piece follows the frame where it starts, as graphics do. A piece "to the
  end" stops at the end of the video. If the edit removes the first frame of a piece, the
  piece starts at the next frame that stays.

Saved data (version 20): `ProjectClip.music` (`MusicBed`):
- `voice`: the loudness of the voice, in LUFS, as measured.
- `pieces` ([`MusicPiece`]): `id`, `url` (a local file), `duration` and `loudness` (of the
  file, as measured), `start` (seconds in the edited video), `end` (nil: to the end), `from`
  (seconds in the file), `level` (LU, −30 to −6), `fadeIn` and `fadeOut` (0 to 10 s),
  `loop`, and `credit` (`MusicCredit`: `title`, `artist`, `source` (a URL), `licence`,
  `line`).
- `licence` is one of: `audioLibrary` (YouTube Audio Library), `cc0`, `ccBy`, `pixabay`,
  `generated` (made with an AI model: the model's name and its licence go in `line`),
  `own`, `other` (a warning: check it), and `ccNC`, `ccND`, `ccSA` (these stop the export).
- `SwitchableChange.music`.
- `VideoProject.currentVersion` is 20. The app refuses a file of version 19 or older that
  holds music. It also refuses a file that is not a local file, times outside the video,
  pieces that overlap, the same id two times, and levels, fades or loudness out of range.

For agents:
- `addMusic` {clip, path, start?, end?, level?, loop?, credit?}: adds a piece. The app
  measures the file first.
- `updateMusic` {clip, id, …}: only the keys given change (start, end, from, level, fadeIn,
  fadeOut, loop, credit).
- `removeMusic` {clip, id}.
- `setChange` with `music`.
- The state of the project gives `music`, with the plays and the gain in dB of each piece.

## Part 2: duck

What the owner sees:
- In the Music section: **Duck** (on for a new bed) and **Lift** (0 to 12 dB, default 8).
  Tooltips: "The music goes down under speech and up in pauses of 1.5 s or more" and "How
  far the music goes up in a pause".
- On the Music row, a line over each bar shows the gain: low under speech, high in pauses,
  in the intro and at the end.
- The preview and the export sound the same.

The rules (`MusicDuck`, `Sources/MusicDuck.swift`):
- Speech is the kept words, in edited time. Words with less than 1.5 s between them are one
  run. With no transcript, speech is the sound levels above the silence threshold of Review
  Silence.
- Under speech, the music is at Level. In a gap of 1.5 s or more, before the first word and
  after the last word, it is at Level + Lift.
- Down: a 0.3 s ramp that ends 0.1 s before the first word of a run. Up: a 0.8 s ramp that
  starts 0.4 s after the last word of a run. In a gap that is too short for the two ramps,
  the music stays down.
- The limits are constants in `MusicDuck`, so they are easy to change after the owner
  listens on a phone.
- Export: the gain points become one `volume` expression for each frame (`eval=frame`), in
  the graph file that the export writes now for long graphs. The preview uses
  `setVolumeRamp` between the same points.

Saved data (version 21): `MusicBed.duck` (`MusicDuck`: `lift`; nil is off). The app refuses
a file of version 20 or older that holds `duck`.

For agents: `updateMusic` gets `duck` and `lift`. `analyze` with kind `music` gives the runs
of speech, the gain points and the measured loudness of the voice, the music and the mix. An
agent can then check the mix without ears.

## Part 3: music library

What the owner sees:
- A folder for the owner's tracks, `~/Library/Application Support/YamVideo/Music`, with
  `music.json`: the file, name, length, loudness, mood words and credit of each track. It
  works as the logo library does.
- **Add Music…** opens a list of the library (name, length, mood, licence, a play button)
  and **From File…**. A file from outside goes into the library with its credit, so the next
  video can use it again.

For agents: `musicLibrary` (the list), `setMusicTrack` (add or change a track, with its
credit) and `removeMusicTrack`. `addMusic` also takes `track` (a name in the library) in
place of `path`.

Saved data: none in the project. A piece keeps its own copy of the credit (part 1), so a
project still exports when the library changes.

## Part 4: make music on this Mac

What the owner sees:
- **Make Music…** in the Add Music list: a mood (for example "calm lo-fi, soft piano, no
  drums"), a length (default: the length of the video, up to 10 min) and **Make**. The app
  runs a local model and makes 2 versions (2 seeds). It measures each file and adds it to the
  library, with its credit (for example "Made on this Mac with ACE-Step 1.5 (MIT)").
- The first model is ACE-Step 1.5. Stable Audio 3 is the second choice. See "Local music
  models".
- The model is a download of some GB. Ask the owner before the download. The owner does the
  download, as with HyperFrames. The app reads the place of the model from a setting, as it
  does for whisper. After that, it works offline.

How it starts: a test before any app code. Make 3 instrumental beds of 3 min on this Mac,
and write down the time, the memory and how they sound. If ACE-Step 1.5 cannot make a clean
instrumental bed, use Stable Audio 3.

For agents: `makeMusic` {prompt, seconds, seeds?, name?} gives the new tracks in the library.
The Agents Manual says: ask the owner before a long run.

Saved data: none.

## Local music models (research, 19 Oct 2026)

This Mac: Apple M4 Pro, 24 GB memory, macOS 26.6, 118 GB free. Python 3.9 only, no `uv`.

| Model | Licence | On this Mac | Length | Use |
|---|---|---|---|---|
| [ACE-Step 1.5](https://github.com/ACE-Step/ACE-Step-1.5) | MIT (code and [weights](https://huggingface.co/ACE-Step/Ace-Step1.5)). The model card says that you can use the music for commercial purposes. | Apple Silicon with MLX, or a macOS package. Less than 4 GB of GPU memory for the 2B turbo model. Needs Python 3.11 or 3.12 and `uv`. | 10 s to 10 min | First choice. It makes songs with vocals; part 4 tests an instrumental bed first. |
| [Stable Audio 3](https://the-decoder.com/stability-ai-launches-stable-audio-3-0-with-up-to-six-minute-tracks-and-open-weights/) Small Music or Medium (May 2026) | Stability AI Community License: free for commercial use under US$1 M of yearly revenue. You own the output. The Gemma terms also apply (text encoder). | Yes (Small runs on the CPU). The Hugging Face download is gated: the owner accepts the terms with their own account. | Small 2 min, Medium more than 6 min | Second choice. It makes only instrumental music, which is good for a bed. |
| MusicGen (Meta AudioCraft) | Code MIT, weights CC BY-NC 4.0 | Yes | 30 s for each run | Do not use. The weights are non-commercial, and the channel is monetised. |
| Magenta RealTime 2 (June 2026) | Code Apache 2.0, weights CC BY 4.0 | MLX engine on Apple Silicon | A live stream | Not now. It is for live play, and the terms for the output are not clear. |

Cloud services (Suno, Udio, Lyria, ElevenLabs Music) are not in this plan. They are not
local and they need accounts.

## Free music libraries

- **YouTube Audio Library** (YouTube Studio → Audio Library): free for YouTube videos, also
  monetised videos. It is the safest choice for Content ID. Some tracks need a credit line;
  the library gives the line.
- **Pixabay Music:** the Pixabay Content License; no credit needed. Some creators get
  Content ID claims, so keep the page of the track.
- **Incompetech** (Kevin MacLeod): CC BY 4.0; a credit line is necessary.
- **Free Music Archive** and **ccMixter:** each track has its own licence. Use only CC0 and
  CC BY.
- **Musopen:** public-domain classical music. Check the licence of each recording.

## Licence rules for YouTube

1. Use a track only when its licence lets you use it in a monetised YouTube video: the
   YouTube Audio Library, CC0 or public domain, CC BY (with the credit), Pixabay, your own
   music, or music from a model whose licence permits commercial use (ACE-Step 1.5; Stable
   Audio 3 under US$1 M of yearly revenue).
2. Do not use an NC (non-commercial) licence. A monetised channel is commercial use.
   MusicGen's weights are NC.
3. Do not use an ND (no derivatives) licence. Creative Commons says that music synced to a
   video is always an adaptation.
4. Do not use an SA (share-alike) licence. The video must then have the same licence.
5. Do not use songs from music labels, or "no copyright" uploads from unknown people.
6. Put the credit line in the description when the licence needs it. The app writes it
   (part 1).
7. Keep the source page and the licence of each track. A Content ID claim can come also for
   a free track, and the licence is the proof for a dispute. Content ID does not read the
   description.
8. YouTube asks creators to tell when AI music is the main focus of a video ("Altered or
   synthetic content",
   [YouTube Help](https://support.google.com/youtube/answer/14328491)). A quiet bed is not
   the main focus. The export text names each track made with AI, so the owner can decide
   in YouTube Studio.

## Not in this plan

- Music in Shorts. (Later, a Short can use the part of the bed under its range.)
- Sound effects, for example a whoosh at a section card.
- Music that changes or goes up at each section card.
- An export without music still measures the whole source file for Loudness. Part 1
  changes the measure only for a recording with music.

## Tests (`./test.sh music`)

- Plays: a loop with crossfades, a trim, `from`, `end` nil, a video shorter than the file,
  pieces that touch.
- The gain from the two loudness values. The ffmpeg graph for 1 and 2 pieces, with and
  without cuts, with and without Loudness, and for the movie.
- Validation: a version 19 file with music is refused; bad values are refused; a project
  saves and opens with the same music.
- A piece after cuts follows its frame.
- Credits: the line in the description, the stop for CC BY-NC, CC BY-ND and CC BY-SA, and the
  warning for no licence.
- Part 2: runs of speech from words, gaps, ramps, short gaps, no transcript, the `volume`
  expression.
- A real export: a 10 s clip with a 3 s music file that ffmpeg makes (chords from
  `aevalsrc`, so no download). Then ffprobe the lengths of the video and the sound, and
  measure the mix: −14 LUFS ± 0.5.
