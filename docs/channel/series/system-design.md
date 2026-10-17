# System design for designers (series recipe)

How the parts of this series are edited, so that every part looks the same. The rules are
also in [Style.md](../Style.md), under "System design series". Part 1's full notes are in
[videos/AgentUX-System-Design Video.md](../videos/AgentUX-System-Design%20Video.md).

| Part | Project | Title | Length |
|---|---|---|---|
| 1 | `AgentUX-System-Design.yamvideo` | System design for designers: how I built my own Mobbin (Part 1) | 11:54 |

The app must have the Ink layout (PR #38) and the white frost thumbnail (PR #40). Part 1's
project is version 17.

## 1. Footage

- Camera: DJI Osmo Pocket 3, with the Hollyland Lark mic. Drawing: YamDraw on the iPad
  (white ink on a dark dot grid). App tours: iPad screen recordings.
- With two or more takes, join them into one recording (copy the picture, no re-encode)
  and put the screen recordings on that timeline in one screen file. A Movie shows the
  speaker only, so one recording keeps the layouts and graphics.
- Find each screen's offset from hand motion against screen change (Part 1: −47.1 s for
  the tour, +3.2 s for the drawing).

## 2. Transcript and cuts

- Transcribe with whisper large-v3-turbo, with `--carry-initial-prompt` and a prompt of
  the names, written with punctuation. Then check the names. The prompt once changed
  "mobile" into "Mobbin".
- Tight cuts first. Then flow cuts for repeats, side stories and fillers. Do not speed up.
  Aim for less than 12 minutes.
- At each cut, keep 0.11 s of quiet on each side. Listen to each joint. Fix the captions
  where a word is doubled or left over at a cut edge.

## 3. Layouts and zooms

| Part of the video | Layout | Zoom |
|---|---|---|
| Intro, stories, outro | Speaker (the base layout) | 1.15x push-in on the face |
| App tour | Screen (bubble: circle, bottom right) | screen zooms where text is small |
| Hand-drawn system design | Ink (the owner on the right) | sketch zoom 1.5x, aimed where the most ink is |

- A layout or a zoom aim changes only at a sentence start.
- The base layout is Speaker, with Screen and Ink spans. A span cannot reach an end that
  is not on a frame.

## 4. Graphics

- Look: mix. Accent: #F5C42C. Panel: shade.
- Scale each one up for phones: name plate 1.5, feature list 1.35, title cards 1.27, link
  card 1.25, ink panels 1.2.
- Cards and panels stay out of the Ink parts. Ink panel points are 50 px.
- Logo badges: run `analyze --kind logos`, and use each brand's official logo. A wide
  wordmark keeps its label.
- A link card for the project's site. The end screen at the end.

## 5. Publish

- **Title:** `System design for designers: <hook> (Part N)`. The hook is what people
  remember (Part 1: "how I built my own Mobbin").
- **Description:** what the project is; "In this video I draw the system design of …, part
  by part:" and a numbered list of the parts; why a designer needs system design; "This
  is part N of a series."; the links; the gear line; `#SystemDesign #UXDesign #AINative`.
- **Chapters:** one for each part drawn, and for the intro, the tour and the outro.
- **Tags:** start with `system design for designers, system design, design engineer, UX
  design, product design, AI native`, then the project's names and tools.
- **Category:** Science & Technology. **Language:** English. **Captions:** upload the SRT.

## 6. Thumbnail

1. Find a frame: `analyze --kind thumbnailFrames`. Pick one where the owner smiles and
   faces the camera (Part 1: 11:54.2, in the outro).
2. Make the hook picture from the repository's root:

   ```sh
   swift Tools/Thumbnails/hook_image.swift hook.png "HOW I BUILT" "MY OWN" Mobbin Supabase Claude Figma
   ```

   The logo goes after the second line, in place of the brand's name. Use at most three
   badges.
3. Try the design with a `thumbnail` request, then save it (`thumbnail --save`). Part 1's
   design:

   ```json
   {
     "background": "frost", "side": "left", "place": "clear", "cutout": true, "outline": false,
     "zoom": 1.15, "time": 714.2,
     "tag": "DESIGN ENGINEERING", "title": "*SYSTEM DESIGN*\nFOR DESIGNERS", "highlight": true,
     "image": "/path/to/hook.png", "imageSize": 1.6
   }
   ```

   The non-breaking spaces keep the title on two lines. Part 1's picture and thumbnail are
   in [assets/system-design](../assets/system-design/).

## 7. Export and check

- Export for YouTube to `output/<Project>/`.
- Check each export: the video and audio lengths agree, and the sync is correct (audio
  against the camera file, frames against the app's preview).

## 8. Shorts

- 30 to 60 s each, one point from start to end, cut at sentence edges.
- Set `screen: "top"` for parts with the sketch or the app. Set it off when a layout
  changes near the Short's end.
