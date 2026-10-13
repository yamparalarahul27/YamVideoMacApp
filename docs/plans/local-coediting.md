# Local co-editing and the simplified editor — implementation plan

**Updated:** 2026-10-13. **Status:** Planning only; this change implements no app features.
**Owner intent:** Edit videos in the native Mac app while Codex or Claude edits the same
open project on the same Mac. The owner also needs beginner-friendly DJI Osmo Pocket 3
colour correction. No cloud collaboration service is required.

This is the coordinating plan. Where earlier documents conflict, the decisions and
sequence here take precedence. The existing effect math and timeline behaviour remain
applicable unless explicitly amended below. Product direction is confirmed; the proposed
protocol, file names and milestones below are implementation decisions for review.

## 1. Baseline and changes to earlier decisions

Inspected application baseline: `timeline-editing` at `98a6789`. Published `main` is
`cd431a3`. The former contains five additional commits, including the editor foundation
(`a07829c`), the Filmora study, the HDR fixture correction, adaptive ruler and anchored
zoom. This documentation PR is based on published main and deliberately includes only
Markdown. Integrate/review the editor branch before implementing this plan. The timeline
plan is carried into this PR from that branch so all planning links work on main.

| Area | Observed state / revised decision |
|---|---|
| Editing foundation | Native preview, cuts, speed, movie assembly, waveform, silence review, suggested zooms, undo and recovery exist on the inspected editor branch. Reuse them. |
| Timeline navigation | Adaptive ruler and anchored zoom are implemented. Snapping, markers, multi-selection and shared lane sizing remain planned. |
| Simplified layout | Promote selection inspector + separate export sheet into the next implementation phase; replace the earlier Inspector/Export tab proposal. |
| Agent editing | Promote to a first-class local workflow. The earlier rejection of an agent-facing edit representation no longer applies. |
| Colour | Add a per-recording Pocket 3 D-Log M workflow before creative effects; see the dedicated colour plan. |
| Full-frame blur | Preserve the planned controls and timing. Implement after shared commands and colour; use the same inspector and agent commands. |
| Layers / blend modes | Retain as a later deliverable, not permanently rejected. It requires a separate composition model and cannot be simulated by sequential Movie assembly. |
| Remotion | Optional local generation of titles, intros and graphics after the co-editing foundation. Native editing must work without Node or Remotion. |
| Existing enhancements | HDR tone mapping, loudness normalization and subtitle import/burn-in exist. Do not reimplement them from the historical enhancement proposal. |

Related plans: [timeline navigation](timeline-navigation.md),
[Pocket 3 colour](pocket-3-colour.md), [whole-frame blur](full-frame-blur-effects.md),
[historical renderer research](video-use-enhancements.md).

## 2. What local co-editing means

Example: the owner opens a recording and starts trimming. In a local Codex or Claude
session they ask, “Remove the pauses and add a zoom when I open Settings.” The agent reads
the open project's state, requests local analysis/preview frames, submits edits, and sees
results. The app updates its actual timeline. The owner can adjust those edits immediately
and Undo them normally. Codex and Claude may both connect; neither owns a separate copy.

YamVideo owns media processing and project state locally. It does not upload footage or
run a hosted collaboration backend. A connected agent client may still use a hosted model;
local co-editing does not promise local model inference. Frames/text explicitly requested
by that client follow its own data handling. No background full-video upload is part of
this design.

MVP does not require an embedded chat pane, a shared cloud document, screen-coordinate
clicking, or agents modifying a live `.yamvideo` JSON file. Offline project files remain
save/open artifacts. Editing a saved file externally never silently replaces live state.

## 3. One project owner and one mutation path

```text
SwiftUI actions ──────────────────────────┐
                                        v
Codex / Claude -> CLI or stdio MCP -> local socket -> ProjectCommandDispatcher
                                                    on the app's MainActor
                                                       |
                                           validated immutable candidate
                                                       |
                                        commit + undo + revision + recovery
                                                       |
                                        timeline / inspector / preview / events
```

Introduce `EditCommand`, `EditTransaction`, `EditResult` and a pure command reducer.
The reducer takes a document value plus explicit IDs; it must not depend on current UI
selection. `ProjectCommandDispatcher` performs the commit on `@MainActor`. Validation
and publication are synchronous there, with no `await` between revision check and commit.
Media probing, analysis and rendering run outside that critical section.

