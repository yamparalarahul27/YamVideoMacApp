# YamVideo Agents Manual

This manual is for every agent that edits a video with the owner in YamVideo: Claude,
Codex or another. Read it once at the start of a session. Then use the catalog
(`yamvideoctl catalog` or the `yamvideo_describe` tool) for the fields of each command.

YamVideo is a Mac video editor. The owner has a project open and edits it at the same
time as you. You edit through the app, never through its files. The app checks every
edit, and each edit becomes one undo step with your name on it.

## 1. Connect

- **MCP tools** (Claude Code, Codex): the `yamvideo_*` tools. The owner's Local agents
  panel copies the setup command.
- **Command line:** `build/yamvideoctl` in the YamVideo folder. Every command gives JSON.
  `yamvideoctl --help` lists the commands.
- **Start of a session:**
  1. Read this manual: `yamvideoctl manual` or `yamvideo_manual`.
  2. Read the project: `yamvideoctl state`. Keep its `sessionID`, `projectID` and
     `revision`.
  3. Read the channel's rules: `yamvideoctl style` (`yamvideo_get_style`). Follow them
     unless the owner says otherwise.
  4. Read the owner's choices in `state.autoEdit.options` and the recording's
     `publish` details, and the project's Why notes in `state.notes.why`.
  5. Read the video folder's `Files/Plan.md` when it has one (4.16). When the owner
     added recordings that have no plan, study them and write one first.

## 2. Rules

1. **Edit only with commands.** Send typed commands with `apply`. Do not change a
   `.yamvideo` file or the app's caches yourself.
2. **Plan against a revision.** Send the `revision` you read. If the reply is
   `revision_conflict`, the owner edited at the same time: read state again and make
   a new plan. Do not guess a revision.
