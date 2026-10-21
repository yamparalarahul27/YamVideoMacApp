# Distribution — implementation plan

**Updated:** 2026-10-17. **Status:** phase 1 (the Library, the sidebar and Ideas) is
merged (PR #33, section 11), and so are phase 1b, past videos (PR #34, section 12), and
phase 1c, Style.md and Video.md (PR #35, section 13). Phase 2 has started: the platforms'
rules are checked, the owner's answers are in, and the design and mock-ups are agreed
(section 14). Nothing of phase 2 is built yet. **Next up** is section 14.6.

## 1. Goal

Today YamVideo is an editor: it ends at the export and the upload text for YouTube. The
owner wants it to cover distribution, from an idea to knowing which posts worked, in one
app with three linked modules:

1. **Social Media Platforms**: YouTube, Instagram, X and LinkedIn, the owner's own
   accounts only.
2. **Scheduling & Analytics**: a place for ideas, a calendar of what goes out when, and
   how each post performs.
3. **Editing & Production**: today's editor, Shorts and Publish sheet.

## 2. Decisions (the owner's answers, 2026-10-16)

1. **No APIs, no automation.** The app never signs in to a platform, never posts, never
   reads a platform's data, and never drives a browser. Platforms flag bot activity, and
   the owner wants no API costs. The owner uploads and publishes by hand. The app may open
   a platform's upload page in the default browser: a link, nothing more.
2. **Everything else is local and AI assisted.** AI comes in two ways:
   - **Claude (or Codex) through the agent bridge**, for the bigger work: ideas, titles,
     captions for each platform, reading results. Every module is open to agents.
   - **Apple's on-device model** (FoundationModels, macOS 26 with Apple Intelligence on)
     inside the app for small jobs: hashtags, a caption shortened for X, an angle for an
     idea. Its buttons are hidden where it is not available (older macOS, or Apple
     Intelligence off). On 2026-10-16 it reported `appleIntelligenceNotEnabled` on the
     owner's Mac; they turn it on in System Settings → Apple Intelligence & Siri.
   - **Apple Vision text recognition** reads numbers from screenshots. It needs no Apple
     Intelligence.
3. **Videos only.** Every post is a long video or a Short made in the app. No text-only
   or image-only posts.
4. **The Library is on this Mac only**, in `~/Library/Application Support/YamVideo/Library/`,
   not in iCloud. `YAMVIDEO_LIBRARY_PATH` overrides it, so an isolated test instance keeps
   the owner's Library untouched.
5. **Numbers at day 1, 7 and 30** after posting, so posts are compared at the same age.
   The app reminds the owner on each day.
6. **Two numbers matter: views and watch time** (total watch time, and average view
   duration or retention where the platform shows it). X and LinkedIn barely show watch
   time, so their posts compare on views only.
7. **Three comparisons:** the same video on each platform, Shorts against long videos, and
   topics against each other.
8. **An idea holds** a title, text notes, links, images and a topic. No voice notes.
9. **Order:** the phases in section 7, one chat and one PR each.

## 3. The spine: a content item

Each idea is one **content item**. It moves through stages:

```
Idea → In production → Ready → Scheduled → Posted → Results at day 1, 7, 30
```

- An idea becomes a project with **Start a Project from This Idea**: a new project is
  created, saved where the owner chooses, and linked to the item.
- An item has **pieces**: the long video and each of its Shorts, by recording and Short ID.
- A piece has **posts**: one per platform it goes to. A post has a planned date and time,
  a status, the post's link once it is up, and its check-ins.
- A **check-in** is the numbers on day 1, 7 or 30, and where they came from (typed, a
  screenshot, or a platform's export file).

The stage is worked out from the data, never stored: no project is *Idea*; a project with
no post kit exported is *In production*; an exported kit is *Ready*; a planned date is
*Scheduled*; a link is *Posted*.

**Links are by ID.** A project is found by its `projectID` (`VideoProject.projectID`) and
its last known path. When the owner opens a project that was moved, the Library sees its
ID and updates the path. Recordings and Shorts already have stable UUIDs.

## 4. Data (a sketch; each phase settles its part)

```swift
struct Library: Codable {
    var version: Int
    var items: [ContentItem]
    var platforms: [PlatformProfile]       // phase 2
}
struct ContentItem: Codable, Identifiable {
    var id: UUID
    var title: String
    var notes: String
    var links: [URL]
    var images: [String]                   // file names in Library/Images, copied in
    var topic: String?
    var created: Date
    var project: ProjectLink?              // nil while it is an idea
    var pieces: [Piece]                    // phase 2
}
struct ProjectLink: Codable { var projectID: UUID; var path: String }
struct Piece: Codable, Identifiable {
    var id: UUID
    var recording: UUID
    var short: UUID?                       // nil is the long video
    var posts: [Post]
}
enum Platform: String, Codable, CaseIterable { case youtube, instagram, x, linkedin }
struct Post: Codable, Identifiable {
    var id: UUID
    var platform: Platform
    var planned: Date?                     // phase 3
    var exported: Date?
    var posted: Date?
    var link: URL?
    var checkIns: [CheckIn]                // phase 4
}
struct CheckIn: Codable {
    var day: Int                           // 1, 7 or 30
    var recorded: Date
    var views: Int
    var watchMinutes: Double?
    var averageViewSeconds: Double?
    var source: Source                     // typed, screenshot, file
}
```

The Library is one `Library.json` and an `Images/` folder, written atomically after every
change, as the recovery file is. Its edits get their own undo history and revision, so an
agent's edit against an out-of-date Library is refused, as project edits are.

**Where post kit text lives (proposed, settled in phase 2):** in the project, next to
`PublishInfo`, because it describes the video and Export writes it. The Library keeps
only when, where, the status, the link and the numbers, plus a copy of the title for the
calendar.

## 5. The app

- **A sidebar** on the left of the window: Ideas · Calendar · Studio · Results · Platforms.
  Studio is today's editor, unchanged, with its own toolbar. Each module appears in the
  sidebar when its phase lands.
- **Linked both ways.** An idea shows its project and opens it in Studio. Studio shows the
  idea the open project belongs to, with a button back to it. The calendar and results
  open the post's idea, project or Short.
- **Agents see it.** `reveal` can show an idea, a post or a day on the calendar, and the
  agent highlight works in every module.

## 6. Agents

Every phase follows the owner's rule for agent-friendly features: typed commands with
defaults and agent-chosen IDs, errors that say what is allowed, the module in agent state,
`reveal` and highlights, a way to see the result, and entries in `AgentCatalog.swift`.

- New request methods next to `state` and `apply`: `library` (the Library's state) and
  `libraryApply` (typed Library commands, against the Library's revision).
- `yamvideoctl library …` and matching MCP tools in `Tools/AgentBridge`.
- New Agents Manual recipes: ideas, captions for each platform, and reading results.

## 7. Phases

### Phase 1: the Library, the sidebar and Ideas

1. The Library store: file, atomic writes, undo, revision, `YAMVIDEO_LIBRARY_PATH`.
2. The sidebar with Ideas and Studio.
3. The Ideas page: items grouped by stage, a topic filter, and an editor for the title,
   notes, links, images (dropped or pasted, copied into the Library) and topic (an
   existing one or a new one).
4. Start a Project from This Idea, and the link back from Studio.
5. Agents: `library` state; `addIdea`, `updateIdea`, `removeIdea`, `linkProject`; catalog;
   manual recipe.
6. Tests: Library round trip, project links and relinking, agent commands.

### Phase 2: Platforms and post kits

1. Check each platform's current rules first (caption length, video length and shape,
   hashtags, file size), because they change. Record them with the date they were checked.
2. A profile per platform: its rules, the owner's handle, links and description footer,
   usual posting times, and the address of its upload page.
3. The Publish sheet gets a platform picker for each piece (the long video and each
   Short). YouTube's form stays as it is; Instagram, X and LinkedIn get a caption,
   hashtags, checks against their rules and a preview.
4. Export Post Kit: the video in the right shape and a text file per platform, in one
   folder. Copy buttons for every field, and Open Upload Page.
5. Pieces and posts in the Library, created when a kit is set up.
6. Agents: set a kit per platform, issues per platform in state.

### Phase 3: Calendar

1. Month and week views. Posts are placed on days and dragged between them. Posts with no
   date wait in a side list.
2. Reminders with macOS notifications: at the planned time, and on day 1, 7 and 30 after
   posting to add numbers.
3. Mark as Posted: paste the post's link; the date is now unless changed.
4. Agents: plan a post, move it, mark it posted; the calendar in state.

### Phase 4: Results

1. A check-in form for each post: views and watch time, typed in.
2. From a screenshot: drop or paste the platform's stats screen, Vision reads the text,
   the app fills in the numbers, and the owner confirms them.
3. From an export file: the CSV or Excel file a platform's analytics page gives. Rows are
   matched to posts by link, title and date, and the owner confirms them. Check at the
   start of the phase which exports each platform offers.
4. Comparisons with Swift Charts, at day 1, 7 or 30: the same video on each platform,
   Shorts against long videos, and topics.
5. Agents: record a check-in; results in state, so Claude can read and sum them up.
6. From a YouTube link (added 2026-10-21): views, likes and new comments read with
   `yt-dlp`, never signed in. Planned in [launch-templates.md](launch-templates.md),
   part A. The owner allowed this one kind of reading on 2026-10-21.

### Phase 5: in-app AI with Apple's model

1. One place that checks `SystemLanguageModel.default.availability` and hides the AI
   buttons when it is not available, saying why.
2. Small jobs: hashtags for a platform, a caption shortened to fit a platform, a few
   angles for an idea, a title rewritten. Each result is a suggestion the owner accepts or
   edits; nothing is set on its own.
3. Tests that run the model when it is available and skip the check when it is not.

## 8. Tests (`./test.sh`)

Each phase adds a feature to the suite, and new source files are listed in `test.sh`. The
suite already checks `AgentCatalog` against `WireCommand.types`; the Library commands get
the same check. The real-use check for each phase runs an isolated instance with
`YAMVIDEO_LIBRARY_PATH`, `YAMVIDEO_RECOVERY_PATH` and `YAMVIDEO_AGENT_BRIDGE_DIR` set, driven
by `yamvideoctl`.

## 9. Questions for the start of each phase

- Phase 1: Ideas as a list or as columns by stage? (Mock-ups first.) **Answered:** a list
  by stage with the editor always on the right (2026-10-16).
- Phase 2: confirm that post kit text lives in the project. **Answered:** yes, in the
  project, next to the YouTube text (2026-10-17). Section 14.2 has the other answers.
- Phase 3: at what time of day the check-in reminders come.
- Phase 4: which exports each platform offers today.

## 10. Status

| Phase | What | Status |
|---|---|---|
| 1 | Library, sidebar, Ideas | Merged (PR #33) |
| 1b | Past videos: scan a folder, the videos of an item, posts | Merged (PR #34) |
| 1c | Style.md, project notes and Video.md | Merged (PR #35) |
| 2 | Platforms and post kits | Rules checked, design and mock-ups agreed (section 14); not built |
| 3 | Calendar | Calendar and release tree built (section 15); reminders later |
| 4 | Results | Not started; YouTube numbers from a link planned (launch-templates.md, part A) |
| 5 | In-app AI | Not started |

## 11. Phase 1 as built

**Data.** `Sources/Library.swift`: `Library` (version 1, with a `revision` saved in the
file), `ContentItem`, `ProjectLink`, `ContentStage` (idea, inProduction), the rules
(title one line up to 200 characters, notes up to 20,000, topic up to 60, up to 50 http or
https links and 50 images), `LibraryCommand` and `LibraryReducer` (all or nothing). Times
are kept to the whole second so the file reads back equal. A topic that differs only in
case takes the existing spelling; a bare address gets `https://`.

**Storage.** `~/Library/Application Support/YamVideo/Library/Library.json` and `Images/`,
or `YAMVIDEO_LIBRARY_PATH`. Loaded in `applicationDidFinishLaunching`, not in
`AppModel.init`, so tests and the snapshot tool use their own folder, and nothing is written
before it is loaded. Written atomically after every change. A file that cannot be read is
moved aside as `Library (unreadable …).json`; images no idea uses are removed on load
(undo history does not outlive the app).

**The app.** `Sources/LibraryEditing.swift` and `Sources/IdeasView.swift`. A module
sidebar (Ideas, Studio; ⌘1, ⌘2; remembered), the Ideas page (list by stage with a topic
filter; the editor with title, topic and existing topics, notes, links, images dropped,
pasted or chosen, and the project), the Library's own undo history (typing in one field
is one step; ⌘Z on the Ideas page undoes the Library, after the text field's own undo),
New Idea (⌥⌘N), Start a Project from This Idea (save panel first, then a new project,
saved and linked), Link the Open Project, Open in Studio, Locate (the identity must
match), Unlink. Studio's toolbar shows the open project's idea and goes back to it.
Opening or saving a project moves its idea's link to the file's new place, in the undo
history too. The timeline keys and menu act only in Studio.

**Agents.** `Sources/LibraryAgents.swift`: methods `library`, `libraryApply`,
`libraryUndo`, `libraryRedo`; `reveal` with `idea`; `state.idea` and
`state.selection.module`/`idea`; events of kind `library` with the Library's revision.
Commands: `addIdea`, `updateIdea`, `removeIdea`, `addIdeaImages`, `removeIdeaImage`,
`linkProject` (a path, or the saved open project) and `unlinkProject`, in the catalog's
`libraryCommands`. Images are copied only after every command checks; a dry run copies
nothing. A retry is matched on the whole request with sorted keys, so a new yamvideoctl
process retrying is still recognised. `yamvideoctl library [apply|undo|redo]`, MCP tools
`yamvideo_get_library`, `yamvideo_apply_library`, `yamvideo_library_undo` and `_redo`,
and recipe 4.11 in the Agents Manual (plus rule 10: never post).

**Checks.** `./test.sh library` (61 checks; the whole suite is 1477). `Tools/Snapshot` renders the Ideas pages with
`YAMVIDEO_SNAPSHOT_ONLY=ideas` (16a–16e); the toolbar does not show in snapshots, as
before. The real-use check ran an isolated instance with `YAMVIDEO_LIBRARY_PATH` and drove
it with yamvideoctl: a dry run, two ideas with an image, a stale revision refused, reveal,
a saved project linked, `state.idea`, undo and redo, events, and the Library and link
intact after a relaunch.

**Left for later.** Hands-on clicks in the running app (typing, drag and drop, paste,
the save panel); the idea chip in Studio's toolbar can only be seen in the running app.

## 12. Phase 1b: past videos (2026-10-17)

The owner already had videos made and published before the Library: YamVideo projects
and Export for YouTube folders (not videos that exist only on a platform). They asked to
see them in the app and act on them, without the app keeping copies.

**Decisions.** Past videos come in by **scanning a folder** the owner picks (and by
dropping projects, exports or folders on the Library page); the sheet lists what was
found to tick. Nothing is copied: the Library keeps only where each file is, the post
links, and later the numbers. The four actions are all in: open in Studio, play / show
the files, open the post, copy the title, description and tags. The module is now called
**Library** (the owner asked for a recommendation): it holds ideas, projects and published
videos.

**Data (Library version 2).** `ContentItem.videos: [VideoPiece]`: a long video or Short
by the recording's or Short's own ID, its exports (paths to `.youtube.json` files) and
its posts (`VideoPost`: a pasted link, or "posted" with no link). `Platform` is read from
a link's address (youtube.com and youtu.be, instagram.com, x.com and twitter.com,
linkedin.com). Stages: idea, inProduction, ready (something exported), posted (a post).
Commands `addVideos` (merge), `putVideo`, `removeVideo`.

**Scanning** (`Sources/LibraryScan.swift`). Finds `.yamvideo` and `.youtube.json` files
under the chosen paths, skipping hidden folders. An export belongs to a project by the
project it names (exports from now on write `projectID` and `recordingID`), else by its
Short's ID, else by the recording's ID or YouTube title. Exports whose project is not there
become items of their own. Candidates say what the Library already holds, so a second
scan offers only new exports.

**The page** (`Sources/LibraryVideos.swift`, `Sources/LibraryVideosView.swift`). An item
with a project shows Project and Videos first: every recording and Short of the project
(read from the project file when shown, not stored), plus anything else it was exported
or posted as, with the cover, length, export date and posts. The row plays the latest
export that still has its video. Find Exports Near the Project scans the project's folder.
A new Export for YouTube or Export Short for YouTube of a linked project adds itself to
its item as an undo step ("Exported …").

**Agents.** Method `scanFolder`; Library commands `importVideos {paths}`, `addPost
{ideaID, videoID, link?}`, `removePost {ideaID, videoID, link?}`; `library` lists each
item's `videos` with exports, posts and files; `yamvideoctl scan --path`; MCP tool
`yamvideo_scan_folder`; the Agents Manual's Ideas recipe gained past videos.

**Checks.** `./test.sh pastvideos` (28 checks). Snapshots 16f (the Add Past Videos sheet)
and 16g (a posted item with its Shorts). Real use: an isolated instance scanned the
owner's `~/Desktop/DJIFootage` and found `AppStore.yamvideo` with 5 Shorts, matched the 5
exports from 15 Oct by Short ID (covers and videos found), imported them, recorded a
YouTube post and revealed the item; nothing was written into the folder.

**Found on the way.** The owner's App Store edit had never been saved as a project (it
lived only in the recovery file); they saved it as `DJIFootage/AppStore.yamvideo` on
2026-10-17.

## 13. Phase 1c: Style.md, project notes and Video.md (2026-10-17)

The owner asked for a CLAUDE.md-like file so agents learn how videos are edited. Two
files, so the facts are not copied:

- **Style.md**, one for the channel, in the Library folder: the owner's taste as rules per
  kind of video (talking head, screen walkthrough, Short, thumbnail). Agents read it
  before editing (served by the bridge like the manual) and propose a rule after the
  owner's feedback; a rule is added only after the owner says yes.
- **Video.md**, one per video, written at export next to its files: what the video is,
  the idea it came from, what was done and why, each Short with its times, and what the
  owner asked to change. The app writes the facts it knows; the agent adds the reasons.

**The owner's answers.** Build both. Agents propose a rule and add it only after the
owner's yes; the owner can also edit Style.md in the app or any text editor. One
Video.md per project, next to the project file, rewritten at every save and export.
Style.md starts from the draft made from the owner's AppStore project and feedback.

**As built.**
- `Sources/Style.swift`: rules under `## ` headings, one `- ` line each with its source
  in `*(…)*`; adding (to an existing or new heading), removing by the rule's words, a
  starter with the headings. Style.md lives beside Library.json and is `Library.style`
  in memory, so it changes, undoes and moves the revision with the Library. Commands
  `setStyle`, `addStyleRule`, `removeStyleRule`. An edit made in another app is taken in
  before the next change and kept in the undo history, so no Undo brings back what it
  replaced.
- The Style sheet (Library toolbar, ⌘3): sections with their rule counts, the text to
  edit, Open in Text Editor and Show in Finder.
- Project version 15 (`VideoProject.notes`, `VideoProject.log`). The Why notes are
  Markdown; `setNotes` / `addNote` edit them (File → Project Notes…, ⇧⌘N). The history
  (`ChangeLogEntry`: date, by, label, kind) gets every committed step, undo and redo
  ("Undid …") and export. It is kept out of undo snapshots (a different document brings
  its own; undo within one keeps it), the owner's identical steps within two minutes are
  one line, and the history alone never marks a project unsaved.
- `Sources/ProjectNotes.swift`: Video.md (`<project> Video.md`): project, idea, Style.md
  date, each recording's length after cuts, captions, graphics with times, the long
  video's title and exports/posts, a Shorts table (times, look, exported, posted), the Why
  notes and the last 60 changes. Written after every save (owner or agent) and every
  YouTube export.
- Agents: method `style`; Library commands for Style.md; project commands
  `setProjectNotes`, `addProjectNote` (signed with the agent's name and the date);
  `state.notes` (`why`, `videoNotes`, `changes`, `recent`); `yamvideoctl style`, MCP
  `yamvideo_get_style`; the manual's session start reads Style.md, and recipe 4.12.

**Checks.** `./test.sh style` (37 checks; the whole suite is 1592). Snapshots 16h (Style) and 16i (Project
Notes). Real use: an isolated instance with a copy of AppStore.yamvideo and the drafted
Style.md read the style, took two notes, saved (writing a real `AppStore Video.md` with
the 5 Shorts and the 9 graphics), and added a rule to Style.md; nothing was written into
DJIFootage.

## 14. Phase 2: Platforms and post kits (started 2026-10-17)

Phase 2 started in a chat on 2026-10-17. The owner stopped it after the rules check, the
questions and the mock-ups, before any code, and asked for this plan to be merged with
everything that comes next. The build is section 14.6.

### 14.1 The platforms' rules, checked 2026-10-17

Checked on the platforms' own help pages without signing in. "3P" marks a number that
only third-party sites give. Rules change, so the app keeps them with this date and shows
it; check again before trusting them after a few months.

**YouTube (long video).** Title 100 characters, no `<` or `>`. Description 5,000
characters (the API says 5,000 *bytes*, so count UTF-8 bytes too). Tags 500 characters in
all, counting the commas and 2 more for a tag with a space. Hashtags: up to 3 show by the
title; with more than 60, YouTube ignores them all. Length: 15 minutes until the channel
is verified, then up to 12 hours or 256 GB. MP4, H.264, AAC; 16:9. Upload page:
`https://www.youtube.com/upload`, which goes on to
`studio.youtube.com/channel/UC/content?d=ud`. Sources: support.google.com/youtube answers
57407, 6390658, 71673 and 1722171; developers.google.com/youtube/v3/docs/videos.

**YouTube Shorts.** A square or vertical video of up to 3:00 is a Short by itself;
landscape never is. Shorts play at most at 1080p. Title, description and hashtags as for
long videos; no current official page asks for #Shorts. Same upload page. Sources:
support.google.com/youtube answers 15424877 and 10059070.

**Instagram Reels.** Caption 2,200 characters. **Hashtags: 5 per post or Reel**, since
18 December 2025 (Meta's developer docs still say 30; the Help Center and @creators say 5).
Length up to 20 minutes, but Reels over 3:00 are not shown to new audiences. 9:16 is best;
a 16:9 video still posts as a Reel, with bars. 23–60 fps, H.264 or HEVC, AAC. About 125
characters show before "more" (3P). No file size is stated for posting by hand. Posting
from a Mac: instagram.com, Create, Post, Select from computer, then the cover, trim and
caption. Sources: facebook.com/help/instagram/351460621611097 (the Help Center page),
about.instagram.com/features/reels, the Graph API media reference.

**X.** 280 characters, or **25,000 with Premium**, counted with a link as 23 and an emoji
as 2; the video does not count. Video: 140 s and 512 MB without Premium; with Premium under
4 hours at 1080p and up to 16 GB on the web and iOS (the About Premium page says about
3 hours and 8 GB). Shapes from 1:2.39 to 2.39:1, so 16:9 and 9:16 both fit. The help page
lists at most 40 fps and 25 Mbps (the developer docs say 30 or 60 fps). X recommends no
more than 2 hashtags. Upload page: `https://x.com/compose/post`. Sources:
help.x.com/en/using-x/x-videos, help.x.com/en/using-x/premium-longer-videos,
help.x.com/en/using-x/how-to-use-hashtags, docs.x.com/fundamentals/counting-characters.

**LinkedIn (the owner's own profile).** Post text 3,000 characters; about 140 (phone) to
210 (desktop) show before "see more" (3P). Video 3 s to 15 min, 75 KB to 5 GB, shapes
from 1:2.4 to 2.4:1 (16:9 and 9:16 both fit), 10–60 fps, MP4 or MOV (ProRes does not
process). No official hashtag guidance any more (the help page is gone; 3–5 or none is
common advice, 3P). Upload page: `https://www.linkedin.com/feed/`, then Start a post and
Add media (the `?shareActive=true` address is not documented). Sources:
linkedin.com/help/linkedin answers a528176 and a548372.

**Best shape.** The long 16:9 video suits YouTube, X and LinkedIn; on Instagram it is a
Reel with bars. A 9:16 Short suits all four.

### 14.2 The owner's answers (2026-10-17)

1. **Post kit text lives in the project**, next to the YouTube text: one set per piece
   (the long video and each Short) and platform. It goes with the project file, undoes
   with the edit, shows in Video.md, and agents change it with project commands. The
   Library keeps only the posts: platform, when the kit was exported, its folder, the
   link.
2. **X has Premium**, so X is checked against 25,000 characters and Premium's video
   lengths. It is a switch in X's profile.
3. **The Publish sheet uses layout B:** the platforms in a list down the left, each with
   a tick and its state (Ready, 2 to fix, 1 to check, Off), the form in the middle and the
   preview on the right. Chosen over tabs across the top.
4. The **Post Kit sheet, the Platforms page and the Library row** were shown as in the
   mock-ups (`docs/prototypes/post-kits.html`). The owner stopped before saying yes or
   asking for changes, so show them again before building them.

### 14.3 The design to build

**Data in the project (version 16).**
- `PostKit` on `PublishInfo.kit` (the long video) and on `Short.kit`: `platforms` (where
  the piece goes, YouTube included) and `posts`, the text for Instagram, X and LinkedIn
  keyed by platform: `PlatformPost {caption, hashtags}`. No kit means YouTube only, as
  today, so older projects read unchanged. A platform's text is kept when it is ticked
  off. YouTube's own text stays where it is.

**Data in the Library (version 3).**
- `Library.platforms`: a `PlatformProfile` for each of the four: handle, links, footer
  (added under every caption, and under YouTube's description), usual posting times
  (weekday and time, for the calendar in phase 3), upload page address (the defaults in
  14.1, editable) and, for X, Premium. They undo with the Library and move its revision.
- `VideoExport.platforms`: the platforms a kit was made for (nil is an older YouTube-only
  export). `VideoPost.platform`: the platform of a post marked without a link.
- Reuse `Platform`, `VideoPiece`, `VideoPost` and `VideoExport`. An exported kit makes
  the video Ready, as an export already does.

**The rules in code.** `PlatformRules` holds the numbers in 14.1 with the date checked;
X's Premium switch picks its limits. The Platforms page and the agents' state show them.

**The text each platform gets:** the caption, the profile's footer, then the hashtags
with `#`. X counts a link as 23 characters and an emoji as 2.

**Checks for each platform** (issues like YouTube's: blocking or warning): caption over
the limit (blocking); more than 5 hashtags on Instagram (blocking), more than 2 on X
(warning); Instagram over 3:00 (warning: followers only) or over 20 minutes (blocking); X
over Premium's length, or over 40 fps (warning); LinkedIn under 3 s or over 15 minutes
(blocking); a 16:9 video on Instagram (warning: bars); after export, a file over a
platform's size. YouTube's checks count only when YouTube is ticked.

**Export Post Kit.** The Publish sheet's button reads Export for YouTube… when only
YouTube is ticked, and Export Post Kit… when more are. It writes what Export for YouTube
(or Export Short for YouTube) writes today, into the folder the owner picks, plus
`<title> Instagram.txt`, `<title> X.txt` and `<title> LinkedIn.txt` for the ticked
platforms. One video serves them all: the 16:9 MP4 or the 1080×1920 Short. The
`.youtube.json` stays the machine file (so the Library and Scan a Folder keep working) and
gains `kit: true` and `platforms`, each with its final text and upload page. YouTube.txt is
written only when YouTube is ticked.

**The Publish sheet (layout B).** Left: "Goes to", a tick and a state per platform.
Middle: YouTube's form as today; Instagram, X and LinkedIn get a caption with its count
and how much shows before "more", hashtags with their count, the footer from the profile
(with Edit Profile), and the checks. Right: the preview, an Instagram Reel over the cover,
an X post or a LinkedIn post. Copy buttons on every field.

**The Post Kit sheet** opens after Export Post Kit and from the Library row's Post Kit….
A card per platform: a copy button for each field, the video and cover shown in Finder,
**Open Upload Page** (it only opens the address in the default browser), and a field to
paste the post's link with Mark Posted. Posted platforms show "On Instagram" and Open Post.

**The Platforms page**, a new module in the sidebar after Studio: the four platforms on
the left, the profile on the right (handle, upload page with Open, links, footer, usual
times, X's Premium), and the rules with the date checked and their sources.

**The Library row** of a video shows a chip per platform of its latest kit: "On X"
(posted, green) or "X: kit ready" (blue), with Post Kit… beside Play.

**Agents** (the owner's rule for every feature):
- Project command `setPostKit {clipID, shortID?, platforms?, posts?}`; only the keys given
  change. State: `clips[].publish.kit` and `clips[].kitIssues` by platform, and the same
  on each Short.
- Library command `updatePlatform {platform, handle?, links?, footer?, times?, uploadPage?,
  premium?}`; `library.platforms` with each profile, its rules and the date checked;
  exports list their platforms, posts their platform; `addPost` takes `platform` for a
  post with no link.
- Method `postKit {clip, short?}`, the preview: each ticked platform's text exactly as its
  file will hold it, its issues, its upload page and the video it uses. It changes
  nothing. `export` with `kit: true` writes the kit. `reveal` with `platform` shows the
  Platforms page.
- `yamvideoctl postkit`, `yamvideoctl export --kit`, `yamvideoctl platforms`; MCP tools to
  match; AgentCatalog entries, kept in step with `WireCommand.types` and
  `LibraryWireCommand.types`.
- Agents Manual recipe **Captions for each platform**: read Style.md, the platforms'
  rules and footers, and the piece's YouTube text and transcript; write each caption with
  `setPostKit` in the owner's style; check it with `postKit`; show the owner; export the
  kit only when asked. Agents never open upload pages and never post.

**Checks.** `./test.sh platforms` (rules, counting, issues, kit files, Library v3 and
project v16 round trips, agent commands, catalog). Snapshots with
`YAMVIDEO_SNAPSHOT_ONLY=platforms`: the Publish sheet for a Short and for the long video,
the Post Kit sheet, the Platforms page, a Library row with kits. A real-use check on an
isolated instance (`YAMVIDEO_LIBRARY_PATH`, `YAMVIDEO_RECOVERY_PATH`,
`YAMVIDEO_AGENT_BRIDGE_DIR`) driven by yamvideoctl, writing nothing into the owner's
folders.

### 14.4 Mock-ups

`docs/prototypes/post-kits.html` has the agreed Publish sheet (layout B), the Post Kit
sheet, the Platforms page and the Library row, drawn with a stand-in cover. The owner saw
them on their "App Store tip: let users delete everything" Short.

### 14.5 Found on the way

- Instagram's limit dropped to 5 hashtags in December 2025; older advice (30) is wrong.
- X's help page caps video at 40 fps. A 50 or 60 fps export should get a warning on X.
- The upload pages need the owner to be signed in to each site in their own browser; the
  app only opens the address.

### 14.6 Next up, in order

1. **Phase 2, the build** (a new chat, branch `distribution-platforms` or a new one):
   1. Show the Post Kit sheet, Platforms page and Library row mock-ups again and get the
      owner's yes or changes.
   2. `PlatformRules` and the text and counting for each platform.
   3. Library version 4 (version 3 is the calendar's plans): profiles, kit platforms on
      exports, a post's platform.
   4. The Platforms page and module.
   5. Project version 16: `PostKit` on the long video and each Short, and `setPostKit`.
   6. The Publish sheet in layout B, with the checks and previews.
   7. Export Post Kit and the Post Kit sheet, with Open Upload Page and Mark Posted.
   8. Kits and posts in the Library row.
   9. Agents: commands, state, `postKit`, `export --kit`, `reveal`, catalog, yamvideoctl,
      MCP, the manual's recipe.
   10. `./test.sh platforms`, snapshots, the real-use check, one PR.
2. **Phase 3, Calendar** (section 7): first ask at what time of day the check-in
   reminders come. The profiles' usual posting times suggest slots.
3. **Phase 4, Results**: first check which export files each platform's analytics give.
4. **Phase 5, in-app AI**: the owner turns on Apple Intelligence first (it was off on
   2026-10-16).
5. **Still open from phases 1 to 1c:** hands-on clicks in the running app (typing, drag
   and drop, paste, the save panel), and the idea chip in Studio's toolbar, which only
   shows in the running app.

## 15. Phase 3: the release calendar (2026-10-18)

The owner asked for it ahead of phase 2: a calendar of what goes out when, and for each
long video a tree of its Shorts, each with its day and the platforms it goes out on. "I
will be telling you" the plan; mostly every platform on the same day. Mock-ups:
`docs/prototypes/release-calendar.html`.

**The owner's answers (2026-10-18).** Build both views. A plan is one day (and an
optional time) for all of a video's platforms; a platform can be unticked or given its
own day. New plans tick all four platforms. Reminders come later, with phase 4.

**As built.**
- `ReleasePlan` on each `VideoPiece` (Library version 3): `day` "yyyy-MM-dd" (a calendar
  day, so it never moves with a time zone), `time` "HH:mm" or nil, `platforms`, and
  `ownDays` {platform: day}. An item with a plan and no post is *Scheduled*.
- The **Calendar** module (⌘4) between Library and Studio: month and week, from Monday;
  each day lists its releases (long video purple, Shorts accent), with YT IG X in marks,
  filled once a post on that platform is recorded. Drag to move (a platform with its own
  day moves alone; dragged back to the video's day it joins the rest), drag from *Not
  planned* to plan for all four, click for the plan editor (day, time, platforms, own
  days, Mark Posted with a link). An idea filter shows one idea's videos.
- The idea page's **Release plan**: the long video, a branch to each Short, each with its
  day, marks or state; **Plan All Shorts…** spreads the unplanned Shorts one every N days.
- Every change is a Library `putVideo`, so it undoes with the Library (⌘Z on the Calendar).
- Agents: `planRelease` (`day`, `clock`, `platforms`, `ownDays`) and `unplanRelease`; the
  plan shows in `library` state. `clock`, not `time`: project commands decode `time` as a
  number from the same request line.
- `./test.sh calendar`.

**Later.** Reminders (macOS notifications on the day), the check-in reminders of phase 4,
and post kits (phase 2) opening from a release.

### 15.1 At a glance (2026-10-21)

**The owner's feedback:** "It is hard for me to know when is when at first glance." The
month showed short chips with cut-off titles, long videos only a colour apart from Shorts,
past and future alike, missed posts like plans, and a third of the window empty.
Mock-ups on sample plans in the owner's rhythm: `docs/prototypes/calendar-glance.html`
(A: the month made readable with Up next; B: a Schedule list). **The owner chose both.**

**As built.**
- **Schedule** (the first view; the last view chosen comes back): *Needs you* (past
  releases not posted on a platform), then *This week*, *Next week* and each week to the
  planning horizon, every day said in words; the rhythm's empty slots as dashed rows; what
  went out in the last four weeks folded under *Earlier*. A platform with its own day is a
  row of its own ("Only LinkedIn this day").
- **Month and Week:** the grid fills the window; an *Up next* strip (the next four
  releases or empty slots, and *Planned ahead* against the horizon); past days faded,
  today outlined, Yesterday/Today/Tomorrow and "in N days" on days with something on;
  long videos as purple bars with a film icon, Shorts as blue chips; marks green when
  posted, orange when missed; dashed empty slots.
- **The rhythm** (`ReleaseRhythm`, Library version 4): the long video's day and weeks
  apart, the Shorts' days, the time and how many weeks ahead to plan. Nil uses Style.md's
  (a long video every other Thursday, Shorts Tuesday and Saturday at 19:00, eight weeks).
  Every other week counts from the latest long video on that day. A long-video week is
  filled by a long video on any of its days; a week needs as many Shorts as Short days.
  Set it with **Rhythm** in the Calendar's bar; it undoes with the Library.
- Agents: `setRhythm`; `library.calendar` gives the rhythm, the empty slots, the missed
  posts and the last planned day. Agents Manual 4.17.
- `./test.sh calendar`; `YAMVIDEO_SNAPSHOT_ONLY=calendar Tools/Snapshot/snapshot.sh`.

