/* Offline UI concept. No app connection, media processing, LUTs or uploads. */
"use strict";
const $ = (id) => document.getElementById(id);
const esc = (value) =>
  String(value).replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ],
  );
const clone = (value) => JSON.parse(JSON.stringify(value));
let nextID = 10;
const uid = () => `demo-${nextID++}`;
const neutral = () => ({
  brightness: 0,
  warmth: 0,
  contrast: 1,
  saturation: 1,
});
const makeClip = (id, name, duration, image, profile) => ({
  id,
  name,
  image,
  profile,
  corrected: profile === "dlog",
  color: neutral(),
  segments: [{ id: `${id}-a`, start: 0, end: duration, speed: 1 }],
  zooms: [],
  blur: null,
});
let clips = [
  makeClip("coast", "Morning coast", 36, "coast.svg", "dlog"),
  makeClip("cafe", "Coffee stop", 18, "cafe.svg", "standard"),
  makeClip("title", "Opening title", 4, "coast.svg", "generated"),
];
clips[0].segments = [
  { id: "coast-a", start: 0, end: 12, speed: 1 },
  { id: "coast-b", start: 12, end: 24, speed: 1 },
  { id: "coast-c", start: 24, end: 36, speed: 1 },
];
clips[0].zooms = [{ id: "zoom-1", start: 12, end: 18 }];
let selected = "coast",
  selectedSegment = "coast-a",
  tab = "colour",
  view = "corrected",
  time = 5.2,
  movie = false,
  playing = false,
  pausedAgents = false,
  snapping = true,
  lastFrame = 0;
const undoStack = [],
  redoStack = [];
let activities = [
  {
    origin: "You",
    label: "Opened Weekend on the coast",
    detail: "Demo session ready",
  },
];
let gesture = null,
  toastTimer;
const current = () => clips.find((c) => c.id === selected) || clips[0];
const duration = (c) =>
  c.segments.reduce((n, s) => n + (s.end - s.start) / s.speed, 0);
const total = () =>
  movie ? clips.reduce((n, c) => n + duration(c), 0) : duration(current());