3. **One plan, one undo step.** Put all commands of one approved plan in one `apply`,
   with a `label` the owner understands in the Undo menu (for example "Flow cuts and
   caption fixes"). To change your own step, undo it with its `transactionID` and apply
   again, so the history stays clean.
4. **Check before you apply.** Use `--dry-run` for a large batch.
5. **Show a plan before a big change.** For cuts, layouts, zooms, titles, thumbnails and
   other choices of taste, show the owner a plan with times (or a picture) and wait for
   a yes. Small fixes the owner asked for do not need a plan.
6. **Look at your work.** Use `preview --composed` before and after an edit. It shows
   the frame as the owner's Preview shows it. Use `thumbnail` to see a thumbnail.
7. **Ask before you save, export or replace a file.** `save` and `export` change files
   on the owner's Mac.
8. **Only the owner downloads.** Whisper models and HyperFrames are downloaded by the
   owner. If a reply says `unsupported_capability`, ask them.
9. **Do not move the owner's view.** Use `reveal` only when the owner asks, or to show
   them a result they asked for.
10. **Never post.** YamVideo does not sign in to, post to or read from YouTube,
    Instagram, X or LinkedIn, and you must not either, not even through a browser. The
    owner publishes by hand. You prepare everything for them.
11. **Write to the owner in simple English.** Use short sentences, one word for one
    thing, and the active voice (ASD-STE100 Simplified Technical English). Use the same
    style in labels, titles and app text you write.

## 3. Time

- **Edited seconds:** time on the timeline after cuts, moves and speed changes. Split
  points, zooms, layouts, graphics, captions, chapters and the thumbnail's frame use
  edited seconds.
- **Source seconds:** time in the recording file. Sections (`start`, `end`), trims and
  transcript words use source seconds. `transcript` gives each word's `editedStart`
  too.
- A cut moves everything after it. Zooms, effects, markers and layouts follow their
  footage, and a cut that removes their footage removes them (the reply lists them).
- **Gaps:** the owner's timeline can leave space where a section was deleted, trimmed or
  moved, so the rest stays in place while they cut. A section's `gapBefore` is that space
  in seconds. Gaps are only on the timeline: edited seconds, playback and exports have no
  gaps. See 4.18.

## 4. Recipes

### 4.1 First edit of a talking-head recording

1. Read `state.autoEdit.options`: the owner's model, language, cut style, captions and
   loudness.
2. Run `yamvideoctl autoedit --clip ID`. It transcribes if necessary, cuts pauses (and
   stumbles for the tight style), and sets captions and loudness in one undo step.
   Tight keeps a longer breath where the transcript ends a sentence (0.40 s) or a
   clause (0.30 s), so transcribe before you cut. Every cut's sound fades over 12 ms.
   With the review style, it cuts nothing and gives the proposed cuts to show the owner.
3. If whisper is not on the Mac, transcribe another way and use `importTranscript` with
   `{model, language, words: [{text, start, end}]}` in source seconds.

### 4.2 Cuts that sound clean

- Whisper word times are often 0.1–0.3 s late. A cut at a word's end time can clip the
  end of the word.
- Put each cut edge in quiet audio: below about −40 dB for 20 ms or more. Use
  `analyze --kind silence` for the quiet parts.
- A word said twice is not always a mistake. Listen to the sentence (or read the words
  round it) before you cut a repeat.
- For flow cuts (a side story, a repeated part, a preview of a later part), show the
  owner each cut with its words and times first.
- Apply the cuts as one `replaceSections`, or as `deleteSection` and `trimSection`
  commands in one `apply`.

### 4.3 Captions

- Captions come from the transcript, or from a caption file (`setSubtitles`).
- If a caption leaves out a word, the word's time is often wrong. Give the word a time
  inside its sound, keep all words in the order they are spoken, and `importTranscript`
  again.
- Fix names in the transcript (product names, people, sites) so the captions spell
  them right.

### 4.4 A screen recording with the speaker

1. `setScreen` with the screen recording's path and `offset` (the screen's time at the
   speaker's source time 0). Do not trust the file times: the clocks of a camera and a
   Mac can differ by many seconds.
2. Find the offset from a moment that both show: for example the speaker says "click on
   it" and the screen shows the click. Check it with `preview --composed` at a second
   moment.
3. `updateScreen` with a `crop` to remove a dark window border, and the bubble
   (`corner`, `size`, `shape` circle or rounded).
   - The bubble can move for one part. When the screen shows something important
     under the bubble's corner (a menu, a button, a code line), give that part a
     `screen` layout with its own `bubble`, for example `{"corner": "topLeft"}`. Keys
     that you leave out follow the screen's bubble. The bubble glides to its new place
     over 0.4 s.
   - After you move the bubble, read `state.clips[].screen.layouts[].bubbleBox` and
     check that no graphic in that part covers it. Check a frame of the glide with
     `preview --composed`.
4. Plan layouts from the transcript and show the plan: `speaker` for the intro and the
   outro, `split` (side by side) where the speaker explains without the screen, and
   the base `screen` layout where the screen shows the point. Apply with
   `replaceLayouts`.
   - `ink` is for a drawing recorded on a dark canvas (for example YamDraw on an iPad):
     the speaker moves to the right at full size, and only the drawing's bright lines
     show on the left, over a dark shade. Set the screen's `crop` to the part of the
     canvas where the lines are, so they show large. Check a frame with
     `preview --composed`: the lines must be clear, and the face must not be under them.
5. Screen zooms: `analyze --kind screenZooms`, keep the ones where the text on the
   screen matters, aim others by hand at that text, and apply with
   `replaceScreenZooms`. A level of 1.4 to 2 makes browser text sharp.
6. Keep the face clear. No graphic may cover the bubble. In the Screen layout the app
   moves each column card (name plate, title card, link, feature list, end card) clear of
   the bubble: below a top bubble, above a bottom bubble, or beside the bubble when there
   is no room. A graphic with its own `transform` stays where the transform puts it. Do
   not set `props.clear`: the app writes it.
7. Check the bubble each time you move the bubble, change the layouts, or add or move
   graphics. Read `state.clips[].screen.overBubble`. Each item is a graphic and a place
   of the bubble that it covers (a layout part can move the bubble), with `graphicID`,
   `kind`, `at` (the first time the bubble shows at that place with the graphic),
   `rect` and `bubble` (design pixels of the 1920×1080 frame) and `why`. The list must be
   empty before you show frames to the owner. For each item:
   - `transform`: give the graphic a `transform` that keeps `rect` clear of `bubble`, or
     set the transform to x 0, y 0, scale 1, so the app places it.
   - `noRoom`: make the card smaller (`transform` scale) or give it less text.
   - `otherBubble`: a layout part moves the bubble while the card shows. The app keeps
     the card clear of the bubble that shows when the card is fully in. Move the card so
     it starts and ends in one part, or give it a `transform` clear of both bubbles.
   - `panel`: the app does not move panels. Move the panel to a time with a different
     layout, or set the bubble to a different corner.
   - `badge`: remove the logo badge's `transform`.
   When `overBubble` is missing, no graphic shows with the bubble, or the app could not
   measure the graphics. Then look at a frame from `preview --composed` to be sure.

### 4.5 Zooms and graphics on the speaker

- `analyze --kind zooms` proposes push-ins from local activity. Pick the ones that help
  the point, and apply with `replaceZooms`.
- Graphics (`addGraphic`, `replaceGraphics`) are timed on what is said: read
  `transcript` to place them. The owner's style and accent are in
  `state.clips[].graphics.style`.
- Most viewers watch on a phone. Look at frames from `preview --composed` scaled to
  about 640 px wide: every text must be easy to read there. If it is small, set the
  style's `size` (`setGraphicsStyle`, 1 to 1.5; 1.3 to 1.4 suits a phone) before you
  scale graphics one by one. Cards grow to the left and panels grow half as much, so
  check that no card covers the speaker's face. With a screen recording, read
  `state.clips[].screen.overBubble` (4.4, step 7). Read the owner's Style.md too: it can
  have a rule about this.
- Two graphics cover the whole picture, for design videos that move from part to part:
  - `kineticText`: a short phrase in big words, each on the time it is spoken. Give
    `words: "transcript"` and the app takes the words said over its time. Keep it to
    a phrase of 1–8 words that carries the point, and 1.5–4 s.
  - `sectionCard`: the title of the next part over a seek bar that shows how far into
    the video it starts. Put one at each part's first sentence, for 2–3 s, and use the
    chapter's words for the title.
  Nothing else may show with them; leave gaps round them for other graphics.
- The Paper look (`look: "paper"`, for the style or for one graphic) puts the card kinds
  (`namePlate`, `titleCard`, `sectionCard`, `panelTitle`) on an off-white card with a strip
  of tape in the accent's colours. The title is in a heavy serif and `detail` is an italic
  line. Other kinds keep their look. A Paper card can have a `label`: a tilted sticker in
  handwriting under the card, one line of 32 characters or fewer, for example
  "most powerful feature". The eyebrow (`kicker`) is drawn in a darker tone of the accent,
  so it reads on the paper. Use the look only when the owner asks for it or their Style.md
  says so. Check the cards at about 640 px wide, as for every graphic.
- A `link` card is a browser bar: a pointer clicks the address field and the address types
  in. Give `image` (a screenshot of that page, an absolute path) and the card about 7 s, so
  the page loads in a window under the bar. Put it on the side the owner faces (move it
  with `transform`), clear of the face. Write the label (`kicker`) as an action, for example
  "Link in the description".

### 4.6 Title, description, chapters and tags

1. Read the transcript and write chapters at the first word of each part (edited
   seconds, whole seconds). YouTube needs the first chapter at 0:00, at least 3
   chapters, and 10 s or more for each.
2. Write the title (100 characters or fewer), the description and the tags (500
   characters or fewer as YouTube counts them). Use the owner's own words for what the
   video is about: ask if you are not sure.
3. Show all of it to the owner before you set it.
4. Set it with `setPublishInfo` (`title`, `description`, `tags`, `chapters`,
   `category`, `language`). Keep the chapters in `chapters`, not in the description
   text: Export for YouTube adds them to the end of the description, one per line, and
   YouTube makes its chapters from them.
5. Read `state.clips[].publishIssues` and fix each blocking issue.

### 4.7 Thumbnail

1. Find the best frames: `analyze --kind thumbnailFrames --clip ID` (then
   `job ID --wait`). The result gives moments where the speaker smiles, looks at the
   camera and has the eyes open, best first, each with its edited `time` and scores. It
   also gives `sheet`, a PNG of the faces: look at it. A recording with a screen uses
   the speaker's own picture at every moment.
2. Try designs without storing them: a `thumbnail` request with `design` keys (raw
   `request`). Useful keys:
   - `time`: a suggested frame.
   - `title`: up to 3 lines; put the key words between asterisks.
   - `highlight: true`: the words between asterisks get a band of the accent colour.
   - `background`: `white`, `solid` (dark), `dim`, `blur`, `frame`, `frost` (the
     whole frame, with a white blurred shade on the title side, as in the Ink layout) or
     `shade` (the same with a dark shade: the speaker's own room behind them is near
     black too, so only the cut-out speaker is bright and lines up with the room).
   - `place: "clear"`: the speaker moves clear of the title and the picture, so nothing
     overlaps. Use it with the `white`, `solid`, `frost` or `shade` background.
   - `vivid`: 1 to 1.4, stronger colours on the speaker alone (1 is as recorded).
   - `accentFont: "serif"`: the words between asterisks in an italic serif (Apple's New
     York), against the bold sans of the other words. Use it on one or two words.
   - `outlineWidth`: the white outline round the speaker, 2 to 16 (3 is thin).
   - `image`: a picture under the title, for example logos or icons. Make it a
     transparent PNG.
   - `imageSize`: the picture's size, 1 to 1.6 times its usual size (at most 520×340
     pixels of the 1920×1080 frame). A larger picture makes the title smaller.
   - `zoom`: the speaker's size, 1 to 1.6.
