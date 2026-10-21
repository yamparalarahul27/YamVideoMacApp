# Agent harness: check, mark and match

**Status (2026-10-21):** plan only. The owner said yes to the three ideas below, in this
order. Each step is its own chat and its own pull request.

## 1. Where it comes from

On 2026-10-21 the owner asked for research on [Motion](https://motion.so/gva), the
"General Video Agent" from Mosaic (a five-person Y Combinator W25 company), announced on
2026-10-20. Motion is a cloud video agent built on a Claude model. It edits footage or
makes new footage, matches a reference video's style, cuts podcast clips around the
person speaking, and takes feedback by chat, by drawing on the frame or in a timeline.

Its main claim: **the harness** (what the model reads first, the tools it can use and how
it checks its own work) matters more than the framework it writes the video in. In its
own benchmark, the same model wrote films in seven languages; the familiar ones
(HyperFrames, Remotion, Python, Motion's own) scored about the same, at about $2.90–3.30
of model cost a film. The benchmark is small (one to four films a language), run by the
company, and gives no per-language scores.

**Decision:** do not use Motion. It is cloud only (the owner's face footage would go to
US servers and several AI providers), it can post to social accounts (against the owner's
rules), its Claude connector cannot run the video agent, and it overlaps the planned
Launch Short and App demo templates ([launch-templates.md](launch-templates.md)). Price:
$6 for 200 credits, or Pro from $29 a month; credits per film are not published. Keep
HyperFrames: the benchmark gives no reason to change. Take three of its ideas, all local.

## 2. Step 1: check before showing

**What the owner sees:** when an agent says an edit is done, it has already looked at it.
It shows a sheet of the frames it checked and what it fixed, not a first draft.

**How:**

1. A `check` request (`yamvideoctl check --clip ID [--short ID]`) renders the moments
   that matter: each graphic once it has settled, each layout change, each section's
   first frame, the end screen, and each Short at phone size with YouTube's player over
   it (`preview --short --furniture` exists). It returns the frames as files and a list
   of findings, each with a time, a level (**Must** or Ask) and what is wrong.
2. The checks, from Style.md and what the app already knows:
   - text readable at phone size (about 640 px wide; Style.md "Phones first");
   - a graphic, panel or caption over the speaker's face (Apple Vision face boxes, as
     Shorts and thumbnails use);
   - a Short's text outside YouTube's clear area, or under the like/share rail;
   - captions over a graphic, or over the face;
   - the end screen's boxes outside YouTube's area (exists);
   - a Must item in `Files/Blur notes.md` not hidden for its time range;
   - the thumbnail's phone check and information gap (exist).
3. The Agents Manual makes it a rule: after an edit, run `check`, fix every Must, run it
   again, then show the owner the sheet. Video.md records the last check.
4. In the app: **Check** in Studio's tool bar lists the findings; a click goes to the
   time.

**Tests:** each check on a fixture that fails it and one that passes; the rule in the
Agents Manual.

## 3. Step 2: draw on the frame

**What the owner sees:** while watching, they pause, pick a pen, draw on the picture
(circle a word, an arrow to a corner) and type a short note. The mark sits on the timeline
like a marker. The agent reads it, fixes it and ticks it off.

**How:**

1. A **mark** on a recording: its edited time, the strokes (normalised to the picture, so
   they survive a crop), a note, who made it, and whether it is done. Project version 22.
2. Drawn in the player with a pen and an eraser; a mark is a flag on the ruler with a
   pen icon, and a click shows it over the frame again.
3. Agents: marks in the state; `yamvideoctl mark --id` gives the frame with the drawing on
   it; `resolveMark` ticks one off with a line on what was done; the owner can reopen it.
4. A mark on a Short is drawn in the Short's own picture and time.

**Tests:** marks survive cuts (they follow their footage like markers), saving and opening,
and undo; the frame with the drawing renders.

## 4. Step 3: a reference card

**What the owner sees:** they give a video they like the style of. Before planning, the
agent writes a short **reference card**: how long its shots are, how often it cuts, where
and how big its text is, its colours, its transitions, how its captions look. The plan
then says which of those to follow.

**How:**

1. The owner adds a reference file to the video folder's `Files/` (a download they are
   allowed to keep, or a screen recording of it). A reference is studied, never reused in
   a video.
2. `analyze --kind reference` measures it: shot lengths and cuts a minute (ffmpeg scene
   detection), a contact sheet, the text on screen with its size and place (Vision text
   recognition), the main colours, and the music's beats when it has music.
3. The card is written to `Files/Reference <name>.md` with the contact sheet beside it,
   and the plan (Agents Manual 4.16) reads it first. A style the owner likes from it can
   become a Style.md rule after their yes.

**Tests:** a fixture with known cuts and text gives the right shot lengths, cuts a minute
and text boxes.

## 5. Order

| Step | What | Status |
|---|---|---|
| 1 | Check before showing | Next |
| 2 | Draw on the frame | After step 1 |
| 3 | Reference card | After step 2 |

## 6. Questions for the start of each step

- **1:** Which findings are **Must** (block "done") and which are Ask? Should Export warn
  when a Must finding is open?
- **2:** Pen colours, and whether a mark can cover a span of time or only a moment.
- **3:** Only files the owner adds, or also a YouTube link (`yt-dlp`, for study only)?

## 7. Sources

- [Motion GVA](https://motion.so/gva) and its benchmark (read 2026-10-21)
- [Motion docs: credits](https://docs.motion.so/guides/credits),
  [Motion in Claude](https://docs.motion.so/guides/claude)
- [Mosaic research](https://mosaic.so/research),
  [seed round](https://mosaic.so/research/mosaic-seed-round-announcement),
  [Y Combinator page](https://www.ycombinator.com/companies/mosaic-2)
- [Motion legal](https://motion.so/legal)
