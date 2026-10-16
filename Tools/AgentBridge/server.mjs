#!/usr/bin/env node
// YamVideo MCP server: Codex, Claude and other MCP clients co-edit the project open in
// YamVideo on this Mac.
//
// It holds no editing logic. Every tool runs yamvideoctl, which finds the running app,
// checks that its socket is private to this user and speaks the protocol; YamVideo
// decides whether an edit is valid. Logs go to stderr — stdout is the MCP channel.

import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const here = path.dirname(fileURLToPath(import.meta.url));
const ctl = process.env.YAMVIDEO_CTL || path.resolve(here, "../../build/yamvideoctl");
// Credited in YamVideo's Undo menu and activity list. Set per client in its MCP config.
const client = process.env.YAMVIDEO_CLIENT || "MCP client";

/** Runs yamvideoctl with `args`, optionally feeding `input` on stdin; returns its JSON. */
function runCtl(args, input) {
  return new Promise((resolve) => {
    const child = spawn(ctl, [...args, "--client", client], { stdio: ["pipe", "pipe", "pipe"] });
    let out = "", err = "";
    child.stdout.on("data", (chunk) => (out += chunk));
    child.stderr.on("data", (chunk) => (err += chunk));
    child.on("error", (error) =>
      resolve({ ok: false, error: { code: "ctl_unavailable", message: `Could not run ${ctl}: ${error.message}. Build YamVideo with ./build.sh, or set YAMVIDEO_CTL.` } }));
    child.on("close", () => {
      try { resolve(JSON.parse(out)); }
      catch { resolve({ ok: false, error: { code: "bad_output", message: err.trim() || "yamvideoctl returned no JSON." } }); }
    });
    child.stdin.end(input ?? "");
  });
}

/** Sends one protocol request. Fields left undefined are omitted. */
function request(method, fields = {}) {
  const body = { protocolVersion: 1, method };
  for (const [key, value] of Object.entries(fields)) if (value !== undefined) body[key] = value;
  return runCtl(["request", "--file", "-"], JSON.stringify(body));
}

/** An MCP result carrying the app's JSON answer; refusals are tool errors with their reason. */
function result(response, extra = []) {
  return {
    content: [{ type: "text", text: JSON.stringify(response, null, 1) }, ...extra],
    isError: response?.ok !== true,
  };
}

const id = z.string().describe("A UUID from yamvideo_get_state.");
const address = {
  sessionID: id.describe("sessionID from yamvideo_get_state."),
  projectID: id.describe("projectID from yamvideo_get_state."),
  expectedRevision: z.number().int().nonnegative().describe("The revision your plan was based on. If the project changed since, the request is refused with revision_conflict: read state again and replan."),
};
const requestID = z.string().max(128).optional().describe("Reuse the same ID to retry safely after a timeout; a retry is never applied twice. Omit to generate one.");

const server = new McpServer(
  { name: "yamvideo", version: "1.0.0" },
  {
    instructions: [
      "YamVideo is a Mac video editor. These tools read and edit the project the owner has open, while they keep editing it too.",
      "Start with yamvideo_manual: the Agents Manual has the rules for work with the owner and a recipe for each common job (first edit, cuts, captions, screen and layouts, zooms, graphics, chapters and text, thumbnail, Shorts, export).",
      "Then yamvideo_describe: it lists every edit command with its fields, units, ranges, defaults and an example, and the rules every request follows. It comes from the app, so it is always current.",
      "Workflow: call yamvideo_get_state, plan, check with yamvideo_apply_edits dryRun, then apply with the sessionID, projectID and revision you read. All commands in one call apply together or not at all.",
      "If you get revision_conflict, someone else (often the owner) edited meanwhile: read state again and replan. Never retry an edit with a guessed revision.",
      "Each applied call is one undo step credited to you. Use yamvideo_undo only for your own most recent step (the transactionID from state.history.undo).",
      "Times: split points and zoom starts are edited-recording seconds; trims and section ranges are source seconds; movie time only with timeSpace \"movie\".",
      "Look before and after with yamvideo_render_preview; pass composed: true to see zooms and whole-frame blur effects exactly as the owner's Preview shows them. Analysis proposes cuts or zooms but applies nothing. Ask the owner before exporting or saving over their file.",
      "Markers (state.clips[].markers) are the owner's notes on the timeline; read their labels to learn what they mean by \"the bit after the intro\", and add your own to point at moments.",
      "The owner's answers for a first edit (transcript model and language, cut style, captions, loudness) are in state.autoEdit.options. yamvideo_auto_edit follows them in one undoable step; yamvideo_get_transcript gives the words with edited times, for placing graphics and chapters on what is said.",
      "A YouTube Short is a vertical 1080×1920 version of up to 3:00 of a recording (state.clips[].shorts): add one with addShort (window \"speaker\" centres it on the face), look at it with yamvideo_render_preview and short, and export it with yamvideo_export and short (youtube: true writes the upload files).",
    ].join("\n"),
  },
);