3. Look at each result. Make sure the face is clear and nothing overlaps. Then add
   `check: true` (or `--check`) to see it on a phone: `check.findings` says what does
   not read in 0.5 s at the size of the home feed and of the search list (letters too
   small, too many words, low contrast, a face too small), and `check.phone` is a PNG of
   both sizes. Fix each finding with level `fails` before you show the owner.
4. Make the thumbnail and the title work together. The title says what the video is; the
   thumbnail adds what the title does not say: the result, a number, a surprise or a
   question. A finding of kind `title` says the thumbnail repeats the title;
   `check.gap` gives the repeated words and phrases and the words the thumbnail adds. To
   try a new video title without storing it, add `videoTitle` (`--video-title`).
5. Check the eye path: `check.path` lists where the eye goes, in order (the face, then
   the words by size, contrast and colour). The words between asterisks must be 1st or
   2nd; a finding of kind `eyePath` says when they are not. Make them bigger or clearer
   (`highlight: true`), or make the other words smaller.
6. Show the owner two or three versions. After a yes, save it: `thumbnail --save`, then
   `setPublishInfo` with `{thumbnail: savedPath, design: …}` (and `title`, if it changed).
7. For YouTube's Test & Compare (two or three thumbnails YouTube tries on viewers): set
   versions B and C with `setPublishInfo` `{test: {versions: [B, C]}}` (A is `design`).
   Save each with `thumbnail --version A --save` (then B, C), and store the paths with
   `{test: {images: [A, B, C]}}`. Export for YouTube then writes "… thumbnail A.jpg" and
   the others, and the text file says where to upload them. When the owner knows the
   result, `{test: {winner: 1}}` marks B: its image becomes the thumbnail. Write the result
   into the project's idea in the Library (`libraryApply`, the idea's notes), so later
   videos can learn from it.

