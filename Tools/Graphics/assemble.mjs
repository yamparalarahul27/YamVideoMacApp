#!/usr/bin/env node
// Writes a HyperFrames page for a graphics JSON file, using the engine in
// Resources/Graphics. See docs/plans/graphics-track.md and README.md next to this file.
//
//   node Tools/Graphics/assemble.mjs --graphics g.json --out DIR --mode full --video cut.mp4 [--fill small.mp4]
//   node Tools/Graphics/assemble.mjs --graphics g.json --out DIR --mode unit --unit ID
//   node Tools/Graphics/assemble.mjs --graphics g.json --units
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const engineDir = path.resolve(here, "../../Resources/Graphics");
const engine = createRequire(import.meta.url)(path.join(engineDir, "graphics.js"));

function fail(message) {
  console.error("assemble: " + message);
  process.exit(2);
}

const args = {};
for (let i = 2; i < process.argv.length; i++) {
  const key = process.argv[i];
  if (!key.startsWith("--")) fail("unexpected argument " + key);
  const next = process.argv[i + 1];
  if (next === undefined || next.startsWith("--")) args[key.slice(2)] = true;
  else { args[key.slice(2)] = next; i++; }
}
if (!args.graphics) fail("--graphics FILE is required");

const graphicsPath = path.resolve(args.graphics);
const data = JSON.parse(fs.readFileSync(graphicsPath, "utf8"));
const plan = engine.plan(data);

if (args.units) {
  console.log(JSON.stringify(plan.units, null, 2));
  process.exit(0);
}

const mode = args.mode || "full";
if (!["full", "unit", "preview"].includes(mode)) fail("--mode must be full, unit or preview");
if (!args.out) fail("--out DIR is required");
const out = path.resolve(args.out);
fs.mkdirSync(path.join(out, "media"), { recursive: true });
fs.mkdirSync(path.join(out, "fonts"), { recursive: true });

// The engine, copied so that the page has no paths outside its folder.
for (const file of ["graphics.js", "graphics.css", "gsap.min.js"]) {
  fs.copyFileSync(path.join(engineDir, file), path.join(out, file));
}
for (const font of fs.readdirSync(path.join(engineDir, "fonts"))) {
  fs.copyFileSync(path.join(engineDir, "fonts", font), path.join(out, "fonts", font));
}

// Images: every "image" value resolves against the JSON file's folder and is copied in
// under a content-hash name, so two images with one file name cannot collide.
const base = path.dirname(graphicsPath);
function copyImages(node) {
  if (Array.isArray(node)) return node.map(copyImages);
  if (!node || typeof node !== "object") return node;
  const copy = {};
  for (const [key, value] of Object.entries(node)) {
    if (key === "image" && typeof value === "string") {
      const source = path.resolve(base, value);
      if (!fs.existsSync(source)) fail("missing image " + source);
      const bytes = fs.readFileSync(source);
      const name = crypto.createHash("sha1").update(bytes).digest("hex").slice(0, 10) + path.extname(source).toLowerCase();
      fs.writeFileSync(path.join(out, "media", name), bytes);
      copy[key] = "media/" + name;
    } else {
      copy[key] = copyImages(value);
    }
  }
  return copy;
}
const pageData = copyImages(data);

let duration;
let media = "";
const options = { mode };
if (mode === "unit") {
  const unit = plan.units.find((u) => u.id === args.unit);
  if (!unit) fail("unknown --unit " + args.unit + "; see --units");
  duration = unit.end - unit.start;
  options.unit = unit.id;
} else {
  duration = Number(args.duration || data.duration);
  if (!(duration > 0)) fail("--duration or a duration in the JSON is required");
}
if (mode === "full") {
  if (!args.video) fail("--video FILE is required in full mode");
  const video = path.resolve(args.video);
  const link = path.join(out, "video" + path.extname(video).toLowerCase());
  fs.rmSync(link, { force: true });
  fs.symlinkSync(video, link);
  const src = path.basename(link);
  // The fill is blurred, so a small copy of the video (--fill) is enough and decodes faster.
  let fillSrc = src;
  if (args.fill) {
    const fill = path.resolve(args.fill);
    const fillLink = path.join(out, "fill" + path.extname(fill).toLowerCase());
    fs.rmSync(fillLink, { force: true });
    fs.symlinkSync(fill, fillLink);
    fillSrc = path.basename(fillLink);
  }
  media =
    `<video id="bg-fill" class="clip" src="${fillSrc}" muted playsinline data-start="0" data-duration="${duration}" data-track-index="0"></video>\n` +
    `<video id="bg-video" class="clip" src="${src}" muted playsinline data-start="0" data-duration="${duration}" data-track-index="1"></video>\n` +
    `<audio id="bg-audio" class="clip" src="${src}" data-start="0" data-duration="${duration}" data-track-index="10" data-volume="1"></audio>`;
}

const rate = String(data.fps || "30").split("/").reduce((a, b) => Number(a) / Number(b));
const page = fs.readFileSync(path.join(engineDir, "page.html"), "utf8")
  .replaceAll("{{MODE}}", mode)
  .replaceAll("{{DURATION}}", String(Math.round(duration * 1000) / 1000))
  .replaceAll("{{FPS}}", String(Math.round(rate)))
  .replace("{{MEDIA}}", media)
  .replace("{{JSON}}", JSON.stringify(pageData).replace(/</g, "\\u003c"))
  .replace("{{OPTIONS}}", JSON.stringify(options));
fs.writeFileSync(path.join(out, "index.html"), page);
console.log(JSON.stringify({ out, mode, duration, units: plan.units.length }));