server.registerTool("yamvideo_manual", {
  title: "Read the Agents Manual",
  description: "How to work with the owner in YamVideo: the rules, and a recipe for each common job. It comes from the app, so it matches this build. Read it once at the start of a session.",
  inputSchema: {},
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async () => {
  const response = await request("manual", {});
  const text = response?.result?.text;
  return text ? { content: [{ type: "text", text }] } : result(response);
});

server.registerTool("yamvideo_describe", {
  title: "Describe what YamVideo can do",
  description: "Every edit command (sections, crop, blur areas, zooms, whole-frame blur effects, markers, colour, movie, project) with each field's type, unit, range, default and allowed values, a worked example per command, every other request, and the conventions: time spaces, units, revisions and how commands in one request see each other. Read this before planning edits.",
  inputSchema: {},
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async () => result(await request("catalog", {})));

server.registerTool("yamvideo_list_sessions", {
  title: "List YamVideo sessions",
  description: "Running YamVideo instances on this Mac, with the open project's session, revision, title and capabilities.",
  inputSchema: {},
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async () => result(await runCtl(["sessions"])));

server.registerTool("yamvideo_get_state", {
  title: "Read the open project",
  description: "The open project as last committed: revision, every recording with stable IDs for its sections, blur areas and zooms (with source and edited timing), crop, subtitles, export settings, movie order, the owner's selection and playhead, and the top undo/redo steps.",
  inputSchema: { sessionID: id.optional(), projectID: id.optional() },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async (args) => result(await request("state", args)));

server.registerTool("yamvideo_apply_edits", {
  title: "Apply edits",
  description: [
    "Apply 1–100 typed commands as one undo step, against the revision you read. Out-of-range values are refused, never clamped. Use dryRun to validate and preview the effect (new IDs, zooms a cut would remove) without committing.",
    "Command types and fields (IDs from state; rect = {x, y, width, height} in source pixels; target = {x, y}):",
    "splitSection {clipID, at} · trimSection {clipID, sectionID, start?, end?} · deleteSection {clipID, sectionID} · moveSection {clipID, sectionID, index} · setSectionSpeed {clipID, sectionID, speed 0.25–4} · replaceSections {clipID, sections:[{id?, start, end, speed?}]}",
    "setCrop {clipID, rect} · setAspect {clipID, preset: Free|16:9|9:16|1:1|4:5|4:3|2.39:1}",
    "addBlurArea {clipID, rect, areaID?} · updateBlurArea {clipID, areaID, rect} · removeBlurArea {clipID, areaID} · replaceBlurAreas {clipID, areas:[{id?, rect}]}",
    "addZoom {clipID, start, target, hold? (2), level? (2), zoomID?} · updateZoom {clipID, zoomID, start?, hold?, level?, target?} · removeZoom {clipID, zoomID} · replaceZooms {clipID, zooms:[…]}",
    "setMovieOrder {order:[every clipID]} · setIncludedInMovie {clipID, included} · setMovieCanvas {canvas: firstClip|widescreen|portrait|square}",
    "setExportSettings {settings: only the keys to change, e.g. {format: \"gif\", frameRate: 12}; captions: burnIn|upload|off} · setSubtitles {clipID, path} · clearSubtitles {clipID} · addMedia {paths} · removeMedia {clipID} · relinkMedia {clipID, path}",
    "Auto edit: setAutoEditOptions {autoEdit: only the keys to change: model large-v3-turbo-q5_0|base.en, language (en, hi, te… or auto), cutStyle tight|natural|review, captions upload|burnIn|off, normaliseAudio} · importTranscript {clipID, path to whisper-cli -ojf JSON or {model, language, words}} · clearTranscript {clipID}",
    "Colour (each recording's state.color shows the profile in effect and why, the conversion and any problem): setInputProfile {clipID, profile: auto|standard|pocket3DLogM|hlg|pq} · importTechnicalLUT {clipID, path to DJI's Pocket 3 D-Log M to Rec.709 .cube; needs profile pocket3DLogM} · clearTechnicalLUT {clipID} · setColorCorrection {clipID, enabled} (Natural colour) · setColorAdjustments {clipID, exposureEV? -2–2, warmth? -1–1, contrast? 0.5–1.5, saturation? 0–2} · resetColorAdjustments {clipID} · copyColorAdjustments {clipID (from), targets:[clipID], includeInterpretation? (also copy profile and conversion)}",
    "Whole-frame blur: addBlurEffect {clipID, start, end? or duration? (3), amount? 0–80 (24), mix? 0–1 (1), fadeIn? (0.25), fadeOut? (0.25), enabled?, effectID?} · updateBlurEffect {clipID, effectID, any of those} · removeBlurEffect {clipID, effectID}",
    "Markers: addMarker {clipID, time, label?, color? red|orange|yellow|green|blue|purple, markerID?} · updateMarker {clipID, markerID, time?, label?, color?} · removeMarker {clipID, markerID}",
    "Graphics (state.clips[].graphics; times are edited-recording seconds; beat times inside props such as at or …At are seconds after the graphic's start; image values are absolute file paths): addGraphic {clipID, graphic: {kind, start, end, props, look?: glass|ink, id?}} · updateGraphic {clipID, graphicID, graphic: {only the fields to change; props replaces all props}} · removeGraphic {clipID, graphicID} · replaceGraphics {clipID, graphics:[…], graphicsStyle?} · setGraphicsStyle {clipID, graphicsStyle: {accent?, panel?: shade|solid, moveVideo?, edge? 0–400, look?: glass|ink|mix}} · importGraphics {clipID, path to a graphics.json as Tools/Graphics uses}. Kinds: namePlate, featureList, titleCard, phoneScreens, route, link, endCard (right column) and panelTitle, rule, checklist (side panel).",
    "Shorts (state.clips[].shorts; vertical 1080×1920, up to 3:00, the same edit, graphics and captions laid out for a phone): addShort {clipID, short?: {start?, end?, window?: {x, y, width, height} 9:16 source pixels | \"speaker\" | \"centre\", title?, description?, tags?, hidden?: [graphicID], placements?: {graphicID: {x, y, scale}}, cover?, panels?: sheet|shade|split, captions?: stepUp|over|hide, zoom?: 0.5625–1 (lower zooms out: the picture at the top over a blurred copy, text under the face), screen?: off|top (with a screen recording: the screen across the top, the speaker below, the face kept in YouTube's clear area), id?}} · updateShort {clipID, shortID, short: only the keys to change} · removeShort {clipID, shortID}",
    "splitSection, zoom and effect starts, marker times and a new graphic's start accept timeSpace \"movie\" to give a movie time instead. yamvideo_describe has every field's range, default and an example.",
  ].join("\n"),
  inputSchema: {
    ...address,
    commands: z.array(z.object({ type: z.string() }).passthrough()).min(1).max(100).describe("The commands, in order."),
    label: z.string().max(80).optional().describe("What the Undo menu should call this step, e.g. \"Tighten the intro\"."),
    dryRun: z.boolean().optional(),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
}, async (args) => result(await request("apply", args)));

server.registerTool("yamvideo_get_events", {
  title: "Read recent changes",
  description: "Changes since a cursor, oldest first, at most 100 per page: edits, undo/redo, project switches and finished jobs, each with who made it. Pass the returned `next` as `after` to continue. resync_required means the cursor is too old: read state again.",
  inputSchema: { after: z.number().int().nonnegative().optional(), limit: z.number().int().min(1).max(100).optional() },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async (args) => result(await request("events", args)));

server.registerTool("yamvideo_render_preview", {
  title: "Render a preview frame",
  description: "Render one frame of a recording at an edited time (or a movie time with timeSpace \"movie\") to a PNG on this Mac, with colour, blur areas, tone mapping and captions applied; cropped also applies the crop (zooms are not drawn); original leaves the colour correction out, to compare with a corrected frame at the same revision. Returns the file path and the revision and source time it shows; attachImage includes the picture in this result so you can see it.",
  inputSchema: {
    clip: id.optional().describe("Recording ID (omit with timeSpace \"movie\")."),
    time: z.number().nonnegative(),
    timeSpace: z.enum(["recording", "movie"]).optional(),
    composed: z.boolean().optional().describe("Render as the owner's Preview plays it: crop, zoom, colour, blur areas and whole-frame effects at this exact time. Use it to check an effect or a zoom."),
    cropped: z.boolean().optional(),
    short: id.optional().describe("One of the recording's Shorts (state.clips[].shorts[].id): draws it 1080×1920 as its viewer shows it, graphics and captions laid out for 9:16, with each graphic's box. time is then seconds into the Short."),
    furniture: z.boolean().optional().describe("With short: draw YouTube's Shorts player over the frame (top icons, like and share rail, channel and title) and dash the clear area, to see what a phone covers."),
    draft: z.array(z.record(z.any())).optional().describe("Graphics to draw in this preview only, never stored ({kind, start, end, props}, as in addGraphic; with composed or short). Use it to show the owner a plan before you apply it."),
    original: z.boolean().optional().describe("Leave the recording's colour correction out."),
    expectedRevision: z.number().int().nonnegative().optional().describe("Refuse if the project is no longer at this revision."),
    attachImage: z.boolean().optional().describe("Include the PNG in the result (default true)."),
  },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async ({ attachImage, ...args }) => {
  const response = await request("preview", args);
  const extra = [];
  if (response?.ok && attachImage !== false && response.result?.path) {
    try {
      extra.push({ type: "image", mimeType: "image/png", data: (await readFile(response.result.path)).toString("base64") });
    } catch (error) {
      console.error(`yamvideo-mcp: could not attach ${response.result.path}: ${error.message}`);
    }
  }
  return result(response, extra);
});

server.registerTool("yamvideo_analyze", {
  title: "Analyze a recording",
  description: "Start a background job: \"silence\" proposes cuts (and the resulting sections) from audio levels; \"autoEdit\" proposes the cuts the owner's cut style makes, pauses and stumbles from the transcript, each with its reasons; \"zooms\" proposes zooms from local visual activity, \"screenZooms\" the same on the screen recording; \"thumbnailFrames\" finds the best moments for the thumbnail (a smile, eyes open, facing the camera) with a contact sheet PNG to look at; \"logos\" finds the brand and company names said in the transcript, lists those without a logo yet (ask the owner for a file, then yamvideo_set_logo), and suggests a logoBadge graphic next to the speaker for each name with a logo. Nothing is applied — apply chosen results with yamvideo_apply_edits. Poll with yamvideo_get_job.",
  inputSchema: {
    sessionID: address.sessionID, projectID: address.projectID, clip: id, kind: z.enum(["silence", "zooms", "screenZooms", "autoEdit", "thumbnailFrames", "logos"]),
    limit: z.number().int().min(1).max(20).optional().describe("For thumbnailFrames: how many moments (default 8)."),
    style: z.enum(["tight", "natural", "review"]).optional().describe("For autoEdit: a cut style other than the owner's."),
    threshold: z.number().optional().describe("Silence threshold in dB (default -40)."),
    minimum: z.number().nonnegative().optional().describe("Silence: shortest pause to cut, seconds (default 0.8). Logos: seconds between two badges of one logo (default 60)."),
    padding: z.number().nonnegative().optional().describe("Audio kept either side of a cut, seconds (default 0.15)."),
    requestID,
  },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async (args) => result(await request("analyze", args)));

server.registerTool("yamvideo_logos", {
  title: "List the owner's logos",
  description: "The owner's logo library, kept for every project: each brand's name, the words that say it, and its image's path. analyze with kind logos uses it.",
  inputSchema: {},
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async () => result(await request("logos", {})));

server.registerTool("yamvideo_set_logo", {
  title: "Keep a logo in the library",
  description: "Add a brand's logo to the owner's library, or replace the one of the same name: the app keeps a copy of the file. Use only a logo the owner gave, or a clear, simple one you are sure of (never invent one), and show the owner each logo you keep.",
  inputSchema: {
    name: z.string().min(1).max(40).describe("The brand, as the badge's label shows it: Next.js, Apple Watch."),
    path: z.string().describe("A local PNG (transparent), JPEG, SVG, WebP or HEIC file."),
    words: z.array(z.string().min(1).max(40)).min(1).max(8).optional().describe("What the speaker says for it, matched without case. Default: the name."),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("setLogo", args)));

server.registerTool("yamvideo_remove_logo", {
  title: "Remove a logo from the library",
  description: "Remove a brand's logo from the owner's library. A badge that uses it cannot draw until the logo is set again.",
  inputSchema: { name: z.string().min(1).max(40), requestID },
  annotations: { readOnlyHint: false, destructiveHint: true, openWorldHint: false },
}, async (args) => result(await request("removeLogo", args)));

server.registerTool("yamvideo_transcribe", {
  title: "Transcribe a recording",
  description: "Start a job that transcribes a recording on this Mac with whisper.cpp, word by word; the transcript lands as one undo step. state.autoEdit says whether whisper is installed and which models are downloaded (only the owner can download one). Poll with yamvideo_get_job.",
  inputSchema: {
    sessionID: address.sessionID, projectID: address.projectID, clip: id,
    model: z.enum(["large-v3-turbo-q5_0", "base.en"]).optional().describe("Default: state.autoEdit.options.model."),
    language: z.string().optional().describe("A whisper language code or auto. Default: state.autoEdit.options.language."),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("transcribe", args)));

server.registerTool("yamvideo_get_transcript", {
  title: "Read a recording's transcript",
  description: "Every word in source seconds with editedStart (where it plays now; null when cut), the captions on the edited timeline, and stumbles found (filler, repeat, restart, fragment).",
  inputSchema: { clip: id },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async (args) => result(await request("transcript", args)));

server.registerTool("yamvideo_auto_edit", {
  title: "Auto edit a recording",
  description: "Start a job that edits a recording the way the owner chose in state.autoEdit.options: transcribe if needed, cut pauses (and stumbles for the tight style), and set captions and loudness, as one undo step. With the review style nothing is cut and the proposed cuts come back to show the owner. The result lists each cut with its reasons and the transactionID to undo it. Poll with yamvideo_get_job.",
  inputSchema: {
    sessionID: address.sessionID, projectID: address.projectID, clip: id,
    style: z.enum(["tight", "natural", "review"]).optional().describe("Override the owner's cut style for this run."),
    label: z.string().max(80).optional(),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("autoEdit", args)));

server.registerTool("yamvideo_get_job", {
  title: "Check a job",
  description: "Status, progress and result of an analysis or export job. With wait, returns once the job has finished (up to about ten minutes).",
  inputSchema: { job: id, wait: z.boolean().optional() },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async ({ job, wait }) => result(await runCtl(["job", job, ...(wait ? ["--wait", "--timeout", "600"] : [])])));

server.registerTool("yamvideo_cancel_job", {
  title: "Cancel a job",
  description: "Cancel one analysis or export job. A cancelled export never touches its destination.",
  inputSchema: { job: id, requestID },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("cancel", args)));

server.registerTool("yamvideo_save_project", {
  title: "Save the project",
  description: "Save without a dialog: in place (refused with disk_conflict if the file changed on disk), to a first location for an untitled project (path), or to another path as a separate copy with its own identity. Ask the owner first.",
  inputSchema: {
    ...address,
    path: z.string().optional().describe("A .yamvideo path; omit to save in place."),
    overwrite: z.boolean().optional(),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("save", args)));

server.registerTool("yamvideo_export", {
  title: "Export",
  description: "Start an export job of exactly the revision named, to an explicit path whose extension matches the export format. scope \"recording\" (with clip) or \"movie\". Editing is locked until it ends and the owner's Stop cancels it. Never replaces a source recording. Ask the owner first.",
  inputSchema: {
    ...address,
    path: z.string(),
    scope: z.enum(["recording", "movie"]),
    clip: id.optional(),
    youtube: z.boolean().optional().describe("Export for YouTube: path is an existing folder for the video, its captions, thumbnail (or a Short's cover) and upload text."),
    short: id.optional().describe("Export one of the recording's Shorts (with clip): a 1080×1920 MP4, or with youtube its upload files."),
    overwrite: z.boolean().optional(),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("export", args)));

for (const [name, method, verb] of [["yamvideo_undo", "undo", "Undo"], ["yamvideo_redo", "redo", "Redo"]]) {
  server.registerTool(name, {
    title: `${verb} a step`,
    description: `${verb} the step named by transactionID (from state.history.${method}). Refused with history_conflict if another edit is now on top, so you never ${method} someone else's work by accident.`,
    inputSchema: { ...address, transactionID: id, requestID },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (args) => result(await request(method, args)));
}

server.registerTool("yamvideo_get_library", {
  title: "Read the owner's ideas",
  description: "The Library, apart from any project: every idea with its title, notes, topic, links, images (with paths you can look at), stage (idea or inProduction) and linked project; the topics in use; the Library's own revision and top undo/redo steps.",
  inputSchema: {},
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async () => result(await request("library")));

server.registerTool("yamvideo_apply_library", {
  title: "Change the owner's ideas",
  description: [
    "Apply 1–100 Library commands as one undo step on the Ideas page, against the Library revision you read (not the project's). Use the owner's own words, reuse existing topics, and ask before deleting. YamVideo never posts to any platform, and neither should you.",
    "addIdea {title, ideaID?, notes?, topic?, links?, paths? (images to copy in)} · updateIdea {ideaID, title?, notes?, topic? (\"\" clears), links? (the whole list)} · removeIdea {ideaID}",
    "addIdeaImages {ideaID, paths} · removeIdeaImage {ideaID, image (a name from images[].name)} · linkProject {ideaID, path? (a .yamvideo; left out: the saved project open in Studio)} · unlinkProject {ideaID}",
  ].join("\n"),
  inputSchema: {
    expectedRevision: z.number().int().nonnegative().describe("library.revision as you read it. If the Library changed since, the request is refused with revision_conflict: read it again."),
    commands: z.array(z.object({ type: z.string() }).passthrough()).min(1).max(100).describe("The Library commands, in order."),
    label: z.string().max(80).optional().describe("What the Undo menu should call this step, e.g. \"Sharpen the Claude idea\"."),
    dryRun: z.boolean().optional(),
    requestID,
  },
  annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
}, async (args) => result(await request("libraryApply", args)));

for (const [name, method, verb] of [["yamvideo_library_undo", "libraryUndo", "Undo"], ["yamvideo_library_redo", "libraryRedo", "Redo"]]) {
  server.registerTool(name, {
    title: `${verb} a Library step`,
    description: `${verb} the Library step named by transactionID (from yamvideo_apply_library or library.history). Refused with history_conflict if another Library change is now on top.`,
    inputSchema: {
      expectedRevision: z.number().int().nonnegative().describe("library.revision as you read it."),
      transactionID: id, requestID,
    },
    annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
  }, async (args) => result(await request(method, args)));
}

server.registerTool("yamvideo_reveal", {
  title: "Show something to the owner",
  description: "Move the owner's view to a recording, section, zoom, blur effect, marker or time, selecting it, or to an idea on the Ideas page. Edits never move their view; use this only when it helps them see what you mean.",
  inputSchema: {
    clip: id.optional(), section: id.optional(), zoom: id.optional(), effect: id.optional(), marker: id.optional(),
    graphic: id.optional(), short: id.optional().describe("A Short: shows it in the owner's Short viewer; time is then seconds into it."),
    idea: id.optional().describe("An idea from yamvideo_get_library: shows it on the Ideas page."),
    time: z.number().nonnegative().optional(), timeSpace: z.enum(["recording", "movie"]).optional(),
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("reveal", args)));

await server.connect(new StdioServerTransport());
console.error(`yamvideo-mcp ready (client "${client}", ctl ${ctl})`);