### 4.8 Shorts

- Pick parts of 30–60 s that make one point from start to end. Start and end them at
  the edges of sentences (read `transcript`), and show the owner the plan with times.
- `addShort` with `window: "speaker"`. Give it its own title, description and tags.
- For a recording with a screen recording, set `screen: "top"`: the screen goes across
  the top, the speaker below, and the captions between them. Where the recording's
  layout shows only the speaker, the Short shows only the speaker.
- Shorts have their own caption setting (`setExportSettings` with `shortCaptions`). By
  default they burn captions in whenever the video has captions, also when the long
  video uploads an SRT. Do not change the long video's `captions` for a Short.
- Check each Short with `preview --short` at a few times, and show the owner frames
  before you export. Export it with `export --short` (with `--youtube` for the upload
  files). In the footage folder, the `--path` is the video's `Edited/Shorts/` (4.14).

### 4.9 Brand logos

When the speaker names a brand (Figma, Claude, an app), a logo badge can show the brand's
logo next to the speaker for about 2 seconds. The app finds the names and places the
badges; you choose with the owner.

1. Fix brand names in the transcript first (section 4.3), so the app can find them.
2. Run `yamvideoctl analyze --kind logos --clip ID` (then `job ID --wait`). The result
   gives:
   - `mentions`: each name, its words and times. `source` is `library` (the owner has a
     logo), `known` (a brand of the app's list) or `guess` (a word shaped like a name,
     such as a capital inside a sentence). A guess can be a person or a common word:
     check it.
   - `missing`: the names without a logo yet.
   - `suggestions`: a `logoBadge` graphic for each name with a logo, ready for
     `addGraphic`. Names said within 1.2 s share one badge. A logo said again within
     60 s gets no new badge (`--minimum SECONDS` changes this). A badge ends before a
     layout change, so it does not float after the speaker moves.
3. For each missing name, ask the owner for the logo, or draw a clear, simple one that
   you are sure of (a transparent PNG or an SVG). An app's own icon on the Mac
   (`/Applications/NAME.app`) is a good source. Do not invent a logo: tell the owner which
   brands you could not draw and ask for those files. Keep each logo with
   `yamvideoctl setlogo --name BRAND --path FILE [--words "a, b"]`, and show the owner
   each logo you keep. The library is kept for every project, so the next video uses it
   again. `yamvideoctl logos` lists it.
   A wide logo is fine: keep a wordmark (such as CoinDCX, 496×149) as the owner gives
   it. Do not put it on a square background. The badge draws each logo 100 px tall
   (96 px in a Short) and as wide as its shape asks, up to 3 times its height, so a
   wordmark reads on a phone.
4. Run the analysis again. Show the owner the plan (each brand, its time, where the badge
   sits) and frames from `preview --composed` and `preview --short`.
