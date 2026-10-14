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
      "Workflow: call yamvideo_get_state, plan, then yamvideo_apply_edits with the sessionID, projectID and revision you read. All commands in one call apply together or not at all.",
      "If you get revision_conflict, someone else (often the owner) edited meanwhile: read state again and replan. Never retry an edit with a guessed revision.",
      "Each applied call is one undo step credited to you. Use yamvideo_undo only for your own most recent step (the transactionID from state.history.undo).",
      "Times: split points and zoom starts are edited-recording seconds; trims and section ranges are source seconds; movie time only with timeSpace \"movie\".",
      "Look before and after with yamvideo_render_preview. Analysis proposes cuts or zooms but applies nothing. Ask the owner before exporting or saving over their file.",
    ].join("\n"),
  },
);

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
    "setExportSettings {settings: only the keys to change, e.g. {format: \"gif\", frameRate: 12}} · setSubtitles {clipID, path} · clearSubtitles {clipID} · addMedia {paths} · removeMedia {clipID} · relinkMedia {clipID, path}",
    "Colour (each recording's state.color shows the profile in effect and why, the conversion and any problem): setInputProfile {clipID, profile: auto|standard|pocket3DLogM|hlg|pq} · importTechnicalLUT {clipID, path to DJI's Pocket 3 D-Log M to Rec.709 .cube; needs profile pocket3DLogM} · clearTechnicalLUT {clipID} · setColorCorrection {clipID, enabled} (Natural colour) · setColorAdjustments {clipID, exposureEV? -2–2, warmth? -1–1, contrast? 0.5–1.5, saturation? 0–2} · resetColorAdjustments {clipID} · copyColorAdjustments {clipID (from), targets:[clipID], includeInterpretation? (also copy profile and conversion)}",
    "splitSection and zoom start accept timeSpace \"movie\" to give a movie time instead.",
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
    cropped: z.boolean().optional(),
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
  description: "Start a background job: \"silence\" proposes cuts (and the resulting sections) from audio levels; \"zooms\" proposes zooms from local visual activity. Nothing is applied — apply chosen results with yamvideo_apply_edits. Poll with yamvideo_get_job.",
  inputSchema: {
    sessionID: address.sessionID, projectID: address.projectID, clip: id, kind: z.enum(["silence", "zooms"]),
    threshold: z.number().optional().describe("Silence threshold in dB (default -40)."),
    minimum: z.number().positive().optional().describe("Shortest pause to cut, seconds (default 0.8)."),
    padding: z.number().nonnegative().optional().describe("Audio kept either side of a cut, seconds (default 0.15)."),
    requestID,
  },
  annotations: { readOnlyHint: true, openWorldHint: false },
}, async (args) => result(await request("analyze", args)));

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

server.registerTool("yamvideo_reveal", {
  title: "Show something to the owner",
  description: "Move the owner's view to a recording, section, zoom or time. Edits never move their view; use this only when it helps them see what you mean.",
  inputSchema: {
    clip: id.optional(), section: id.optional(), zoom: id.optional(),
    time: z.number().nonnegative().optional(), timeSpace: z.enum(["recording", "movie"]).optional(),
  },
  annotations: { readOnlyHint: false, destructiveHint: false, openWorldHint: false },
}, async (args) => result(await request("reveal", args)));

await server.connect(new StdioServerTransport());
console.error(`yamvideo-mcp ready (client "${client}", ctl ${ctl})`);