Do not call today's `splitAtPlayhead`, `beginEdit` or selection-dependent methods in a
loop to implement a batch: they mutate state and create history incrementally. Extract
and reuse their timeline math, apply the entire batch to a candidate, validate it, then
publish once. Failure anywhere means no partial edit, revision, history or autosave.

All human document mutations must use this path too: crop handles, blur areas, zooms,
section edits, suggestions, silence cuts, movie order/inclusion/canvas, export settings,
subtitles and source relinking. Audit direct `$model.settings` bindings and writes in
`AppModel`, `CropEditor`, `ContentView`, `MovieEditing` and analysis actions. An observer
that notices changes after they happened is not an atomic command boundary.

Navigation (selection, playhead, zoom, scroll, playback) is session state, not document
revision. Agents read it as context; edit commands use explicit targets and do not steal
focus or move the owner's playhead. A separate, explicit `reveal` action can navigate.
Maintain today's IDs; materialize default section IDs deterministically from the clip ID
when exposing an uncut clip. Splitting keeps the left ID and returns a new right ID.

### Transactions, history and simultaneous input

- Each open document has persistent `projectID`, a fresh `sessionID` per open/restore,
  and a monotonically increasing session `revision`. Requests address all three.
- New/open/recovery rotates the session ID, even when reopening the same file. Undoing
  a project switch also rotates it. Old-session requests fail; revisions are not restored
  from undo snapshots. Save does not change content revision. Save As creates a new
  project ID/session for the new copy; ordinary rename/move keeps identity.
- Every mutation requires `expectedRevision`. Two writers at revision 12 cannot both
  commit: the first produces 13; the second receives `revision_conflict` with 13 and
  changed IDs. It rereads and replans; no automatic overwrite or last-writer-wins merge.
- Each successful nonempty transaction creates one undo entry and increments revision
  once. Undo/redo are new revisions, not counter rollback. No-op edits return unchanged.
- Explicit `begin/update/end/cancel` gesture handling replaces time-window coalescing
  for document gestures. The owner sees transient preview state while dragging; the
  committed snapshot stays stable. Agent mutations return `interaction_in_progress`
  until commit/cancel. Focus loss, Escape and view removal close/cancel the gesture.
- Undo via an agent includes the expected top `transactionID`; reject when another edit
  is now on top. Never undo someone else's intervening change silently. UI Cmd-Z remains
  ordinary global undo; the menu identifies the action and its origin.
- Origin is `human`, `Codex`, `Claude`, or the registered local client label. Attribution
  is informational, not proof of model identity. A compact activity list shows action,
  origin and revision, with Reveal and Undo Last when applicable.
- Analysis results carry base revision + source fingerprint. Applying stale silence or
  zoom suggestions fails or recomputes; it never uses an old timeline against new cuts.

### Retries, crashes and files

`requestID` is an idempotency key per session. Cache terminal mutation results and a hash
of the payload for the whole session. A duplicate with the same payload returns its
original result before the revision check; a different payload yields
`request_id_reused`. Bound a session to 10,000 mutation IDs; require reconnect/new session
rather than evicting IDs and risking duplicate execution. After a crash/new session, old
requests fail; the client must inspect recovered state before issuing new IDs. A commit
may have reached memory but not the current 700 ms recovery debounce; describe that
existing crash window accurately. Do not claim exactly-once persistence across crashes.

Save atomically, retain source files, and detect external modifications to the named
project against its last saved file fingerprint before overwriting. Surface Save Copy or
explicit reload/replace choices; never auto-import file changes. Agent save returns a
structured conflict instead of opening a modal dialog. Existing export atomic publish
and cancellation behaviour must survive the refactor.

## 4. Local transport and client tools

Build a native `yamvideoctl` executable alongside the app. `yamvideoctl sessions --json`
discovers running app sessions; commands never silently attach to a different document.
If the app is not running, return `app_not_running` with launch instructions. Keep the
first release's one-window model; discover multiple app instances without guessing.

App listener: a Unix-domain socket in a short, random subdirectory of the per-user macOS
temporary directory. Enforce the platform socket path length limit. Directory mode 0700,
socket mode 0600; verify peer UID, refuse symlink endpoints, and validate discovery records
against the server's session response. An atomic 0600 discovery record under
`~/Library/Application Support/YamVideo/AgentBridge/` contains socket path, instance ID
and process ID. Remove records on clean shutdown; stale records never authorize replacing
an arbitrary socket. No network listener or remote binding in this release.