5. After a yes, apply the badges in one `apply` with a clear label (for example "Logo
   badges"), then save.

The label: each suggested logo has a `label`, the brand's name, next to the logo. Remove
the `label` from a logo that already shows the name (a wordmark, or an icon with the name
in it), so the name does not show two times. Keep the label for a logo that does not show
the name (an icon or a symbol alone). Remove it from the suggestion before `addGraphic`,
or give the badge's props again with `updateGraphic`. A Short shows the logos without
labels in all cases.

Where a badge sits: the app works it out from the layout at that moment. When the speaker
fills the frame, it goes beside the face; beside the bubble in the Screen layout; at the
foot of the speaker's panel side by side. In a Short it goes beside the face, inside
YouTube's clear area, with the logos only (the captions say the names). When the logos
side by side are wider than the safe area (or the clear area of a Short), the app puts
them one above the other. Badges in a Short's part of the video show in the Short too.
Do not set `props.spot`: the app writes it. Use `transform` only to nudge a badge.

The owner can do the same in the app: Graphics section → Find Brands.

### 4.10 Export for YouTube

- Ask the owner first. Then `export --youtube --path FOLDER --clip ID`. It writes the
  MP4, the captions as an SRT, a 1280×720 thumbnail, the upload text and a JSON. In the
  footage folder, FOLDER is the video's `Edited/` (4.14).
- YouTube's upload API cannot set end screen elements. The export says which element
  goes in which box, for YouTube Studio.

### 4.11 Ideas

The Library keeps the owner's ideas, apart from any project. Each idea has a title,
notes, a topic, links and images. A project made from an idea is linked to it, and the
idea then shows as *In production*.

1. Read the Library: `yamvideoctl library` (`yamvideo_get_library`). Keep its
   `revision`: it is the Library's own, not the project's.
2. Write ideas in the owner's own words. Show the owner what you will add or change,
   and wait for a yes.
3. Use a topic from `topics` when one fits, so ideas group together. Make a new topic
   only for a new subject.
4. Apply with `yamvideoctl library apply --file EDITS.json --revision N`
   (`yamvideo_apply_library`): `addIdea`, `updateIdea`, `addIdeaImages`,
   `linkProject`. Look at an idea's images at their `path`.
5. Ask before `removeIdea`. To change your own step, undo it with
   `yamvideoctl library undo --transaction ID --revision N`.
6. `state.idea` says which idea the open project was made from. Read its notes before
   you write the title, description and chapters (4.6), so they say what the owner
   planned.
7. `reveal --idea ID` shows an idea on the Library page.

**Past videos.** Videos the owner already made come in from their files; nothing is
copied.

1. `yamvideoctl scan --path FOLDER` (`yamvideo_scan_folder`) lists the projects and
   Export for YouTube files there, and what the Library already holds. Show the owner
   the list and ask which to add.
2. Add them with `importVideos {paths}`. Each project becomes an item (stage *Ready*
   when something was exported) with its long video and Shorts in `videos`.
3. When the owner tells you where a video is published, record it with
   `addPost {ideaID, videoID, link}`. The item then shows as *Posted*. Never open, sign
   in to or read the platform to find a link yourself.
4. A video's export (`videos[].exports[].json`) has the title, description and tags it
   went up with. Read them when you write for a new post, to keep the owner's voice.

### 4.11b The release calendar

The owner plans when each video goes out and where, and tells you the plan in words
("Part 1's Shorts: one every two days from Monday, all four platforms, 7 pm").

1. Read the Library and find the idea and each video's `videos[].id`.
2. For each video, `planRelease {ideaID, videoID, day: "2026-10-19", clock: "19:00",
   platforms: [...]}`. Left out, `platforms` is all four (youtube, instagram, x,
   linkedin) and `clock` is any time that day. Give `ownDays {"linkedin": "2026-10-20"}`
   when one platform goes out on another day. Send one command per video in one
   `libraryApply`, so it is one undo step.
3. `unplanRelease` puts a video back in *Not planned*. Planning never posts anything:
   the owner posts by hand and gives you the links for `addPost`.
4. `library` shows each video's `plan`; the owner sees it on the Calendar (⌘4).

### 4.12 Style.md, project notes and Video.md

- **Style.md** holds the channel's taste as rules, by kind of video. When the owner
  gives feedback about taste ("text is coming over my face"), propose a rule in one line
  and where it came from. After a yes, add it: `addStyleRule {section, rule, source}`
  with `yamvideoctl library apply`. Never add a rule the owner did not approve.
- **Project notes** say why this video is edited the way it is. After each choice the
  owner approves, add one line with `addProjectNote {note}` (with `yamvideoctl apply`):
  the decision and its reason.
- **Video.md** is written next to the saved project at every save and export: what the
  video is, the edit, each Short, the Why notes and the history of changes
  (`state.notes.videoNotes` is its path). Read past Video.md files to match how the
  owner's earlier videos were made. Do not edit Video.md; it is rewritten.

### 4.13 Switch a change off

- The owner can switch the crop, colour, blur areas, zooms, graphics or music of a
  recording off in the inspector. Off keeps the change in the project but leaves it out of the
  player and every export. `state.clips[].switchedOff` lists what is off.
- To compare, send `setChange {clipID, change, on: false}`, then `on: true` to bring it
  back. Each is one undo step. Do not delete a change the owner only wants to see
  without; switch it off.
- Before an export, check `switchedOff`. If something is off that the owner did not
  ask for, say so first.

### 4.14 The footage folder

All footage is in `~/Desktop/Yamparala Media`, one folder for each video
(`docs/footage-layout.md` in the YamVideo source has the full rule):

```
YYYY-MM-DD Title/          the date of the first recording
  Name.yamvideo            the project, and "Name Video.md" next to it
  Recorded/                recordings as recorded (Recorded/Joined/ for joined takes)
  Edited/                  Export for YouTube files; Shorts in Edited/Shorts/
  Files/                   thumbnails, saved frames, graphics images, work files
```

`Inbox/` is for new recordings, `Shared Assets/` for images that more than one video uses,
and `Other/` for recordings that are not for a video. With no output folder set, the app
suggests `Edited/` for exports and saves thumbnails in `Files/`.

When the owner says "I added a recording", sort each new file in `Inbox/` or at the top
of the folder:

1. Find its date (`ffprobe`, `format_tags=creation_time`) and its topic (look at 3 or 4
   frames). For a DJI clip, use the time in its file name: its `creation_time` can carry
   a wrong time zone.
2. Move it into `Recorded/` of the video folder with the same topic and day. If there is
   none, make `YYYY-MM-DD Title/` with `Recorded/`, `Edited/` and `Files/`. Keep the file
   name. A YamDraw export (`recording.mp4`, `frame-NN.png`, `session.json`) goes together
   into `Recorded/YamDraw <topic>/`, so the next export cannot replace it.
3. Move DJI `.LRF` files (camera previews) to the Trash. Never use `rm`.
4. Look for personal information in each screen recording and screenshot (names, PAN,
   Aadhaar, signatures, email addresses, phone numbers, bank details, home area). Sample a
   frame every few seconds. Write each item with its time range in `Files/Blur notes.md`:
   **Must** for ID numbers, signatures and contact details, Ask for the rest.
5. Add one line for each file to `Files/Recordings.md`: day, length, what it shows, and
   which video or Short it is for. Read it before the first edit of a video.
6. Tell the owner where each file went. Ask when the topic is not clear.
7. Study the new recordings and plan their videos (4.16).

Before an export, read `Files/Blur notes.md` and hide each Must item with a Blur area:
`addBlurArea {clipID, rect, start, end}` hides the rectangle from `start` to `end`. The
times are source seconds of the recording, the same times as in the notes, so cuts and
speed changes do not move them. Without `start` and `end` the area covers the whole
recording. `updateBlurArea {areaID, start?, end?, whole?}` changes the range. Cut the part
when the video does not need it. Use a Blur effect (`addBlurEffect`) only when the whole
picture must go soft. Look at a frame inside each range with `preview --composed`, and
show the owner one frame of each item.

Do not rename or move a recording that a project uses: the project keeps its full path.
If a move is necessary, send `relinkMedia` for it.

Each Mac keeps a list of its video folders in the YamVideo source, `docs/channel/macs/<Mac>.json`
(this Mac's name is in the Library's Macs menu). Read the other lists to tell the owner
which Mac has a video that is not here. The app writes these files; do not edit them.

### 4.15 Background music

The owner chooses the music for each video. Add music only when the owner asks, and only
a track the owner gave or named.

1. Ask the owner for the track and its licence. Use only a licence that permits a
   monetised YouTube video: the YouTube Audio Library, CC0, CC BY (with its credit line),
   Pixabay, the owner's own music, or a model whose licence permits commercial use. Do not
   use CC BY-NC, CC BY-ND or CC BY-SA: Export for YouTube refuses them.
2. Send `addMusic {clipID, path, start?, end?, music: {level?, credit: {licence, title,
   artist, source, line}}}`. The app measures the file and the voice, so `level` is LU
   under the voice for any track. -20 (the default) is a quiet bed for an educational
   video; do not go above -12 under speech.
3. The music is on the edited timeline. Jump cuts do not cut it, and a piece follows the
   frame where it starts when the edit changes. `end` null plays to the end of the video.
   Pieces may touch but not overlap.
4. Read `state.clips[].music`: each piece with its `gain` (dB) and its `plays` (a loop plays
   the file again with a 2 s crossfade). `missing: true` means the file moved.
5. Change a piece with `updateMusic {clipID, musicID, music: {…}}`; only the keys given
   change. `removeMusic` removes one. `setChange` with `music` switches all of it off.
6. The duck: new music goes down under speech and up in pauses. Under speech it is at its
   level. Before the first word, in gaps of 1.5 s or more and after the last word, it is
   `lift` dB higher (default 8). Speech comes from the transcript, so transcribe first; with
   no transcript the app uses the sound levels. Change it for all the recording's music with
   `setMusicDuck {clipID, music: {duck?, lift?}}`. Keep level + lift at -10 LU or lower.
7. Check the mix without ears: `analyze --kind music` gives the runs of speech, the gain
   points (`lift` in dB at each time) and the loudness of the voice with the music. The
   preview and the export play the same points.
8. Exports mix the music under the voice. With Loudness on, the export normalises the mix
   to -14 LUFS. Export for YouTube writes each credit line at the end of the description.

### 4.16 Study new footage and plan the edit

When the owner adds recordings, study them before any edit, write a plan for each video
and ask the owner the questions that block it. Do not edit until the owner approves the
plan. Sort the files first (4.14).

When the owner names a video they like as a reference, read its notes in the YamVideo
source, `docs/channel/references/`, before you plan, and say in the plan which parts you
follow. A reference is studied, never reused: no frame, logo, music or words from it.

1. **Read** `Files/Recordings.md` and `Files/Blur notes.md` of each video folder.
2. **Transcribe each headshot**: `yamvideoctl transcribe`, or local whisper with a prompt
   of the video's names, written with punctuation. Check the names after: a prompt can
   pull a similar word to a name. Save the words, the captions and a list of timed
   sentences in `Files/Transcripts/`, so the edit can use `importTranscript` later.
   Transcribe a screen recording too when it has the owner's voice (an iPad or iPhone
   recording often has it).
