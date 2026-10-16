# Distribution — implementation plan

**Updated:** 2026-10-16. **Status:** phase 1 (the Library, the sidebar and Ideas) is
implemented on the `distribution-ideas` branch; see section 11. Phases 2 to 5 are not
started.

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
- Phase 2: confirm that post kit text lives in the project.
- Phase 3: at what time of day the check-in reminders come.
- Phase 4: which exports each platform offers today.

## 10. Status

| Phase | What | Status |
|---|---|---|
| 1 | Library, sidebar, Ideas | Implemented (`distribution-ideas`) |
| 2 | Platforms and post kits | Not started |
| 3 | Calendar | Not started |
| 4 | Results | Not started |
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
and recipe 4.10 in the Agents Manual (plus rule 10: never post).

**Checks.** `./test.sh library` (61 checks; the whole suite is 1477). `Tools/Snapshot` renders the Ideas pages with
`YAMVIDEO_SNAPSHOT_ONLY=ideas` (16a–16e); the toolbar does not show in snapshots, as
before. The real-use check ran an isolated instance with `YAMVIDEO_LIBRARY_PATH` and drove
it with yamvideoctl: a dry run, two ideas with an image, a stale revision refused, reveal,
a saved project linked, `state.idea`, undo and redo, events, and the Library and link
intact after a relaunch.

**Left for later.** Hands-on clicks in the running app (typing, drag and drop, paste,
the save panel); the idea chip in Studio's toolbar can only be seen in the running app.
