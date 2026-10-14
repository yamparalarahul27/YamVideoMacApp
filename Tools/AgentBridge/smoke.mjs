#!/usr/bin/env node
// Drives server.mjs through the official MCP client over stdio, as Claude Code or Codex
// would, against a running YamVideo. Prints a JSON summary; exits 1 if any step failed.
// Run with a recording open. Its edits are undone before it finishes.

import path from "node:path";
import { fileURLToPath } from "node:url";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [path.join(here, "server.mjs")],
  env: { ...process.env, YAMVIDEO_CLIENT: process.env.YAMVIDEO_CLIENT || "MCP smoke test" },
  stderr: "ignore",
});
const client = new Client({ name: "yamvideo-smoke", version: "1.0.0" });
const steps = {};
const parse = (response) => JSON.parse(response.content.find((part) => part.type === "text").text);

try {
  await client.connect(transport);
  const tools = (await client.listTools()).tools.map((tool) => tool.name);
  steps.tools = tools.length;
  // The catalog is how an agent learns the app; it has to come through the MCP client whole.
  const catalog = parse(await client.callTool({ name: "yamvideo_describe", arguments: {} })).result;
  if (!catalog?.commands?.some((command) => command.type === "addBlurEffect" && command.example?.type === "addBlurEffect")) {
    throw new Error("yamvideo_describe did not describe addBlurEffect with an example.");
  }
  steps.catalog = catalog.commands.length;

  steps.sessions = parse(await client.callTool({ name: "yamvideo_list_sessions", arguments: {} })).ok;
  const state = parse(await client.callTool({ name: "yamvideo_get_state", arguments: {} })).result;
  const clip = state.clips.find((candidate) => candidate.media);
  if (!clip) throw new Error("Open a project with a loaded recording first.");
  const at = { sessionID: state.sessionID, projectID: state.projectID, expectedRevision: state.revision };
  const box = { type: "addBlurArea", clipID: clip.id, rect: { x: 0, y: 0, width: 64, height: 64 } };

  const dry = parse(await client.callTool({ name: "yamvideo_apply_edits", arguments: { ...at, commands: [box], dryRun: true } }));
  steps.dryRun = dry.ok && dry.result.changed && dry.result.revision === state.revision;

  const applied = await client.callTool({ name: "yamvideo_apply_edits", arguments: { ...at, commands: [box], label: "Smoke test blur" } });
  const receipt = parse(applied).result;
  steps.apply = !applied.isError && receipt.revision === state.revision + 1;

  const stale = await client.callTool({ name: "yamvideo_apply_edits", arguments: { ...at, commands: [box] } });
  steps.conflict = stale.isError === true && parse(stale).error.code === "revision_conflict";

  const preview = await client.callTool({ name: "yamvideo_render_preview", arguments: { clip: clip.id, time: 0.2 } });
  steps.preview = !preview.isError && preview.content.some((part) => part.type === "image" && part.data.length > 100);

  const undo = await client.callTool({ name: "yamvideo_undo", arguments: {
    sessionID: state.sessionID, projectID: state.projectID, expectedRevision: receipt.revision, transactionID: receipt.transactionID } });
  steps.undo = !undo.isError;
} catch (error) {
  steps.error = error.message;
} finally {
  await client.close().catch(() => {});
}

const ok = !steps.error && ["sessions", "dryRun", "apply", "conflict", "preview", "undo"].every((name) => steps[name] === true);
console.log(JSON.stringify({ ok, steps }));
process.exit(ok ? 0 : 1);
