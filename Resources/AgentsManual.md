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

## 4. Recipes

### 4.1 First edit of a talking-head recording

1. Read `state.autoEdit.options`: the owner's model, language, cut style, captions and
   loudness.
2. Run `yamvideoctl autoedit --clip ID`. It transcribes if necessary, cuts pauses (and
   stumbles for the tight style), and sets captions and loudness in one undo step.
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
4. Plan layouts from the transcript and show the plan: `speaker` for the intro and the
   outro, `split` (side by side) where the speaker explains without the screen, and
   the base `screen` layout where the screen shows the point. Apply with
   `replaceLayouts`.
5. Screen zooms: `analyze --kind screenZooms`, keep the ones where the text on the
   screen matters, aim others by hand at that text, and apply with
   `replaceScreenZooms`. A level of 1.4 to 2 makes browser text sharp.

### 4.5 Zooms and graphics on the speaker

- `analyze --kind zooms` proposes push-ins from local activity. Pick the ones that help
  the point, and apply with `replaceZooms`.
- Graphics (`addGraphic`, `replaceGraphics`) are timed on what is said: read
  `transcript` to place them. The owner's style and accent are in
  `state.clips[].graphics.style`.

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
   - `background`: `white`, `solid` (dark), `dim`, `blur` or `frame`.
   - `place: "clear"`: the speaker moves clear of the title and the picture, so nothing
     overlaps. Use it with the `white` or `solid` background.
   - `outlineWidth`: the white outline round the speaker, 2 to 16 (3 is thin).
   - `image`: a picture under the title, for example logos or icons. Make it a
     transparent PNG.
   - `zoom`: the speaker's size, 1 to 1.6.
3. Look at each result. Make sure the face is clear, nothing overlaps, and the words
   read at YouTube's small search size.
4. Show the owner two or three versions. After a yes, save it: `thumbnail --save`, then
   `setPublishInfo` with `{thumbnail: savedPath, design: …}`.

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
  files).

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
4. Run the analysis again. Show the owner the plan (each brand, its time, where the badge
   sits) and frames from `preview --composed` and `preview --short`.
5. After a yes, apply the badges in one `apply` with a clear label (for example "Logo
   badges"), then save.

Where a badge sits: the app works it out from the layout at that moment. When the speaker
fills the frame, it goes beside the face; beside the bubble in the Screen layout; at the
foot of the speaker's panel side by side. In a Short it goes beside the face, inside
YouTube's clear area, with the logos only (the captions say the names). Badges in a Short's
part of the video show in the Short too. Do not set `props.spot`: the app writes it. Use
`transform` only to nudge a badge.

The owner can do the same in the app: Graphics section → Find Brands.

### 4.10 Export for YouTube

- Ask the owner first. Then `export --youtube --path FOLDER --clip ID`. It writes the
  MP4, the captions as an SRT, a 1280×720 thumbnail, the upload text and a JSON.
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