3. **Find which recordings were made together.** Do not trust the file times alone:
   - A DJI file name (`DJI_YYYYMMDDhhmmss`) has the camera's local time. Its
     `creation_time` can carry a wrong time zone. Apple file names (`Screen Recording …
     at 7.24.17 PM`, `ScreenRecording_MM-DD-YYYY HH-MM-SS`) and YamDraw's
     `session.json` `startedAt` are correct.
   - Two recordings with close start times and close lengths were made together. The
     screen then gets one `offset` (4.4).
   - Confirm each offset by content: a click, a scroll or a word that both show. A screen
     recorded at another time needs a placement table (which part of the screen shows
     over which sentence).
4. **Look at the screen recordings.** Sample a frame every 2–4 s where the screen
   changes (contact sheets with the time on each frame). Note what each part shows, the
   UI details the owner talks about, and new personal information (4.14 step 4).
5. **Understand the content:** the main point in the owner's words, the story, the
   strong parts, and the weak, repeated or off-topic parts.
6. **Write `Files/Plan.md`** in the video folder. Use these sections:
   1. Summary: the main point, the target length (do not pad), the layout mix, the
      effort, the most important choices.
   2. What the recordings show: the story by source time; what each screen part shows.
   3. Structure: chapters with source times and estimated edited times; a hook in the
      first 10 s; a clear end.
   4. Cuts: tight cuts, then flow cuts (repeats, fillers, restarts, side stories), each
      with its words and times; the length after each.
   5. Screen placement: the offset and how you found it, or the placement table; the crop.
   6. Layouts and zooms: Speaker, Screen, Side by side or Ink for each part; zoom levels
      and aims for the UI details the owner talks about.
   7. Motion graphics: section cards, kinetic text, callouts, logo badges, name plate,
      link card, end screen; check that each text reads at 640 px wide.
   8. Personal information: each Must item with its rect and range, or the cut that
      removes it; each Ask item as a question. A blur area covers only the main
      recording, not a screen recording in a layout, so cut a Must part that the screen
      shows.
   9. Shorts: 2–4 candidates with times, title, description, tags and the hook.
   10. Publish draft: title options, description, chapters, tags, two thumbnail ideas in
       the owner's style (Style.md).
   11. New app features the plan needs (describe them; do not build them).
   12. Open questions: each one marked **Blocks edit** or **Can wait**.
   Give times in source seconds of the headshot. Write all text in simple English
   (rule 11).
