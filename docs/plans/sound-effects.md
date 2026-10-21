# Sound effects and music hits

**Status (2026-10-21):** A plan. The owner answered four questions the same day (see
"The owner's answers"). Nothing is built. Next: a mock-up on the Tradl video, so the owner
can see and hear the cues, the music hits and a fast track before any code.
**Source:** the owner, 2026-10-21, after the test of the music duck (PR #73): "I like the
music work done, but it is not my vibe … my vibe is more into fast, informative
entertainment, education, tech."

## Why

The duck test showed two facts:

1. **The owner talks with almost no pauses.** In the Tradl edit, the longest gap between two
   words is 0.51 s (tight cuts). In the raw take, the longest silence is 1.65 s. The duck
   lifts the music only in a gap of 1.6 s or more, so in a tight edit it never lifts. The
   music bed stays at one level from start to end.
2. **A calm bed does not fit the channel.** The test pad (slow chords) was smooth and calm.
   The channel is fast, informative and entertaining: design, education and tech.

So the energy cannot come from pauses. It must come from three places:

- **The track:** a faster track with drums (see "The track for this channel").
- **Short sounds on the graphics:** a whoosh when a section card comes in, a tap for each
  letter that the link card types, a pop for a logo badge.
- **Music hits:** a short swell of the music at each section card.

## What the app does now

- **Music:** a bed from a file (part 1, PR #59, merged), and the duck (part 2, PR #73): the
  music at its level under speech, and up in pauses of 1.6 s or more. The duck uses gain
  points, and the preview and the export play the same points.
- **Graphics:** each graphic has a start and an end on the edited timeline, and follows the
  edit. Each kind has its own motion in `Resources/Graphics/graphics.js`, with fixed times.
  For example, a section card fades in over 0.25 s and its bar moves from 0.45 s to 1.35 s.
  The link card (PR #71) types one letter each 0.09 s from 1.3 s, and its window opens
  0.2 s after the last letter.
- **Sound:** the export mixes the voice and the music. Graphics have no sound. Shorts keep
  only the voice.

## Decisions (proposed)

1. **The sounds come from the graphics.** Each kind of graphic has cues: a sound at a moment
   of its motion. A section card has a whoosh at its start; a link card has a tap for each
   letter. When a graphic moves or the edit cuts it, its sounds move with it. The owner does
   not place sounds by hand. The owner can change the sound of a cue, or switch a cue off,
   for one graphic or for all graphics of a kind.
2. **The graphics engine gives the times of the cues.** `graphics.js` gets a pure function,
   `soundCues(kind, props, length)`, that returns `[{at, cue}]` from the same constants as
   the motion. The app calls it with the render of each graphic and keeps the result with the
   render. Thus one file holds the times, and a change to a motion also moves its sound.
3. **Sounds are short files in a sound library**, as logos are:
   `~/Library/Application Support/YamVideo/Sounds`, with `sounds.json` (the name, the file,
   the length, the measured loudness and the licence of each sound). Export for YouTube
   stops a licence that a monetised video cannot use, with the same rules as music.
4. **The level is in LU under the voice**, as for music. A sound is short, so the app
   measures its loudest 400 ms (momentary loudness), not the integrated loudness. Default:
   −8 LU, so a whoosh is clear but softer than the voice.
5. **Music hits use the gain points of the duck.** At the start of each section card, the
   music goes up 4 dB over 0.15 s and comes back over 1.0 s. The hit adds points to the same
   envelope as the duck, so the preview and the export play the same sound. The
   background-music plan puts "music that goes up at each section card" under "Not in this
   plan". It fits now, because in a tight edit the section cards are the only moments where
   the music can come forward. The hit is short (about 1.2 s), so it does not fight the voice
   for long.

## The track for this channel

This part is a guide, not code. It answers the owner's question about the vibe.

- **Tempo:** 100 to 128 BPM. A fast edit needs a pulse under it.
- **Sound:** electronic, lo-fi hip hop or light future bass, with crisp drums and a simple
  melody. No vocals: words in the music fight the voice.
- **Energy in the drums and the bass, not in the middle.** Pads and synths from 300 Hz to
  3 kHz sit on the voice and make it hard to follow. Drums and bass leave room for it.
- **Mood:** bright, funky or inspirational. Not dramatic or cinematic.
- **Where:** YouTube Studio → Audio Library. Use the filters Genre (Dance & Electronic, or
  Hip Hop & Rap), Mood (Bright, Funky or Inspirational) and "Attribution not required".
  Then the app needs no credit line.
- **Length:** a track with a beat loops badly: the 2 s crossfade of part 1 does not keep the
  beat. Use a track at least as long as the video, or switch Loop off. (A loop on the beat
  can come later.)
- **Level:** start at −20 LU and try −18 to −22 LU on a phone.

If the owner agrees, a short rule for the track goes into `docs/channel/Style.md`.

## The cues

| Kind | Moment | Sound (from the kit, if its licence permits) | Default |
|---|---|---|---|
| Section card | the card comes in (0 s) | whoosh-1 | on |
| Kinetic text | the first word | whoosh-2 | on |
| Kinetic text | each later word | a soft tap (button-1 to 6) | on |
| Link card | each typed letter | a key tap (button-1 to 6, in turn) | on |
| Link card | Enter, the window opens | whoosh-2 | on |
| Name plate | comes in | whoosh-2, quieter | on |
| Logo badge | each chip pops in | natural-tap-1 | on |
| Checklist | each tick | button-3 | on |
| Title card | comes in | whoosh-1 | on |
| Callout (PR #69) | the line draws | button-2 | on |
| End screen | comes in | musical-tap-1 | off |

The questions below ask the owner about each default.

## Where the sounds come from

1. **The owner's "Boring Sound Kit"** (`~/Downloads/!Boring Sound Kit`): 18 WAV files, 44.1 kHz
   stereo. Whooshes are 0.75 to 0.96 s, buttons are 0.12 to 0.24 s, taps are 0.8 to 1.8 s.
   The folder has **no licence file**, the files have no download source, and a web search
   did not find the kit. Do not use it in an export until the owner gives its source and
   licence.
2. **YouTube Audio Library → Sound effects:** free for YouTube videos, also monetised videos.
   The owner downloads them with their own account.
3. **Sounds that the app makes:** ffmpeg can make a whoosh (filtered noise that sweeps up),
   a tap (a short sine with a fast fade) and a pop. They have no licence question, and they
   need no download. They are simpler than recorded sounds.

Cloud services (for example ElevenLabs sound effects) are not in this plan.

## How it works

- **Export:** each sound file is one more ffmpeg input, as music files are. Each cue is
  `adelay` and `volume`. Then `amix` adds the cues to the voice and the music. With Loudness
  on, the loudness pass measures this mix. A long graph goes to a file, as now.
- **Preview:** the cues go on two more audio tracks of the composition (they alternate, as
  the music plays do), with a volume for each cue.
- **Movie:** each recording mixes its own cues, as it does its music.
- **Shorts:** a Short keeps its graphics, so it could keep their sounds. A question for the
  owner.
- **The switch:** **Sounds** becomes one more change that the owner can switch off
  (`SwitchableChange.sounds`), and the Audio row gets a mute for the preview.
- **The timeline:** a small mark on each graphic bar where a cue plays.

## Saved data (version 23)

Version 22 is the duck (PR #73), so this is version 23.

- `ProjectClip.sounds` (`SoundSettings`): `level` (LU under the voice, −20 to 0, default −8)
  and `kinds` (for each kind and cue: a sound name, or `off`). Nil: the defaults.
- `GraphicItem.sounds`: for one graphic, a cue's sound name or `off`. Nil: the kind's choice.
- `MusicBed.hits` (`MusicHits`: `lift` 0 to 8 dB, default 4; nil is off).
- The app refuses a file of version 22 or older that holds any of them.

## For agents

- `setSounds {clipID, sounds: {level?, kinds?}}` and `updateGraphic … graphic: {sounds}`.
- The sound library: `sounds` (the list), `setSound {name, path, licence}` and
  `removeSound`, as the logo library does.
- `setMusicDuck` also takes `hits` (the lift at section cards).
- `state.clips[].sounds` gives each cue: its time, its graphic, its sound and its gain.
  `analyze` with kind `music` also gives the cues and the hits.
- A new recipe in the Agents Manual: 4.19 Sound effects.

## The order

1. **Sound library and the first cues:** section card, title card and link card, in the
   preview and the export (version 23). They give the most energy first.
2. **All other kinds**, the choice for each graphic, and Shorts.
3. **Music hits** at section cards.
4. **Sounds that the app makes** (ffmpeg). If the kit's licence is unknown, this part comes
   first, so part 1 has sounds to use.

## The owner's answers (2026-10-21)

1. **Sources:** use free open sounds (CC0, or CC BY with its credit), the owner's "Boring
   Sound Kit" (the owner says to use it; its source is not known, so the app marks its
   licence "other", and Export for YouTube warns), and sounds that the app makes. AI sounds
   (a local model) can come later. All of it must be easy for an agent to direct: the app is
   the medium where the owner and the agent work together. So each sound has a name in the
   library, and agents choose cues by name.
2. **Cues:** all four groups are on by default: whooshes on section and title cards, key
   taps on the link card, pops on badges and ticks, and a tap on each kinetic word. (The
   table above had the kinetic word taps off; they are now on.)
3. **Music hits:** the owner asked for a recommendation. Recommendation: yes, a short swell
   (4 dB, about 1.2 s) at each section card. The mock-up lets the owner hear it first.
4. **The track rule for Style.md:** not yet. The owner wants to see a fast track on the
   Tradl video first.

Still open: how loud a sound is (question 3 below), and sounds in Shorts (question 5).

## Questions for the owner

1. Where does the "Boring Sound Kit" come from, and what does its licence permit? If you do
   not know: use YouTube Audio Library sounds, or sounds that the app makes?
2. Are the defaults in "The cues" correct? In particular: a tap for each typed letter of the
   link card? A tap for each word of a kinetic text (now off)?
3. How loud is a sound: −8 LU under the voice (clear), or quieter?
4. Music hits at section cards: a short swell (4 dB, about 1.2 s), or nothing?
5. Sounds in Shorts too?
6. May I add the rule for the track (tempo, genre, no vocals, energy in drums and bass) to
   `Style.md`?

## Tests (`./test.sh sounds`)

- The cues of each kind from `soundCues`, and that they move with the graphic after a cut.
- The gain from the voice and the sound's momentary loudness.
- The ffmpeg graph with cues, with and without music, and for the movie.
- The preview's tracks and volumes for the cues.
- Licences: the stop for CC BY-NC, CC BY-ND and CC BY-SA, and a warning for no licence.
- Version: a version 22 file with sounds is refused; a project saves and opens with them.
- Music hits: the points at each section card, added to the duck's points.
- A real export: a 10 s voice with a section card, measured at the cue's time.