function clock(t) {
  const n = Math.max(0, t);
  return `${String(Math.floor(n / 60)).padStart(2, "0")}:${(n % 60).toFixed(2).padStart(5, "0")}`;
}
function notify(text) {
  $("toast").textContent = text;
  $("toast").hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => ($("toast").hidden = true), 3500);
}
function activity(origin, label, detail = "Just now") {
  activities.unshift({ origin, label, detail });
  activities = activities.slice(0, 12);
  renderActivity();
  $("statusText").textContent = `${origin}: ${label}`;
}
function endGesture() {
  if (!gesture) return;
  const { before, label } = gesture;
  gesture = null;
  // A drag released at its starting value changes nothing and records nothing.
  commit(label, () => {}, "You", before);
}
function commit(label, mutate, origin = "You", before = null) {
  // Close any open slider gesture first so its snapshot never spans this edit.
  if (!before) endGesture();
  const previous = before || clone(clips);
  mutate();
  if (JSON.stringify(previous) === JSON.stringify(clips)) return;
  undoStack.push({ clips: previous, label, origin });
  redoStack.length = 0;
  time = Math.min(time, Math.max(0, total() - 0.01));
  activity(origin, label);
  render();
}
function history(redo = false) {
  endGesture();
  const focused = document.activeElement?.id;
  const from = redo ? redoStack : undoStack,
    to = redo ? undoStack : redoStack,
    entry = from.pop();
  if (!entry) return;
  to.push({ clips: clone(clips), label: entry.label, origin: entry.origin });
  clips = clone(entry.clips);
  if (!clips.some((c) => c.id === selected)) selected = clips[0].id;
  if (!current().segments.some((s) => s.id === selectedSegment))
    selectedSegment = current().segments[0].id;
  time = Math.min(time, Math.max(0, total() - 0.01));
  activity(
    "You",
    `${redo ? "Redid" : "Undid"} ${entry.origin === "You" ? "your edit" : entry.origin + "'s edit"}`,
    entry.label,
  );
  render();
  if (focused) $(focused)?.focus({ preventScroll: true });
}
function choose(id) {
  selected = id;
  selectedSegment = current().segments[0].id;
  time = 0;
  playing = false;
  movie = false;
  render();
}
function renderMedia() {
  $("mediaCount").textContent = `${clips.length} items`;
  $("mediaList").innerHTML = clips
    .map(
      (c) =>
        `<button class="media-item ${c.id === selected ? "selected" : ""}" data-clip="${esc(c.id)}" aria-pressed="${c.id === selected}"><span class="media-thumb ${c.profile === "generated" ? "title-thumb" : ""}"><img src="${esc(c.image)}" alt=""></span><span class="media-info"><strong>${esc(c.name)}</strong><span>${clock(duration(c)).slice(0, 5)} · ${c.profile === "dlog" ? "D-Log M" : c.profile === "generated" ? "Title concept" : "Standard"}</span></span></button>`,
    )
    .join("");
  $("mediaList")
    .querySelectorAll("[data-clip]")
    .forEach((b) => (b.onclick = () => choose(b.dataset.clip)));
}
function slider(id, label, min, max, step, value, formatted) {
  return `<div class="adjustment"><div class="adjustment-head"><label for="${id}">${label}</label><output id="${id}Value" for="${id}">${formatted}</output></div><input type="range" id="${id}" min="${min}" max="${max}" step="${step}" value="${value}"></div>`;
}
function formatValue(id, value) {
  return id === "brightness"
    ? `${value > 0 ? "+" : ""}${value.toFixed(1)}`
    : id === "warmth"
      ? `${value > 0 ? "+" : ""}${Math.round(value * 100)}`
      : `${Math.round(value * 100)}%`;
}
function renderInspector() {
  const c = current();
  $("inspectorTitle").textContent = c.name;
  document.querySelectorAll("[data-tab]").forEach((b) => {
    b.classList.toggle("active", b.dataset.tab === tab);
    b.setAttribute("aria-pressed", b.dataset.tab === tab);
  });
  if (movie) {
    $("inspectorBody").innerHTML =
      `<h3>Movie assembly</h3><p class="hint">${clips.length} recordings · ${clock(total())} total</p><div class="inspector-divider"></div><p class="hint">Select a recording in the timeline to edit its cuts, colour or effects. Each recording keeps its own adjustments.</p><button class="secondary full-width" id="editRecording" style="margin-top:16px">Edit ${esc(c.name)}</button>`;
    $("editRecording").onclick = () => choose(c.id);
    return;
  }
  if (tab === "colour") {
    $("inspectorBody").innerHTML =
      `<label class="field-label" for="profile">Recorded colour</label><select id="profile"><option value="dlog">DJI Pocket 3 D-Log M</option><option value="standard">Standard / already corrected</option><option value="generated">Generated graphic</option></select><p class="hint">Choose the mode used on your camera.</p>${c.profile === "dlog" ? `<div class="correction-control"><div class="correction-head"><svg><use href="#i-check"/></svg><strong>Natural colour</strong><button class="switch" id="correction" role="switch" aria-label="Natural colour correction" aria-checked="${c.corrected}"></button></div><p>A natural starting point for standard screens.</p></div>` : '<p class="hint">No camera conversion needed for this selection.</p>'}<div class="adjustments-heading"><strong>Make it your own</strong><button class="text-button" id="resetColor">Reset</button></div>${slider("brightness", "Brightness", -2, 2, 0.1, c.color.brightness, formatValue("brightness", c.color.brightness))}${slider("warmth", "Warmth", -1, 1, 0.05, c.color.warmth, formatValue("warmth", c.color.warmth))}${slider("contrast", "Contrast", 0.5, 1.5, 0.05, c.color.contrast, formatValue("contrast", c.color.contrast))}${slider("saturation", "Colour strength", 0, 2, 0.05, c.color.saturation, formatValue("saturation", c.color.saturation))}<div class="inspector-divider"></div><button class="copy-button" id="copyColor">Copy adjustments to other recordings</button><details class="detail-disclosure"><summary>About this colour preview</summary><p>CSS changes illustrate the controls. The app will use DJI's camera-specific conversion and a shared colour pipeline. No real LUT is applied here.</p></details>`;
    $("profile").value = c.profile;
    $("profile").onchange = (e) =>
      commit("Changed recorded colour", () => {
        c.profile = e.target.value;
        c.corrected = c.profile === "dlog";
      });
    if ($("correction"))
      $("correction").onclick = () =>
        commit("Changed natural colour", () => (c.corrected = !c.corrected));
    $("resetColor").onclick = () =>
      commit("Reset colour adjustments", () => (c.color = neutral()));
    $("copyColor").onclick = () => {
      commit("Copied colour adjustments", () =>
        clips
          .filter((x) => x.id !== c.id && x.profile !== "generated")
          .forEach((x) => (x.color = clone(c.color))),
      );
      notify("Adjustments copied. Camera profiles and conversions were kept.");
    };
    ["brightness", "warmth", "contrast", "saturation"].forEach((id) =>
      bindSlider(
        id,
        (v) => (c.color[id] = v),
        (v) => formatValue(id, v),
        "Adjusted " + ({ saturation: "colour strength" }[id] || id),
      ),
    );
  } else if (tab === "edit") {
    const s = c.segments.find((s) => s.id === selectedSegment) || c.segments[0];
    selectedSegment = s.id;
    $("inspectorBody").innerHTML =
      `<h3>Selected section</h3><p class="hint">${clock((s.end - s.start) / s.speed)} of playback</p><div class="field-pair edit-field"><label>Source in<input type="number" id="trimStart" min="0" step=".1" value="${s.start.toFixed(2)}"></label><label>Source out<input type="number" id="trimEnd" min="0" step=".1" value="${s.end.toFixed(2)}"></label></div><label class="field-label" for="speed">Playback speed</label><select id="speed">${[0.25, 0.5, 1, 1.5, 2, 4].map((v) => `<option value="${v}">${v}×${v === 1 ? " · Normal" : ""}</option>`).join("")}</select><p class="hint">Trim a section or change its pace. The remaining sections stay together.</p><div class="inspector-divider"></div><button class="secondary full-width" id="splitInspector"><svg><use href="#i-scissors"/></svg>Split at playhead</button><button class="text-button full-width" id="deleteInspector">Delete selected section</button><details class="detail-disclosure"><summary>Prototype scope</summary><p>Timing, section speed and undo are simulated in the browser. The sample picture is not a video file.</p></details>`;
    $("speed").value = s.speed;
    $("speed").onchange = (e) =>
      commit("Changed section speed", () => {
        s.speed = Number(e.target.value);
        clampEffects(c);
      });
    ["trimStart", "trimEnd"].forEach(
      (id) =>
        ($(id).onchange = (e) => {
          const n = Number(e.target.value);
          const others = c.segments.filter((x) => x.id !== s.id);
          const lo = id === "trimStart" ? n : s.start,
            hi = id === "trimEnd" ? n : s.end;
          if (
            !Number.isFinite(n) ||
            lo < 0 ||
            hi <= lo ||
            hi >
              (c.id === "coast"
                ? 36
                : c.id === "cafe"
                  ? 18
                  : c.sourceDuration || 4) ||
            others.some((x) => lo < x.end && hi > x.start)
          ) {
            notify(
              "Keep a valid source range that does not overlap another section.",
            );
            renderInspector();
            return;
          }
          commit("Trimmed section", () => {
            s.start = lo;
            s.end = hi;
            clampEffects(c);
          });
        }),
    );
    $("splitInspector").onclick = split;
    $("deleteInspector").onclick = removeSection;
  } else {
    $("inspectorBody").innerHTML =
      `<span class="phase-label">Planned after the editing foundation</span><h3>Whole-frame blur</h3><p class="hint">A soft visual effect over the whole image. Existing privacy blur stays separate.</p>${c.blur ? `<div class="effect-card"><strong>Blur effect</strong><p>${clock(c.blur.start)} — ${clock(c.blur.end)}</p>${slider("blurAmount", "Amount", 0, 80, 1, c.blur.amount, c.blur.amount)}<button class="secondary full-width" id="previewBlur">Preview effect</button><button class="text-button full-width" id="removeBlur">Remove blur</button></div>` : '<button class="secondary full-width" id="addBlur" style="margin-top:15px"><svg><use href="#i-plus"/></svg>Add blur at playhead</button>'}<div class="inspector-divider"></div><h3>Zooms</h3><p class="hint">${c.zooms.length} gentle push-in${c.zooms.length === 1 ? "" : "s"} on this recording.</p><button class="copy-button" id="addZoom" style="margin-top:12px">Add a gentle zoom</button><details class="detail-disclosure"><summary>What comes later?</summary><p>Stacked video, blend modes and Remotion overlays need a separate layer model. This preview keeps the existing sequential timeline.</p></details>`;
    if (c.blur) {
      bindSlider(
        "blurAmount",
        (v) => (c.blur.amount = v),
        (v) => String(v),
        "Adjusted blur amount",
      );
      $("previewBlur").onclick = () => {
        movie = false;
        time = (c.blur.start + c.blur.end) / 2;
        render();
      };
      $("removeBlur").onclick = () =>
        commit("Removed blur", () => (c.blur = null));
    } else
      $("addBlur").onclick = () => {
        if (movie) {
          notify("Open a recording to add a blur effect.");
          return;
        }
        const start = Math.min(time, Math.max(0, duration(c) - 3));
        commit(
          "Added full-frame blur",
          () =>
            (c.blur = {
              start,
              end: Math.min(duration(c), start + 3),
              amount: 24,
            }),
        );
        notify("Blur added. Use Preview effect to see the middle of the fade.");
      };
    $("addZoom").onclick = () => addZoom("You");
  }
}
function bindSlider(id, set, format, label) {
  const element = $(id);
  // A held arrow key repeats input/change; keep it one gesture until keyup.
  let keyHeld = false;
  const finish = () => {
    if (gesture?.id !== id) return;
    endGesture();
    $(id)?.focus({ preventScroll: true });
  };
  element.oninput = () => {
    if (gesture?.id !== id) {
      endGesture();
      gesture = { before: clone(clips), id, label };
    }
    set(Number(element.value));
    $(id + "Value").textContent = format(Number(element.value));
    renderFrame();
  };
  element.onkeydown = (e) => {
    if (!e.metaKey && !e.ctrlKey && /^(Arrow|Page|Home|End)/.test(e.key))
      keyHeld = true;
  };
  element.onkeyup = () => {
    if (!keyHeld) return;
    keyHeld = false;
    finish();
  };
  element.onchange = () => {
    if (!keyHeld) finish();
  };
  // A drag released at its starting value fires no change event.
  element.onpointerup = element.onpointercancel = finish;
}
function clampEffects(c) {
  const d = duration(c);
  c.zooms = c.zooms
    .map((z) => ({ ...z, end: Math.min(z.end, d) }))
    .filter((z) => z.end - z.start > 0.1);
  if (c.blur) {
    c.blur.end = Math.min(c.blur.end, d);
    if (c.blur.start >= c.blur.end) c.blur = null;
  }
}
function displayClip() {
  if (!movie) return { clip: current(), local: time };
  let t = time;
  for (const c of clips) {
    if (t < duration(c)) return { clip: c, local: t };
    t -= duration(c);
  }
  return { clip: clips[clips.length - 1], local: 0 };
}
function renderFrame() {
  const { clip: c, local } = displayClip(),
    color = c.color;
  $("viewerTitle").textContent = movie ? "Weekend on the coast" : c.name;
  $("sourceBadge").textContent =
    c.profile === "dlog"
      ? "DJI Pocket 3 · D-Log M"
      : c.profile === "generated"
        ? "Generated title · Demo"
        : "Standard colour · Demo";
  ["gradedScene", "originalScene"].forEach((id) => {
    if (!$(id).getAttribute("src").endsWith(c.image)) $(id).src = c.image;
  });
  const converted = c.profile !== "dlog" || c.corrected,
    baseS = converted ? 1.06 : 0.53,
    baseC = converted ? 1.05 : 0.7,
    baseB = converted ? 1 : 1.13;
  const blur =
    c.blur && local >= c.blur.start && local < c.blur.end
      ? (c.blur.amount / 5) *
        Math.min(1, (local - c.blur.start) / 0.25, (c.blur.end - local) / 0.25)
      : 0;
  $("gradedScene").style.filter =
    `saturate(${baseS * color.saturation}) contrast(${baseC * color.contrast}) brightness(${baseB * Math.pow(2, color.brightness * 0.35)}) sepia(${Math.max(0, color.warmth) * 0.35}) hue-rotate(${Math.min(0, color.warmth) * 16}deg) blur(${blur}px)`;
  $("originalScene").style.filter =
    c.profile === "dlog"
      ? "saturate(.53) contrast(.7) brightness(1.13)"
      : "none";
  const z = c.zooms.find((z) => local >= z.start && local < z.end),
    factor = z
      ? 1 +
        0.5 *
          Math.max(
            0,
            Math.min(1, (local - z.start) / 0.7, (z.end - local) / 0.7),
          )
      : 1;
  ["gradedScene", "originalScene"].forEach(
    (id) => ($(id).style.transform = `scale(${factor})`),
  );
  $("zoomBadge").hidden = !z;
  $("titleOverlay").hidden = c.profile !== "generated";
  const compare = view === "compare",
    pos = Number($("compareRange").value);
  $("originalLayer").style.clipPath =
    `inset(0 ${view === "original" ? 0 : compare ? 100 - pos : 100}% 0 0)`;
  ["originalLabel", "correctedLabel", "compareDivider", "compareRange"].forEach(
    (id) => ($(id).hidden = !compare),
  );
  $("compareDivider").style.left = pos + "%";
  document.querySelectorAll("[data-view]").forEach((b) => {
    b.classList.toggle("active", b.dataset.view === view);
    b.setAttribute("aria-pressed", b.dataset.view === view);
  });
  $("previewNote").textContent =
    view === "original"
      ? "Original colour"
      : c.profile === "dlog"
        ? c.corrected
          ? "Natural colour applied"
          : "Camera correction off"
        : "Your colour adjustments";
  $("currentTime").textContent = clock(time);
  $("totalTime").textContent = clock(total());
  $("playhead").style.left =
    `calc(${(time / Math.max(total(), 0.1)) * 100}% - ${(time / Math.max(total(), 0.1)) * 20}px)`;
  $("playBtn").innerHTML =
    `<svg><use href="#i-${playing ? "pause" : "play"}"/></svg>`;
  $("playBtn").setAttribute(
    "aria-label",
    playing ? "Pause simulated preview" : "Play simulated preview",
  );
}
function renderTimeline() {
  const d = total();
  $("timelineContent").style.width =
    Number($("timelineZoom").value) * 100 + "%";
  const spacing = d > 40 ? 10 : d > 15 ? 5 : 1;
  let ticks = "";
  for (let t = 0; t < d; t += spacing)
    ticks += `<span class="ruler-tick" style="left:${(t / d) * 100}%">${clock(t).slice(0, 5)}</span>`;
  $("ruler").innerHTML = ticks;
  const entries = movie
    ? clips.map((c) => ({ clip: c, segment: null, length: duration(c) }))
    : current().segments.map((s) => ({
        clip: current(),
        segment: s,
        length: (s.end - s.start) / s.speed,
      }));
  $("videoLane").innerHTML = entries
    .map(
      ({ clip: c, segment: s, length }, i) =>
        `<button class="timeline-clip ${!movie && s.id === selectedSegment ? "selected" : ""}" style="width:calc(${(length / d) * 100}% - 3px)" data-id="${esc(s ? s.id : c.id)}" aria-label="${esc(c.name)} ${movie ? "" : "section " + (i + 1)}; ${length.toFixed(1)} seconds"><span class="clip-filmstrip">${Array.from({ length: 12 }, () => `<img src="${esc(c.image)}" alt="">`).join("")}</span><span class="clip-text">${esc(c.name)}${s && s.speed !== 1 ? " · " + s.speed + "×" : ""}</span><span class="clip-duration">${length.toFixed(1)}s</span></button>`,
    )
    .join("");
  $("videoLane")
    .querySelectorAll("button")
    .forEach(
      (b) =>
        (b.onclick = () => {
          if (movie) {
            choose(b.dataset.id);
            return;
          }
          selectedSegment = b.dataset.id;
          tab = "edit";
          render();
        }),
    );
  let lines = "";
  for (let i = 0; i < 500; i++) {
    const h = 3 + Math.abs(Math.sin(i * 0.41) * Math.cos(i * 0.13)) * 25;
    lines += `<path d="M${i * 2} ${17 - h / 2}v${h}"/>`;
  }
  $("waveform").innerHTML = lines;
  const offsetClips = movie ? clips : [current()];
  let offset = 0,
    zooms = "",
    blurs = "";
  for (const c of offsetClips) {
    for (const z of c.zooms)
      zooms += `<button class="effect-block" data-clip="${c.id}" style="left:${((offset + z.start) / d) * 100}%;width:${((z.end - z.start) / d) * 100}%" title="Gentle zoom">Push in</button>`;
    if (c.blur)
      blurs += `<button class="effect-block" data-clip="${c.id}" style="left:${((offset + c.blur.start) / d) * 100}%;width:${((c.blur.end - c.blur.start) / d) * 100}%" title="Full-frame blur">Blur</button>`;
    offset += duration(c);
  }
  $("zoomLane").innerHTML =
    zooms || '<span class="empty-lane-label">No zooms on this recording</span>';
  $("blurLane").innerHTML =
    blurs ||
    '<span class="empty-lane-label">Add a visual effect from the inspector</span>';
  document.querySelectorAll(".effect-block").forEach(
    (b) =>
      (b.onclick = () => {
        if (movie) choose(b.dataset.clip);
        tab = "effects";
        render();
      }),
  );
  $("splitBtn").disabled = movie;
  $("deleteBtn").disabled = movie || current().segments.length === 1;
  $("recordingBtn").classList.toggle("active", !movie);
  $("movieBtn").classList.toggle("active", movie);
  $("recordingBtn").setAttribute("aria-pressed", !movie);
  $("movieBtn").setAttribute("aria-pressed", movie);
}
function renderActivity() {
  $("activityList").innerHTML = activities
    .slice(0, 5)
    .map(
      (a) =>
        `<div class="activity-entry"><strong>${esc(a.origin)} · ${esc(a.label)}</strong><p>${esc(a.detail)}</p></div>`,
    )
    .join("");
  ["codexDemo", "claudeDemo", "conflictDemo"].forEach(
    (id) => ($(id).disabled = pausedAgents),
  );
  $("pauseAgents").textContent = pausedAgents
    ? "Resume agent edits"
    : "Pause agent edits";
  document
    .querySelectorAll(".agent-availability")
    .forEach((e) => (e.textContent = pausedAgents ? "Paused" : "Connected"));
}
function render() {
  renderMedia();
  renderInspector();
  renderTimeline();
  renderFrame();
  renderActivity();
  $("undoBtn").disabled = !undoStack.length;
  $("redoBtn").disabled = !redoStack.length;
  $("dirty").hidden = !undoStack.length;
}
function split() {
  if (movie) return;
  const c = current();
  let offset = 0;
  for (const s of c.segments) {
    const length = (s.end - s.start) / s.speed;
    if (time > offset + 0.1 && time < offset + length - 0.1) {
      const at = s.start + (time - offset) * s.speed;
      commit("Split section", () => {
        const right = { ...s, id: uid(), start: at };
        s.end = at;
        c.segments.splice(c.segments.indexOf(s) + 1, 0, right);
        selectedSegment = right.id;
        tab = "edit";
      });
      return;
    }
    offset += length;
  }
  notify("Move the playhead inside a section to split it.");
}
function removeSection() {
  if (movie) return;
  const c = current();
  if (c.segments.length < 2) {
    notify("Keep at least one section in this recording.");
    return;
  }
  commit("Deleted section", () => {
    c.segments = c.segments.filter((s) => s.id !== selectedSegment);
    selectedSegment = c.segments[0].id;
    clampEffects(c);
  });
}
function addZoom(origin) {
  if (movie) {
    notify("Open a recording to add a zoom.");
    return;
  }
  if (origin !== "You" && pausedAgents) return;
  const c = current();
  let start = Math.min(time, Math.max(0, duration(c) - 4));
  while (
    start + 2 <= duration(c) &&
    c.zooms.some((z) => start < z.end && start + 4 > z.start)
  )
    start += 0.5;
  if (start + 2 > duration(c)) {
    notify(
      "No free interval here. Choose another recording or undo an existing zoom.",
    );
    return;
  }
  commit(
    "Added a gentle zoom",
    () =>
      c.zooms.push({ id: uid(), start, end: Math.min(duration(c), start + 4) }),
    origin,
  );
  $("zoomLane").classList.remove("changed");
  void $("zoomLane").offsetWidth;
  $("zoomLane").classList.add("changed");
}
function setMovie(value) {
  movie = value;
  time = 0;
  playing = false;
  render();
}
function togglePlay() {
  playing = !playing;
  if (playing && time >= total() - 0.02) time = 0;
  lastFrame = 0;
  renderFrame();
}
function tick(now) {
  if (playing) {
    if (lastFrame) {
      time += Math.min(0.1, (now - lastFrame) / 1000);
      if (time >= total()) {
        time = total();
        playing = false;
      }
      renderFrame();
    }
    lastFrame = now;
  } else lastFrame = 0;
  requestAnimationFrame(tick);
}
$("undoBtn").onclick = () => history();
$("redoBtn").onclick = () => history(true);
document.querySelectorAll("[data-tab]").forEach(
  (b) =>
    (b.onclick = () => {
      tab = b.dataset.tab;
      renderInspector();
    }),
);
document.querySelectorAll("[data-view]").forEach(
  (b) =>
    (b.onclick = () => {
      view = b.dataset.view;
      renderFrame();
    }),
);
$("compareRange").oninput = renderFrame;
$("playBtn").onclick = togglePlay;
$("startBtn").onclick = () => {
  time = 0;
  renderFrame();
};
$("splitBtn").onclick = split;
$("deleteBtn").onclick = removeSection;
$("recordingBtn").onclick = () => setMovie(false);
$("movieBtn").onclick = () => setMovie(true);
$("ruler").onclick = (e) => {
  const rect = $("ruler").getBoundingClientRect();
  time = Math.max(
    0,
    Math.min(total(), ((e.clientX - rect.left) / rect.width) * total()),
  );
  if (snapping) {
    const frame = 1 / 30;
    time = Math.round(time / frame) * frame;
  }
  renderFrame();
};
$("timelineZoom").oninput = () => {
  renderTimeline();
  renderFrame();
};
$("fitBtn").onclick = () => {
  $("timelineZoom").value = 1;
  $("timelineScroll").scrollLeft = 0;
  renderTimeline();
  renderFrame();
};
$("snapBtn").onclick = () => {
  snapping = !snapping;
  $("snapBtn").setAttribute("aria-pressed", snapping);
  $("snapBtn").querySelector("span").textContent = snapping ? "On" : "Off";
};
function agents(open) {
  $("agentsPanel").hidden = !open;
  $("agentsBtn").setAttribute("aria-expanded", open);
}
$("agentsBtn").onclick = () => agents($("agentsPanel").hidden);
$("closeAgents").onclick = () => {
  agents(false);
  $("agentsBtn").focus();
};
$("pauseAgents").onclick = () => {
  pausedAgents = !pausedAgents;
  renderActivity();
};
$("codexDemo").onclick = () => addZoom("Codex");
$("claudeDemo").onclick = () => {
  if (pausedAgents) return;
  commit(
    "Warmed up the colour",
    () => (current().color.warmth = Math.min(1, current().color.warmth + 0.2)),
    "Claude",
  );
};
$("conflictDemo").onclick = () => {
  if (pausedAgents) return;
  activity(
    "Claude",
    "Edit held for review",
    "The project changed since this proposed edit. Read the latest state and try again. No edit was applied.",
  );
  notify("Conflict handled: your current edit was kept.");
};
$("guideBtn").onclick = () => $("guideDialog").showModal();
$("exportBtn").onclick = () => {
  $("exportSummary").textContent =
    `${total().toFixed(1)} seconds · 1920 × 1080`;
  $("exportScope").selectedIndex = movie ? 1 : 0;
  $("exportDialog").showModal();
};
$("exportScope").onchange = () => {
  $("exportSummary").textContent =
    `${($("exportScope").selectedIndex === 0 ? duration(current()) : clips.reduce((n, c) => n + duration(c), 0)).toFixed(1)} seconds · 1920 × 1080`;
};
$("exportDemo").onclick = () => {
  $("exportDialog").close();
  notify("Export flow previewed. No video was rendered.");
};
$("addMediaBtn").onclick = () => $("fileInput").click();
$("fileInput").onchange = (e) => {
  const files = Array.from(e.target.files);
  if (!files.length) return;
  commit("Added demo media entries", () =>
    files.forEach((f) => {
      const c = makeClip(uid(), f.name, 12, "coast.svg", "standard");
      c.sourceDuration = 12;
      clips.push(c);
    }),
  );
  notify(
    "Names added to the demo. Files were not uploaded or decoded; duration is illustrative.",
  );
  e.target.value = "";
};
document.addEventListener("keydown", (e) => {
  if (document.querySelector("dialog[open]")) return;
  const command = (e.metaKey || e.ctrlKey) && e.key.toLowerCase();
  // Sliders and menus have no undo of their own; text fields keep theirs.
  if (
    (command === "z" || command === "b") &&
    !e.target.closest("textarea, input:not([type=range])")
  ) {
    e.preventDefault();
    if (command === "z") history(e.shiftKey);
    else split();
    return;
  }
  if (e.target.closest("input,select,textarea")) return;
  if (e.code === "Space" && !e.target.closest("button")) {
    e.preventDefault();
    togglePlay();
  }
  if (e.key === "Escape") agents(false);
});
render();
requestAnimationFrame(tick);