7. **Library:** give each video an idea (`addIdea`, 4.11) with a short summary in its
   notes and the path of its `Plan.md`. A new idea is in stage *Idea*.
8. **Ask the owner.** Make one overview page (an HTML page, for example an Artifact) with
   the plans side by side, a recommended order to edit them, and the questions that block
   each one. Then ask the owner to approve or change each plan. After a yes, edit as in
   4.1–4.10, and add each answer as a project note (4.12).

### 4.17 Plan the releases

After the plans, plan when each long video and each Short goes out. Plan at least two
months ahead. With more videos, plan further, so that each video has a day.

1. Read the Library (4.11) and the plans: the long videos and the Shorts each plan
   proposes, and the order the owner approved.
2. Read the rhythm in `library.calendar.rhythm`: the long video's day and how many weeks
   apart, the Shorts' days, the time and how far ahead to plan. `rhythmSet: false` means
   it is still the default from Style.md; confirm it with the owner the first time, and
   save their answer with `setRhythm`. Do not invent a rhythm.
   `library.calendar.emptySlots` lists the rhythm's days with nothing planned, and
   `library.calendar.missed` the past releases not posted on a platform yet.
3. Propose the days as a table: each long video first, then its Shorts on the days after
   it, so a Short sends viewers to its long video. Keep a series in order (Part 1 before
   Part 2). Leave a video that is blocked by a question in *Not planned*.