Use a versioned newline-delimited UTF-8 JSON request/response protocol on this socket,
separate from MCP. Limit a request to 1 MiB and a transaction to 100 commands. Return local
artifact paths for images rather than base64 blobs in socket messages. Bound event pages
to 100 entries, retain the most recent 1,000 events and return `resync_required` if a
cursor expired. Event sequence is separate from edit revision because job events do not
edit the document. Request timeouts do not imply a mutation was cancelled; retry by ID.

Provide an optional stdio MCP adapter in `Tools/AgentBridge/` using the official SDK,
with a pinned dependency/lockfile at implementation time. It maps tools to the same
socket commands; it contains no editing logic. Logs go to stderr. Validate compatibility
against the actual installed Codex and Claude clients, including protocol-version
handling; do not invent configuration flags from memory. CLI is the dependency-free
fallback for local agents that can run commands. MCP setup is documented and copyable,
never automatically writes either client's configuration.

Official references: [MCP transport specification](https://modelcontextprotocol.io/specification/2026-07-28/basic/transports)
and [version compatibility](https://modelcontextprotocol.io/specification/2026-07-28/basic/versioning).

### Required surface

| CLI command / corresponding MCP tool | Contract |
|---|---|
| `sessions` / `yamvideo_list_sessions` | Instance/session/project identity, title, capabilities; no mutation. |
| `state` / `yamvideo_get_state` | Revision, stable clip/section/effect IDs, source metadata, edited timing, settings, selection/playhead, busy state and history head. |
| `apply --file ...` / `yamvideo_apply_edits` | Atomic typed transaction, optional dry-run; result contains affected IDs, generated IDs, remap losses and new revision. |
| `events --after ...` / `yamvideo_get_events` | Bounded cursor-based polling; change summaries and job status, not full project copies every time. |
| `preview` / `yamvideo_render_preview` | Frame or short preview from a specified revision, clip and edited time; return artifact path and render provenance. |
| `analyze` / `yamvideo_analyze` | Asynchronous silence or visual zoom analysis; returns job ID; does not apply its suggestions. |
| `job` / `yamvideo_get_job` | Progress/result/error and source revision for preview, analysis or export jobs. |
| `cancel` / `yamvideo_cancel_job` | Cancel only the addressed job; clean its temporary output. |
| `save` / `yamvideo_save_project` | Explicit destination or existing named save; revision check and disk conflict check; no save dialog. |
| `export` / `yamvideo_export` | Explicit format/scope/path and revision; immutable render snapshot, job ID. Default is no overwrite. |
| `undo`, `redo` / matching tools | Expected revision + history transaction identity; same history as the human UI. |
| `reveal` / `yamvideo_reveal` | Explicit view navigation, not implicitly attached to any edit. |

MVP edit commands: split, trim, delete, reorder sections; set speed/crop; add/update/remove
area blur and zoom; set movie order/inclusion/canvas; set export settings; set subtitle
file; import/relink local media. Probe imported/relinked media first as a job; apply its
validated result only at the requested revision. Later colour, markers and visual effects
register typed commands through the same dispatcher and advertise capabilities.

Requests use source seconds for trim bounds and edited-recording seconds for split,
zoom and effect timing. Movie time must include explicit `timeSpace: movie` and be mapped
through `MoviePlan`; it is never accepted as implicit recording time. Return actual
snapped times and retain existing rational-frame/cumulative-boundary rounding. Half-open
ranges are `[start,end)`. Reject nonfinite numbers, invalid IDs, overlaps or unsupported
commands; do not silently clamp API input. UI may clamp before submitting its command.

Illustrative wire request (IDs stand for values returned by `state`):

```json
{
  "protocolVersion": 1,
  "requestID": "request-uuid",
  "method": "apply",
  "sessionID": "open-session-uuid",
  "projectID": "project-uuid",
  "expectedRevision": 12,
  "label": "Speed up the intro",
  "dryRun": false,
  "commands": [
    {"type": "setSegmentSpeed", "clipID": "clip-uuid", "segmentID": "section-uuid", "speed": 1.5}
  ]
}
```

Error codes include `revision_conflict`, `wrong_session`, `interaction_in_progress`,
`export_in_progress`, `invalid_command`, `missing_media`, `unsupported_capability`,
`request_id_reused`, `disk_conflict` and `resync_required`. Errors include a readable
message, retryability and current revision where relevant; they never return success
for an ignored command. Dry-run performs the same validation/remapping but commits no
state and reserves nothing; real apply must recheck revision.

Preserve today's export edit lock for the MVP: content mutations return
`export_in_progress` while exporting. Read/preview/status/cancel stay available. Editing
during export can be added after immutable render snapshots have separate validation.
Agents choose explicit destinations; they cannot overwrite source media. Cancelling a
render is distinct from rolling back an already committed edit.

## 5. Simplified interface

Use three resizable upper panels: media library, viewer, selection inspector. Place the
active timeline below them across the window width. Keep Recording and Movie contexts
explicit; Movie initially remains sequential assembly and Edit opens a recording.

The inspector follows selection: section timing/speed, recording crop/colour/subtitles,
zoom parameters, area obscuring or a visual effect. Move `TimelineView.sectionControls`
into it. If nothing is selected, show a useful prompt and recording summary. Preserve
numeric precision behind an expandable Details row; common controls use plain labels.

One primary Export button opens a sheet with Selected Recording / All Recordings / Movie
scope, destination and export settings. Preserve keyboard commands and current defaults.
Project name/dirty state, Add Media, undo/redo and playback remain easy to find. Do not put
FFmpeg commands, sockets, revisions or agent configuration into the ordinary editing UI.

A compact “Local agents” status item shows connected clients and a pause/disconnect
control. Pause rejects new agent mutations; the human can keep editing. Agent changes
briefly highlight affected blocks without changing selection. Activity is a collapsible
panel, not a compulsory chat workflow. No confirmation modal for each ordinary edit.

Implement shared lane sizing before adding markers/effects. Keep viewport clipping and
adaptive ruler behaviour from `98a6789`; don't recreate the old wide-ZStack layout bug.
Snapping uses the existing 8-point proposal. Store multi-selection as a `Set<UUID>` and
derive order from the timeline; a Swift Set itself is not ordered.

## 6. Persistence and current gaps that must be fixed first

`VideoProject` currently supports v1/v2. Introduce v3 for a stable `projectID` and complete
editable-state persistence, including `VideoItem.subtitles`, currently absent from
`ProjectClip`. Audit all editable fields for round-trip, history and recovery coverage.
Migrate v1/v2 explicitly and assign missing project identity once; generated identifiers
must survive save/reopen. Session revision and client connections are not file content.

Keep document values separate from selection/playhead/viewport so browsing doesn't dirty
the project or conflict with agent edits. Adapt `EditHistory`/`SessionRecovery` deliberately;
undo restores content and useful selection without restoring an old session/revision.

The colour phase uses v4. Subsequent markers and blur use the next schema version at their
actual landing point, coordinated in one migration registry; do not independently claim
v3 as earlier plans did. Unknown future versions fail without partially restoring. No
feature-bearing project may be written as an older schema that silently loses edits.

## 7. Remotion and later layers

Remotion is an optional local generator. A separate Node worker renders a versioned,
parameterized template to a cached asset; importing that asset is a normal app command.
The owner can edit text, colours and duration in the inspector; agents edit the same
schema-validated properties. Store template ID/version, props, source hash, render settings
and generated asset hash. A successful render is attached only if its requested project
revision is still current; otherwise keep the artifact and ask the client to rebase.

First support opaque intro/title cards as ordinary movie clips. Transparent lower thirds
and graphics over footage depend on actual video layers and alpha-preserving preview and
export; do not flatten them invisibly or promise them in the first integration. Distinguish
editable template props from the rendered clip's normal trim/speed controls.

Use `renderMedia` in a cancellable local worker, explicit local assets, matching rational
fps, output dimensions and frame count. Pin matching Remotion package versions and record
the Node/browser runtime. Native app launch/edit/export remains independent of this worker.
No arbitrary submitted JavaScript or shell execution through the editing protocol; custom
template development is a separate local development action.
[Remotion rendering API](https://www.remotion.dev/docs/renderer/render-media) and
[parameterized compositions](https://www.remotion.dev/docs/parameterized-rendering).

Before layers ship, write the composition schema for independent clip instances, start/end,
track order, opacity, transforms and blend modes; define blend colour space and matching
Core Image/FFmpeg behaviour, audio overlap, old-project migration and hit testing. Repeated
instances need their own IDs and source anchors. This is a later design gate, not a reason
to expand the initial gapless `ClipTimeline` model prematurely.

## 8. File map and delivery order

All new paths below are proposed. Existing paths refer to the inspected editor branch.

| Files | Responsibility |
|---|---|
| `Sources/EditCommands.swift`, `ProjectCommandDispatcher.swift` | Typed DTOs, candidate reduction, validation, atomic commit, revision and idempotency. |
| `Sources/ProjectEditing.swift`, `AppModel.swift`, `Timeline.swift` | Complete project persistence, session identity, history/recovery, shared mutation entry point. |
| `Sources/LocalAgentServer.swift`, `AgentProtocol.swift` | Socket lifecycle, framed requests, event cursor, capability discovery and job routing. |
| `Tools/YamVideoCLI/main.swift` | Native CLI; compile shared Foundation-only protocol types, never app singleton or GUI entry point. |
| `Tools/AgentBridge/` | Optional MCP adapter, pinned SDK, setup guide and integration checks. |
| `Sources/InspectorView.swift`, `ExportSheet.swift`, `AgentActivityView.swift` | Simple editor controls and unobtrusive co-edit activity. |
| `ContentView.swift`, `TimelineView.swift`, `CropEditor.swift`, `MovieEditing.swift`, `ZoomSuggestions.swift`, `AudioAnalysis.swift` under `Sources/` | Route all persistent mutations through commands; gesture transactions; remove duplicate controls. |
| `Sources/Playback.swift`, `MoviePlayback.swift`, `Movie.swift`, `FFmpeg.swift` | Revision-tagged preview/jobs and immutable render inputs; preserve existing output correctness. |
| `Tools/Remotion/`, `Sources/GeneratedMedia.swift` | Later optional render worker, metadata, cache and transactional import. |
| `build.sh`, `test.sh`, `Tests/main.swift`, `Tests/AgentBridge/` | Build CLI separately; shared command, socket and real-client tests. |

Deliver as separately reviewable implementation changes:

1. **Foundation baseline:** integrate editor branch; run current build/tests and record
   actual results. Fix persistence gaps, v3 migration and stable identities. No new renderer.
2. **Shared commands + local CLI:** migrate all UI writes, add atomic batches, gestures,
   revisions, undo attribution, socket and CLI. Demonstrate human + two CLI clients editing
   one open project without lost updates.
3. **Simple UI + client connection:** inspector/export sheet, activity/pause, remaining
   navigation work, MCP adapter, setup guide and hands-on Codex/Claude acceptance demo.
4. **Pocket 3 colour:** v4 persistence, official technical LUT import, simple controls,
   before/after and matching render paths. Agent colour commands land in the same change.
5. **Full-frame blur + remaining markers:** implement the linked blur plan through the
   shared inspector/commands, with colour-stage parity and coordinated schema migration.
6. **Optional generation, then layers:** opaque Remotion assets first; finish the separate
   layer/compositing design before overlays or blend-mode UI. These do not block local co-editing.

## 9. Acceptance gates

- Human drag held for >0.6 s remains one undo step. An agent mutation during it fails
  clearly, then succeeds after rereading. A cancel creates no history or revision.
- Codex and Claude submit different transactions at revision N: one succeeds and one
  conflicts. A late result, duplicate ID, reopened file and crashed/restarted app cannot
  apply an old edit twice or target the wrong project.
- A batch with two valid commands and one invalid command changes nothing. Dry-run reports
  the same proposed remap losses as apply at that revision. No-op edits don't dirty state.
- Human edits and agent edits interleave; Cmd-Z restores the exact previous document.
  Agent undo refuses to cross an intervening transaction. New edits invalidate redo.
- v1/v2 migration, v3 round-trip/recovery, subtitle paths, source relink and Save As identity
  all pass. External file edits produce a conflict, not a silent overwrite.
- Preview/job artifacts carry requested revision/time and cannot replace newer preview
  results. Export/cancel preserve existing outputs; source files remain unchanged.
- Malformed/oversize socket input, wrong peer UID, stale discovery, socket restart and
  client disconnect have bounded errors; UI remains responsive. An offline machine can
  perform CLI edits and native rendering without network access.
- In the app's minimum supported window, media/preview/inspector/timeline are usable;
  keyboard focus and VoiceOver labels survive the layout refactor. Agent changes don't
  steal selection, playback position or focus. Ordinary controls require no agent setup.
- Run the existing Swift suite and build plus command/transport tests. Then perform a real
  local Codex session and a real local Claude session against the same app. Record client
  versions, configuration used and results; mocked MCP calls alone do not prove support.
- Save a small demonstration project and a contact sheet/short recording showing a human
  cut, an agent zoom, a conflict, undo, and (when colour lands) Pocket 3 before/after.

No new tests or app binaries are required for this documentation-only change. Validate
Markdown links, code examples, baseline references and `git diff --check` before publishing.