4. After a yes, send one `planRelease` for each video in one `libraryApply` (4.11b). The
   owner sees the plan on the Calendar (⌘4).
5. When the owner adds new footage, study it (4.16) and plan its videos into the empty
   slots first. Do not move a planned day without the owner's yes.
6. A missed release is the owner's to post. Do not post; when the owner gives the link,
   record it with `addPost`.

### 4.18 Gaps on the timeline

The owner cuts with gaps: Delete (⌘⌫) and the trim handles leave the space a section
used, so nothing else on the row moves. They join the sections with Close Gaps (⌥⌘G) when
they are done. ⇧⌘⌫ deletes and closes at once.

1. Read `gapBefore` in `state.clips[].sections[]`. A section without it has no space in
   front of it.
2. Gaps change no time you send or read: zooms, graphics, captions, Shorts and exports use
   edited seconds, which have no gaps. Export with gaps open; the video is joined.
3. `deleteSection` closes up, as ⇧⌘⌫ does. To leave the space as ⌘⌫ does, send `setGap`
   for the next section in the same `apply`, with its old `gapBefore` plus the deleted
   section's `editedDuration`.
4. `closeGaps {clipID}` joins every section; with `sectionID`, only the gap in front of
   it. Do not close gaps the owner left unless they ask: they may still be cutting.

### 4.19 Sound effects

The owner wants a fast, informative feel: a short sound at moments of the graphics'
motion (a whoosh when a section card comes in, a tap for each letter a link card types).
The graphics engine gives each cue's time, so a sound moves with its graphic.

1. Read `yamvideoctl sounds`: the owner's sound library (each sound's name, loudness, peak
   and licence) and the cues with their default sounds and levels. A cue whose sound is not
   in the library is silent.
2. Add a sound only from a file the owner gave or named: `setSound {name, path, credit}`
   (6 s or less). Set `credit.licence`. The owner's "Boring Sound Kit" has no licence file;
   the owner said to use it, so give it the licence `other` (Export for YouTube warns).
3. Turn the sounds on for a recording with `setSounds {clipID, sounds: {on: true}}`. The
   first time, the app measures the voice. Choose another sound for a cue with
   `cues: {"link.key": "button-2"}`, `"off"` for none, or null for its default.
4. Each cue sits its level in LU under the voice (from the sound's loudest 400 ms) and
   never peaks above -12 dBFS. `level` moves all of them (-12 to +6 dB, default 0).
5. Read `state.clips[].sounds.cues`: each cue's time, graphic, sound and gain, and
   `missing` when its sound is not in the library. Graphics switched off have no sounds.
6. The export and the preview mix the cues with the voice and the music; the duck does not
   move them. Export for YouTube stops CC BY-NC, CC BY-ND and CC BY-SA sounds and writes
   each credit line in the description.

## 5. Problems

- **`revision_conflict`:** read state again and make a new plan. For a Library command,
  read the Library again.
- **`agents_paused`:** the owner paused agents. Wait, or ask them.
- **A preview or thumbnail request times out after the app was rebuilt:** macOS asks the
  owner again for access to the Desktop folder. Ask the owner to click Allow.
- **No face found:** pick a frame where the speaker faces the camera, or set
  `cutout: false`.

## 6. More detail

- `yamvideoctl catalog` (`yamvideo_describe`): every command and request, with each
  field's type, unit, range, default and an example.
- `Tools/YamVideoCLI/README.md` and `Tools/AgentBridge/README.md` in the YamVideo source.
