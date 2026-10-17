/* YamVideo graphics engine, template version 1.
 *
 * Builds every graphic from one JSON object, then one paused GSAP timeline. The same file
 * runs in the app's preview (WKWebView), in HyperFrames for export, and in Node for
 * planning (`plan` only, no DOM). Synchronous and deterministic: no timers, no network,
 * no randomness. Text from the JSON is only ever set as textContent.
 * See docs/plans/graphics-track.md.
 */
(function (root) {
  "use strict";

  const VERSION = 1;
  const COLUMN = { left: 1240, top: 72, width: 640, height: 900 };
  const PANEL_MOVE = { left: 960, top: 0, width: 960, height: 1080 };
  const PANEL_STAY = { left: 1110, top: 0, width: 810, height: 1080 };
  const PANEL_MERGE_GAP = 1.0;   // panel graphics closer than this share one panel
  const PANEL_SLIDE = 0.8;       // the panel and the video move take this long
  const VIDEO_SHIFT = 480;       // the video moves this far left while a panel shows
  const ZONES = {
    namePlate: "column", featureList: "column", titleCard: "column", phoneScreens: "column",
    route: "column", link: "column", endCard: "column",
    panelTitle: "panel", rule: "panel", checklist: "panel",
    endScreen: "screen",
    logoBadge: "speaker",
  };
  const STAGE = { left: 0, top: 0, width: 1920, height: 1080 };
  const DEFAULT_STYLE = { accent: "#F5C42C", panel: "shade", moveVideo: true, edge: 170, look: "glass" };
  /**
   * The style's size, for viewers on a phone (the app's GraphicsStyle.size, 1 to 1.5):
   * cards grow by it about the column's top-right corner (a 600 px card's right edge), so
   * they grow left, away from the frame's edge; panels grow by half as much about the
   * panel's top-right corner, so they stay on their shade. Speaker and screen zones, and
   * Shorts, keep their own sizes.
   */
  const SIZE_RANGE = { min: 1, max: 1.5 };
  const SIZE_ANCHOR = { column: { x: 1840, y: 72 }, panel: { x: 1860, y: 40 } };
  function sizeOf(zone, style, short) {
    if (short || !SIZE_ANCHOR[zone]) return 1;
    const size = Math.max(SIZE_RANGE.min, Math.min(SIZE_RANGE.max, num(style.size, 1)));
    return zone === "panel" ? 1 + (size - 1) / 2 : size;
  }
  const PANEL_PAD = 108;         // panel content starts this far past the soft edge's start

  /**
   * Pure: where a Short (a 1080×1920 canvas) puts things. Each zone is where the template's
   * own zone (the 640×900 column, the 960×1080 panel) has its top-left corner, and its size.
   * Zoomed out, the cards, the bottom sheet and the captions sit `drop` pixels lower, under
   * the face. The app has the same numbers (ShortLayout in Sources/Shorts.swift).
   */
  const SHORT_STAGE = { left: 0, top: 0, width: 1080, height: 1920 };
  const SHORT_PANELS = {
    sheet: { x: 29, y: 717, scale: 0.9 },
    shade: { x: 0, y: 312, scale: 0.96 },
    split: { x: 53, y: 802, scale: 0.85 },
  };
  function shortLayout(panels, drop) {
    const name = SHORT_PANELS[panels] ? panels : "sheet";
    const d = typeof drop === "number" && isFinite(drop) ? Math.max(0, Math.min(400, drop)) : 0;
    const panel = Object.assign({}, SHORT_PANELS[name]);
    if (name === "sheet") panel.y += d;
    return {
      panels: name, stage: SHORT_STAGE, drop: d,
      column: { x: 72, y: 760 + d, scale: 1.2 },
      panel,
      sheetTop: 700 + d, lift: 240,
      splitFrame: { x: 333, y: 112, w: 414, h: 736 },
      captionBottom: 1320 + d,
    };
  }

  /** The video move curve. Core Image and FFmpeg use the same polynomial. */
  function smooth(p) { return p * p * (3 - 2 * p); }

  function zoneOf(kind) {
    const zone = ZONES[kind];
    if (!zone) throw new Error("Unknown graphic kind: " + kind);
    return zone;
  }

  function parseRate(value) {
    if (typeof value === "number") return value;
    const text = String(value || "30");
    const parts = text.split("/");
    return parts.length === 2 ? Number(parts[0]) / Number(parts[1]) : Number(text);
  }

  /**
   * Pure: where the end screen puts everything on the 1920×1080 stage. The speaker's frame
   * (half size), YouTube's Subscribe circle and one or two 16:9 video cards, and the text by
   * the circle. The app has the same numbers (EndScreenLayout in Sources/EndScreen.swift).
   */
  function endLayout(props) {
    const p = props || {};
    const videos = p.videos === 1 ? 1 : 2;
    const side = p.side === "right" ? "right" : "left";
    const card = (y) => ({ x: 1209, y, w: 615, h: 346 });
    // The circle ends inside YouTube's element area (bottom 917), so the frame sits high.
    let frame = { x: 96, y: 56, w: 960, h: 540 };
    let circle = { x: 96, y: 612, w: 296, h: 296 };
    let text = { x: 432, y: 612, w: 624, h: 296 };
    let cards = videos === 2 ? [card(162), card(556)] : [card(153)];
    if (side === "right") {
      const flip = (r) => ({ x: 1920 - r.x - r.w, y: r.y, w: r.w, h: r.h });
      frame = flip(frame); circle = flip(circle); text = flip(text); cards = cards.map(flip);
    }
    return { videos, side, frame, circle, text, cards };
  }

  /** Pure: zones, panel spans and render units. Shared with Tools/Graphics/assemble.mjs. */
  function plan(data) {
    const items = (data.items || []).slice().sort((a, b) => a.start - b.start);
    const spans = [];
    for (const g of items) {
      if (zoneOf(g.kind) !== "panel") continue;
      const last = spans[spans.length - 1];
      if (last && g.start - last.end < PANEL_MERGE_GAP) {
        last.end = Math.max(last.end, g.end);
        last.items.push(g.id);
      } else {
        spans.push({ id: "panel-" + spans.length, start: g.start, end: g.end, items: [g.id] });
      }
    }
    // A panel's shade comes before the graphics that start with it, so they draw over it.
    const units = items.map((g) => ({ id: g.id, kind: g.kind, start: g.start, end: g.end }))
      .concat(spans.map((s) => ({ id: s.id, kind: "panel", start: s.start, end: s.end + PANEL_SLIDE })))
      .sort((a, b) => a.start - b.start || (b.kind === "panel") - (a.kind === "panel"));
    return { version: VERSION, items, spans, units };
  }

  // ───────────────────────── DOM helpers ─────────────────────────

  const SVG_TAGS = new Set(["svg", "path", "circle", "rect", "text", "g", "line"]);
  function h(tag, attrs) {
    const node = SVG_TAGS.has(tag)
      ? document.createElementNS("http://www.w3.org/2000/svg", tag)
      : document.createElement(tag);
    for (const key in attrs || {}) {
      const value = attrs[key];
      if (value === null || value === undefined) continue;
      if (key === "text") node.textContent = String(value);
      else node.setAttribute(key, String(value));
    }
    for (let i = 2; i < arguments.length; i++) append(node, arguments[i]);
    return node;
  }
  function append(node, child) {
    if (child === null || child === undefined || child === false) return;
    if (Array.isArray(child)) { child.forEach((c) => append(node, c)); return; }
    node.appendChild(typeof child === "string" ? document.createTextNode(child) : child);
  }
  /** A short uppercase label in the accent colour. No leading bar: viewers read it as a dash. */
  function kicker(text, pill) {
    return { bar: null, node: h("div", { class: "yg-kicker" + (pill ? " yg-pill" : "") }, h("span", { text: text || "" })) };
  }
  function pad2(n) { return n < 10 ? "0" + n : String(n); }
  function num(value, fallback) { return typeof value === "number" && isFinite(value) ? value : fallback; }

  const ICONS = {
    camera: [["rect", { x: 17, y: 20, width: 14, height: 24, rx: 4 }], ["rect", { x: 15, y: 4, width: 18, height: 13, rx: 3 }],
      ["circle", { cx: 24, cy: 10.5, r: 3.6 }], ["path", { d: "M24 17v3" }], ["circle", { cx: 24, cy: 31, r: 2 }]],
    mic: [["rect", { x: 17, y: 10, width: 14, height: 22, rx: 7 }], ["path", { d: "M24 32v8M18 40h12" }],
      ["path", { d: "M10 14a14 14 0 0 0 0 14M38 14a14 14 0 0 1 0 14" }]],
    app: [["rect", { x: 8, y: 8, width: 32, height: 32, rx: 9 }], ["path", { d: "M17 24h14M24 17v14" }]],
    link: [["path", { d: "M20 28l8-8" }], ["path", { d: "M22 14l3-3a7 7 0 0 1 10 10l-3 3M26 34l-3 3a7 7 0 0 1-10-10l3-3" }]],
    check: [["circle", { cx: 24, cy: 24, r: 16 }], ["path", { d: "M17 24l5 5 9-10" }]],
  };
  function icon(name) {
    const parts = ICONS[name];
    if (!parts) return null;
    return h("svg", { viewBox: "0 0 48 48", fill: "none", stroke: "var(--yg-accent)", "stroke-width": 2.6,
      "stroke-linecap": "round", "stroke-linejoin": "round" }, parts.map((p) => h(p[0], p[1])));
  }

  // ───────────────────────── Kinds ─────────────────────────
  // Each kind builds its DOM inside `inner` and schedules its beats on the context `c`.
  // Beat times (`at`) are seconds after the graphic's start.

  const KINDS = {};

  KINDS.namePlate = function (inner, p, c) {
    const k = kicker(p.kicker);
    const name = h("div", { class: "yg-np-name", text: p.title });
    const role = h("div", { class: "yg-np-role yg-muted", text: p.detail });
    append(inner, h("div", { class: "yg-np-plate yg-glass" }, k.node, name, role));
    c.enterColumn();
    c.grow(k.bar, 0.25);
    c.up([name, role], 0.3, 0.12);
    c.exitColumn();
  };

  KINDS.featureList = function (inner, p, c) {
    const k = kicker(p.kicker, true);
    const list = h("div", { class: "yg-fl-list" });
    append(inner, [k.node, list]);
    c.enterColumn();
    c.grow(k.bar, 0.2);
    for (const item of p.items || []) {
      // A product photo (transparent PNG) takes the icon's place and pops in with a tilt.
      const photo = item.image ? h("div", { class: "yg-fl-photo" }, h("img", { src: item.image, alt: "" })) : null;
      const row = h("div", { class: "yg-fl-row yg-glass" + (photo ? " yg-has-photo" : "") },
        photo || (icon(item.icon) ? h("div", { class: "yg-fl-icon" }, icon(item.icon)) : null),
        h("div", {}, h("div", { class: "yg-fl-t", text: item.title }), h("div", { class: "yg-fl-d yg-muted", text: item.detail })));
      append(list, row);
      c.up(row, num(item.at, 0.2));
      if (photo) c.tl.fromTo(photo, { opacity: 0, scale: 0.6, rotation: -10 }, { opacity: 1, scale: 1, rotation: 0, duration: 0.6, ease: "back.out(1.7)" }, c.at(num(item.at, 0.2) + 0.15));
      const stat = item.stat;
      if (stat) {
        const digits = h("span", { text: String(Math.round(num(stat.from, 0))) });
        const value = h("span", { class: "yg-fl-val" }, digits, stat.suffix ? h("span", { class: "yg-fl-x", text: stat.suffix }) : null);
        const pill = h("div", { class: "yg-fl-stat yg-glass" }, h("span", { class: "yg-fl-lbl yg-muted", text: stat.label }), value);
        append(list, pill);
        c.up(pill, num(stat.at, 1));
        c.count(digits, num(stat.from, 0), num(stat.to, 0), "", num(stat.at, 1) + 0.2, 2.4);
        c.pop(value, num(stat.at, 1) + 2.6);
      }
    }
    c.exitColumn();
  };

  KINDS.titleCard = function (inner, p, c) {
    const k = kicker(p.kicker);
    const words = String(p.title || "").split(/\s+/).filter(Boolean).map((w) => h("span", { class: "yg-tc-w", text: w }));
    const detail = h("span", { class: "yg-muted", text: p.detail });
    const badges = (p.badges || []).map((b) => h("span", { class: "yg-badge", text: b }));
    append(inner, h("div", { class: "yg-tc-panel yg-glass" }, k.node,
      h("div", { class: "yg-tc-title" }, words), h("div", { class: "yg-tc-sub" }, detail, badges)));
    const badgesAt = num(p.badgesAt, 5);
    c.enterColumn();
    c.grow(k.bar, 0.2);
    c.up(words, 0.3, 0.06);
    c.up(detail, Math.max(0.6, badgesAt - 0.4));
    if (badges.length) c.pop(badges, badgesAt, 0.15);
    c.exitColumn();
  };

  KINDS.phoneScreens = function (inner, p, c) {
    const screens = (p.screens || []).map((s) => ({ at: num(s.at, 0), img: h("img", { src: s.image, alt: "" }) }));
    const phone = h("div", { class: "yg-phone yg-ps-phone" }, h("div", { class: "yg-screen" }, screens.map((s) => s.img)));
    const k = kicker(p.kicker);
    const label = h("div", { class: "yg-ps-label yg-glass" }, k.node,
      h("div", { class: "yg-ps-name", text: p.title }), h("div", { class: "yg-ps-d yg-muted", text: p.detail }));
    append(inner, [phone, label]);
    const tl = c.tl;
    tl.fromTo(c.host, { opacity: 0 }, { opacity: 1, duration: 0.3, ease: "power2.out" }, c.at(0));
    tl.fromTo(phone, { y: 120, rotation: 5, opacity: 0 }, { y: 0, rotation: 0, opacity: 1, duration: 0.8, ease: "power3.out" }, c.at(0));
    tl.fromTo(label, { x: 40, opacity: 0 }, { x: 0, opacity: 1, duration: 0.6, ease: "power3.out" }, c.at(0.4));
    c.grow(k.bar, 0.7);
    if (screens.length) {
      const firstHold = screens.length > 1 ? Math.max(0.5, screens[1].at) : Math.max(0.5, c.length - 0.4);
      tl.fromTo(screens[0].img, { scale: 1 }, { scale: 1.05, duration: firstHold, ease: "none" }, c.at(0));
    }
    screens.slice(1).forEach((s) => {
      tl.fromTo(s.img, { opacity: 0, x: 40 }, { opacity: 1, x: 0, duration: 0.5, ease: "power2.out" }, c.at(s.at));
    });
    if (c.length > 5.4) tl.to(phone, { y: -12, duration: c.length - 4.4 - 0.5, ease: "sine.inOut" }, c.at(4.4));
    c.exitColumn();
  };

  /** Waypoints [{name, lat, lon, label?}] as an SVG path, north up, fitted in w×h. */
  function mapPath(points, w, h, pad) {
    const lat0 = points.reduce((a, q) => a + q.lat, 0) / points.length;
    const k = Math.cos(lat0 * Math.PI / 180);
    const xs = points.map((q) => q.lon * k), ys = points.map((q) => -q.lat);
    const minX = Math.min(...xs), maxX = Math.max(...xs), minY = Math.min(...ys), maxY = Math.max(...ys);
    const scale = Math.min((w - 2 * pad) / Math.max(1e-6, maxX - minX), (h - 2 * pad) / Math.max(1e-6, maxY - minY));
    const offX = (w - (maxX - minX) * scale) / 2, offY = (h - (maxY - minY) * scale) / 2;
    const at = points.map((q, i) => ({ x: offX + (xs[i] - minX) * scale, y: offY + (ys[i] - minY) * scale, q }));
    const grid = [];
    for (let lat = Math.ceil(Math.min(...points.map((q) => q.lat))); lat <= Math.max(...points.map((q) => q.lat)); lat++) {
      grid.push(offY + (-lat - minY) * scale);
    }
    return { at, d: at.map((p, i) => (i ? "L" : "M") + p.x.toFixed(1) + " " + p.y.toFixed(1)).join(" "), grid, scale };
  }

  KINDS.route = function (inner, p, c) {
    if (Array.isArray(p.waypoints) && p.waypoints.length >= 2) return routeMap(inner, p, c);
    const k = kicker(p.kicker);
    const title = h("div", { class: "yg-rt-title", text: (p.from || "") + " → " + (p.to || "") });
    const d = "M470 38 C 390 38, 350 112, 268 116 S 120 150, 66 166";
    const path = h("path", { d, stroke: "var(--yg-accent)", "stroke-width": 6, fill: "none", "stroke-linecap": "round" });
    const bike = h("circle", { cx: 470, cy: 38, r: 15, fill: "var(--yg-accent)", stroke: "#0d0f13", "stroke-width": 5 });
    const toLabel = h("text", { x: 66, y: 122, fill: "#f4f5f7", "font-family": "Inter", "font-weight": 700, "font-size": 22, "text-anchor": "middle", text: p.to });
    const svg = h("svg", { class: "yg-rt-svg", viewBox: "0 0 536 200" },
      h("path", { d, stroke: "rgba(255,255,255,0.12)", "stroke-width": 6, fill: "none", "stroke-linecap": "round", "stroke-dasharray": "2 12" }),
      path,
      h("circle", { cx: 470, cy: 38, r: 10, fill: "#0d0f13", stroke: "#f4f5f7", "stroke-width": 4 }),
      h("circle", { cx: 66, cy: 166, r: 10, fill: "var(--yg-accent)" }),
      bike,
      h("text", { x: 470, y: 84, fill: "#f4f5f7", "font-family": "Inter", "font-weight": 700, "font-size": 22, "text-anchor": "middle", text: p.from }),
      toLabel);
    append(inner, h("div", { class: "yg-rt-panel yg-glass" }, k.node, title, svg));
    const drawAt = num(p.drawAt, 1.8);
    c.enterColumn();
    c.grow(k.bar, 0.2);
    c.up(title, 0.4);
    c.draw(path, drawAt, 2.6);
    c.along(bike, path, drawAt, 2.6);
    c.pop(toLabel, drawAt + 2.0);
    if (p.question) {
      const chips = (p.chips || []).map((chip) => ({ at: num(chip.at, 0), node: h("span", { class: "yg-chip" }, h("span", { class: "yg-x", text: "✕" }), h("span", { text: chip.text })) }));
      const risks = h("div", { class: "yg-rt-risks yg-glass" }, h("div", { class: "yg-rt-q", text: p.question }),
        h("div", { class: "yg-rt-chips" }, chips.map((x) => x.node)));
      append(inner, risks);
      c.up(risks, num(p.questionAt, drawAt + 3));
      chips.forEach((x) => c.pop(x.node, x.at));
    }
    c.exitColumn();
  };

  /** The route card with a real path: waypoints by latitude and longitude, drawn north up. */
  function routeMap(inner, p, c) {
    const points = p.waypoints.filter((q) => isFinite(q.lat) && isFinite(q.lon));
    const W = 536, H = 330;
    const map = mapPath(points, W, H, 34);
    const k = kicker(p.kicker);
    const first = points[0].name || p.from || "", last = points[points.length - 1].name || p.to || "";
    const title = h("div", { class: "yg-rt-title", text: (p.from || first) + " → " + (p.to || last) });
    const path = h("path", { d: map.d, stroke: "var(--yg-accent)", "stroke-width": 6, fill: "none", "stroke-linecap": "round", "stroke-linejoin": "round" });
    const svg = h("svg", { class: "yg-rt-svg yg-map", viewBox: "0 0 " + W + " " + H },
      map.grid.map((y) => h("line", { x1: 0, x2: W, y1: y.toFixed(1), y2: y.toFixed(1), stroke: "rgba(255,255,255,0.06)", "stroke-width": 1 })),
      h("path", { d: map.d, stroke: "rgba(255,255,255,0.14)", "stroke-width": 6, fill: "none", "stroke-linecap": "round", "stroke-linejoin": "round", "stroke-dasharray": "2 12" }),
      path);
    const labels = [];
    map.at.forEach((m, i) => {
      const end = i === 0 || i === map.at.length - 1;
      append(svg, h("circle", { cx: m.x.toFixed(1), cy: m.y.toFixed(1), r: end ? 9 : 5,
        fill: i === map.at.length - 1 ? "var(--yg-accent)" : (end ? "#0d0f13" : "rgba(255,255,255,0.75)"),
        stroke: end ? "#f4f5f7" : "none", "stroke-width": end ? 4 : 0 }));
      if (end || m.q.label) {
        const right = m.x < W * 0.55;
        const gap = end ? 22 : 14;
        // The start label sits above its dot, clear of the path leaving it.
        const above = i === 0;
        const label = h("text", { x: (above ? m.x + 10 : m.x + (right ? gap : -gap)).toFixed(1),
          y: (above ? m.y - 18 : m.y + 7).toFixed(1), fill: "#f4f5f7",
          "font-family": "Inter", "font-weight": end ? 700 : 400, "font-size": end ? 22 : 18,
          "text-anchor": above ? "end" : (right ? "start" : "end"), text: m.q.name });
        append(svg, label);
        labels.push({ node: label, index: i });
      }
    });
    const bike = h("circle", { cx: map.at[0].x.toFixed(1), cy: map.at[0].y.toFixed(1), r: 13, fill: "var(--yg-accent)", stroke: "#0d0f13", "stroke-width": 5 });
    append(svg, bike);
    const km = p.distance ? h("div", { class: "yg-rt-km" }, h("span", { class: "yg-accent", text: p.distance }),
      p.roads ? h("span", { class: "yg-muted", text: p.roads }) : null) : null;
    append(inner, h("div", { class: "yg-rt-panel yg-glass" }, k.node, title, svg, km));
    const drawAt = num(p.drawAt, 1.8), drawFor = num(p.drawFor, 3.2);
    c.enterColumn();
    c.up(title, 0.4);
    c.draw(path, drawAt, drawFor);
    c.along(bike, path, drawAt, drawFor);
    labels.forEach((l) => c.pop(l.node, drawAt + drawFor * (l.index / Math.max(1, map.at.length - 1))));
    if (km) c.up(km, drawAt + drawFor);
    if (p.question) {
      const chips = (p.chips || []).map((chip) => ({ at: num(chip.at, 0), node: h("span", { class: "yg-chip" }, h("span", { class: "yg-x", text: "✕" }), h("span", { text: chip.text })) }));
      const risks = h("div", { class: "yg-rt-risks yg-glass", style: "top:" + (km ? 560 : 530) + "px;" }, h("div", { class: "yg-rt-q", text: p.question }),
        h("div", { class: "yg-rt-chips" }, chips.map((x) => x.node)));
      append(inner, risks);
      c.up(risks, num(p.questionAt, drawAt + drawFor + 1));
      chips.forEach((x) => c.pop(x.node, x.at));
    }
    c.exitColumn();
  }

  KINDS.link = function (inner, p, c) {
    const k = kicker(p.kicker, true);
    const url = String(p.url || "");
    const slash = url.indexOf("/");
    const chars = Array.from(url).map((ch, i) => h("span", { class: slash < 0 || i < slash ? "yg-dim" : null, text: ch }));
    const caret = h("span", { class: "yg-ln-caret" });
    const lock = h("svg", { width: 22, height: 26, viewBox: "0 0 22 26", fill: "none", stroke: "#a6adb8", "stroke-width": 2.4 },
      h("rect", { x: 2, y: 11, width: 18, height: 13, rx: 3 }), h("path", { d: "M6 11V7a5 5 0 0 1 10 0v4" }));
    const bar = h("div", { class: "yg-ln-bar yg-glass" }, h("div", { class: "yg-ln-dots" }, h("i"), h("i"), h("i")),
      lock, h("div", { class: "yg-ln-url" }, chars), caret);
    append(inner, [k.node, bar]);
    c.enterColumn();
    c.grow(k.bar, 0.2);
    c.up(bar, 0.3);
    if (chars.length) c.tl.fromTo(chars, { opacity: 0 }, { opacity: 1, duration: 0.01, stagger: 0.1 }, c.at(num(p.typeAt, 1)));
    const blinks = Math.min(9, Math.max(0, Math.floor((c.length - 0.7 - 0.4) / 0.46) - 1));
    c.tl.fromTo(caret, { opacity: 1 }, { opacity: 0, duration: 0.01, repeat: blinks, yoyo: true, repeatDelay: 0.45 }, c.at(0.7));
    c.exitColumn();
  };

  KINDS.endCard = function (inner, p, c) {
    const k = kicker(p.kicker);
    const title = h("div", { class: "yg-ec-title", text: p.title });
    const detail = h("div", { class: "yg-ec-d yg-muted", text: p.detail });
    // A filled bell with a clapper, and two ring arcs that show while it rings.
    const bellBody = h("path", { fill: "#fff", d: "M23 4.5c1.4 0 2.5 1.1 2.5 2.5v1.3c5.3 1.1 9 5.8 9 11.2v8.2l3.3 3.9c.7.8.1 2-1 2H9.2c-1.1 0-1.7-1.2-1-2l3.3-3.9v-8.2c0-5.4 3.7-10.1 9-11.2V7c0-1.4 1.1-2.5 2.5-2.5z" });
    const clapper = h("path", { fill: "#fff", d: "M18.6 37.6h8.8a4.4 4.4 0 0 1-8.8 0z" });
    const ringLeft = h("path", { d: "M6.5 12.5a16 16 0 0 0-3 9.5", stroke: "#fff", "stroke-width": 3, "stroke-linecap": "round", fill: "none" });
    const ringRight = h("path", { d: "M39.5 12.5a16 16 0 0 1 3 9.5", stroke: "#fff", "stroke-width": 3, "stroke-linecap": "round", fill: "none" });
    const bellShape = h("g", {}, bellBody, clapper);
    const bell = h("span", { class: "yg-ec-bell" }, h("svg", { viewBox: "0 0 46 46" }, ringLeft, ringRight, bellShape));
    const button = p.button ? h("div", { class: "yg-ec-btn" }, bell, h("span", { text: p.button })) : null;
    append(inner, h("div", { class: "yg-ec-panel yg-glass" }, k.node, title, detail, button));
    c.enterColumn();
    c.up([title, detail], 0.3, 0.12);
    if (button) {
      c.pop(button, 1.2);
      const ringAt = 2.2;
      c.tl.fromTo(bellShape, { rotation: 0 }, { rotation: 16, svgOrigin: "23 6", duration: 0.11, yoyo: true, repeat: 7, ease: "sine.inOut" }, c.at(ringAt));
      c.tl.fromTo([ringLeft, ringRight], { opacity: 0, scale: 0.6, svgOrigin: "23 22" }, { opacity: 1, scale: 1, svgOrigin: "23 22", duration: 0.25, ease: "power2.out" }, c.at(ringAt));
      c.tl.to([ringLeft, ringRight], { opacity: 0, duration: 0.3, ease: "power2.in" }, c.at(ringAt + 0.9));
    }
    c.exitColumn();
  };

  /**
   * The end screen: a frame round the speaker, who moves into it natively (in the app) or
   * as #bg-video (full mode), and empty boxes exactly where YouTube's end screen elements
   * sit, so nothing covers them. In the app's preview each box says what goes in it
   * (`guides`, written by the app from the publish details); exports draw the boxes only,
   * because YouTube's elements cover them.
   */
  const END_MARGIN = 10;
  KINDS.endScreen = function (inner, p, c) {
    const layout = endLayout(p);
    const px = (r, pad) => "left:" + (r.x - pad) + "px;top:" + (r.y - pad) + "px;width:" + (r.w + 2 * pad) + "px;height:" + (r.h + 2 * pad) + "px;";
    const frame = h("div", { class: "yg-es-frame", style: px({ x: STAGE.left, y: STAGE.top, w: STAGE.width, h: STAGE.height }, 0) });
    const guides = c.mode === "preview" && p.guides ? p.guides : null;
    const box = (r, round, label) => h("div", { class: "yg-es-box" + (round ? " yg-es-round" : ""), style: px(r, END_MARGIN) },
      guides ? h("div", { class: "yg-es-guide" }, h("span", { text: label }), h("span", { class: "yg-es-note", text: "YouTube places it" })) : null);
    const circle = box(layout.circle, true, guides && guides.circle ? guides.circle : "Subscribe");
    const cards = layout.cards.map((r, i) => box(r, false, guides && guides.cards && guides.cards[i] ? guides.cards[i] : "Video " + (i + 1)));
    const k = kicker(p.kicker);
    const title = h("div", { class: "yg-es-title", text: p.title });
    const text = h("div", { class: "yg-es-text " + layout.side, style: px(layout.text, 0) }, p.kicker ? k.node : null, p.title ? title : null);
    append(inner, [frame, circle, cards, text]);
    const tl = c.tl;
    tl.fromTo(c.host, { opacity: 0 }, { opacity: 1, duration: 0.3, ease: "power2.out" }, c.at(0));
    // The frame follows the picture's move: the same curve and length as the native move.
    tl.fromTo(frame, { left: 0, top: 0, width: 1920, height: 1080, opacity: 0 },
      { left: layout.frame.x, top: layout.frame.y, width: layout.frame.w, height: layout.frame.h, opacity: 1, duration: PANEL_SLIDE, ease: smooth }, c.at(0));
    c.pop([circle].concat(cards), PANEL_SLIDE + 0.1, 0.12);
    c.up([k.node, title], PANEL_SLIDE + 0.35, 0.12);
  };

  /**
   * Where a logo badge goes: `spot` {x, y, alignX, alignY, compact}, the point its alignX
   * and alignY edges (start, middle or end) go to. The app works it out from where the
   * layout puts the speaker (LogoSpot in Sources/Logos.swift). Without one: the top right.
   */
  const EDGE_SHIFT = { start: 0, middle: -50, end: -100 };
  function logoSpot(p, short) {
    const s = (p && p.spot) || {};
    const edge = (value, fallback) => (EDGE_SHIFT[value] !== undefined ? value : fallback);
    if (typeof s.x === "number" && isFinite(s.x) && typeof s.y === "number" && isFinite(s.y)) {
      return { x: s.x, y: s.y, alignX: edge(s.alignX, "start"), alignY: edge(s.alignY, "start"), compact: !!s.compact, vertical: !!s.vertical };
    }
    return short ? { x: 888, y: 240, alignX: "end", alignY: "start", compact: true }
      : { x: 1824, y: 54, alignX: "end", alignY: "start", compact: false };
  }

  /** A brand's logo next to the speaker: a row of chips, each a logo and its name, each
   * popping in at its own `at`; one above the other when `spot.vertical`. A Short's compact
   * chips show the logo alone. */
  KINDS.logoBadge = function (inner, p, c) {
    const spot = logoSpot(p, c.short);
    const row = h("div", { class: "yg-lb-row" + (spot.compact ? " yg-lb-compact" : "") + (p.tone === "dark" ? " yg-lb-dark" : "")
        + (spot.vertical ? " yg-lb-column yg-lb-x-" + spot.alignX : ""),
      style: "transform:translate(" + EDGE_SHIFT[spot.alignX] + "%," + EDGE_SHIFT[spot.alignY] + "%);" });
    const chips = (p.logos || []).slice(0, 3).map((logo) => {
      const label = !spot.compact && logo.label ? h("span", { text: logo.label }) : null;
      return { at: Math.max(0, num(logo.at, 0)),
        node: h("div", { class: "yg-lb-chip" + (label ? "" : " yg-lb-bare") }, h("img", { src: logo.image, alt: "" }), label) };
    });
    append(row, chips.map((x) => x.node));
    append(inner, row);
    const tl = c.tl;
    tl.fromTo(c.host, { opacity: 0 }, { opacity: 1, duration: 0.01 }, c.at(0));
    chips.forEach((x) => tl.fromTo(x.node, { opacity: 0, scale: 0.6, y: 14 }, { opacity: 1, scale: 1, y: 0, duration: 0.45, ease: "back.out(1.8)" }, c.at(x.at)));
    // Out: the chips shrink a little as the badge fades. The row keeps its own transform
    // (its alignment), so the timeline never touches it.
    const out = c.at(Math.max(0, c.length - 0.3));
    if (chips.length) tl.to(chips.map((x) => x.node), { scale: 0.9, duration: 0.3, ease: "power2.in" }, out);
    tl.to(c.host, { opacity: 0, duration: 0.3, ease: "power2.in" }, out);
  };

  KINDS.panelTitle = function (inner, p, c) {
    const k = kicker(p.kicker);
    const big = h("div", { class: "yg-pt-big", text: p.title });
    const badges = [];
    for (let i = 1; i <= Math.min(9, num(p.count, 0)); i++) badges.push(h("span", { class: "yg-badge", text: pad2(i) }));
    append(inner, h("div", { class: "yg-pt-intro" }, k.node, big, h("div", { class: "yg-pt-count" }, badges)));
    c.enterPanel();
    c.grow(k.bar, 0.7);
    c.up(big, 0.8);
    if (badges.length) c.pop(badges, num(p.countAt, 2), 0.15);
    c.exitPanel();
  };

  KINDS.rule = function (inner, p, c) {
    const k = kicker(p.kicker);
    const title = h("div", { class: "yg-title", text: p.title });
    const number = p.number ? h("div", { class: "yg-num", text: p.number }) : null;
    const subtitle = p.subtitle ? h("div", { class: "yg-rule-sub yg-muted", text: p.subtitle }) : null;
    append(inner, h("div", { class: "yg-rule-head" }, k.node, number ? h("div", { class: "yg-rule-top" }, number, title) : title, subtitle));
    const demo = p.demo || null;
    const type = demo && DEMOS[demo.type] ? demo.type : "none";
    const points = (p.points || []).map((pt) => ({ at: num(pt.at, 1), node: h("div", { class: "yg-point" }, h("span", { class: "yg-dot" }), h("span", { text: pt.text })) }));
    append(inner, h("div", { class: "yg-points yg-points-" + type }, points.map((x) => x.node)));
    c.enterPanel();
    if (number) { c.pop(number, 0.2); c.up(title, 0.3); } else { c.up(title, 0.13); }
    if (subtitle) c.up(subtitle, num(p.subtitleAt, 0.7));
    points.forEach((x) => c.up(x.node, x.at));
    if (type !== "none") DEMOS[type](inner, demo, c);
    c.exitPanel();
  };

  KINDS.checklist = function (inner, p, c) {
    const k = kicker(p.kicker);
    const title = h("div", { class: "yg-title", text: p.title });
    const items = (p.items || []).map((item, i) => {
      const fill = h("span", { class: "yg-cl-fill", text: "✓" });
      const row = h("div", { class: "yg-cl-item yg-glass" }, h("span", { class: "yg-cl-box" }, fill),
        h("span", { class: "yg-cl-n", text: pad2(i + 1) }), h("span", { class: "yg-cl-l", text: item.text }));
      return { row, fill, at: num(item.at, 1.5 + i * 0.8) };
    });
    const footer = p.footer ? h("div", { class: "yg-cl-foot yg-muted", text: p.footer }) : null;
    append(inner, h("div", { class: "yg-cl-wrap" }, k.node, title, h("div", { class: "yg-cl-list" }, items.map((x) => x.row)), footer));
    c.enterPanel();
    c.up(title, 0.14);
    if (items.length) c.up(items.map((x) => x.row), 0.44, 0.12);
    items.forEach((x) => c.pop(x.fill, x.at));
    if (footer) c.up(footer, num(p.footerAt, 4.6));
    c.exitPanel();
  };

  // ───────────────────────── Rule demos ─────────────────────────

  const DEMOS = {};

  DEMOS.image = function (inner, d, c) {
    const screenW = 280, screenH = 574, left = 88, top = 352;
    const img = h("img", { src: d.image, alt: "" });
    const screen = h("div", { class: "yg-screen" }, img);
    const phone = h("div", { class: "yg-phone yg-dm-phone" }, screen);
    append(inner, phone);
    c.up(phone, num(d.at, 1));
    const flag = d.flag;
    if (flag && flag.box) {
      const b = flag.box;
      const box = h("div", { class: "yg-dm-box", style: "left:" + (b.x * 100) + "%;top:" + (b.y * 100) + "%;width:" + (b.w * 100) + "%;height:" + (b.h * 100) + "%;" });
      append(screen, box);
      const label = h("div", { class: "yg-dm-flag", text: "✕ " + (flag.text || ""),
        style: "left:" + Math.round(left + 10 + (b.x + b.w * 0.4) * screenW) + "px;top:" + Math.round(top + 10 + b.y * screenH - 38) + "px;" });
      append(inner, label);
      c.tl.fromTo(box, { opacity: 0, scale: 1.15 }, { opacity: 1, scale: 1, duration: 0.45, ease: "power3.out" }, c.at(num(flag.at, 2)));
      c.pop(label, num(flag.at, 2) + 0.6);
    }
  };

  DEMOS.account = function (inner, d, c) {
    const rows = (d.rows || []).map((text) => {
      const strike = h("i", { class: "yg-ac-strike" });
      return { strike, node: h("div", { class: "yg-ac-row" }, h("span", { text }), h("span", { class: "yg-muted", text: "›" }), strike) };
    });
    const tap = h("span", { class: "yg-ac-tap" });
    const button = h("div", { class: "yg-ac-del" }, h("span", { text: d.button || "Delete account" }), tap);
    const toast = h("div", { class: "yg-ac-toast", text: "✓ " + (d.toast || "") });
    const ui = h("div", { class: "yg-ac-ui yg-glass" }, h("div", { class: "yg-ac-h", text: d.title || "Account" }),
      h("div", { class: "yg-ac-rows" }, rows.map((r) => r.node)), button, toast);
    append(inner, ui);
    const tl = c.tl;
    c.up(ui, num(d.at, 1.1));
    const tapAt = num(d.tapAt, 3);
    tl.fromTo(tap, { opacity: 0.9, scale: 0.3 }, { opacity: 0, scale: 1.8, duration: 0.7, ease: "power2.out", immediateRender: false }, c.at(tapAt));
    tl.fromTo(button, { scale: 1 }, { scale: 0.96, duration: 0.12, yoyo: true, repeat: 1, ease: "power1.inOut" }, c.at(tapAt));
    const clearAt = num(d.clearAt, tapAt + 2);
    if (rows.length) {
      c.grow(rows.map((r) => r.strike), clearAt);
      tl.to(rows.map((r) => r.node), { opacity: 0.35, duration: 0.4, stagger: 0.12, ease: "power2.out" }, c.at(clearAt + 0.2));
    }
    c.up(toast, clearAt + 1.2);
  };

  DEMOS.flow = function (inner, d, c) {
    const nodes = (d.nodes || []).map((n, i) => ({
      at: num(n.at, 1 + i),
      node: h("div", { class: "yg-fw-node yg-glass" + (n.tone === "danger" ? " yg-danger" : ""), style: "top:" + i * 114 + "px;" },
        h("span", { class: "yg-fw-i", text: String(i + 1) }), h("span", { class: "yg-fw-l", text: n.text })),
    }));
    const lineEnd = 38 + 114 * Math.max(0, nodes.length - 1);
    const pathD = "M42 38 L42 " + lineEnd;
    const line = h("path", { d: pathD, stroke: "rgba(255,255,255,0.18)", "stroke-width": 4, "stroke-linecap": "round", fill: "none" });
    const glow = h("path", { d: pathD, stroke: "var(--yg-accent)", "stroke-width": 4, "stroke-linecap": "round", fill: "none" });
    append(inner, h("div", { class: "yg-fw" }, h("svg", { class: "yg-fw-links", viewBox: "0 0 120 460" }, line, glow), nodes.map((n) => n.node)));
    if (nodes.length > 1) c.draw(line, num(d.lineAt, 1.3), 1.2);
    nodes.forEach((n) => c.up(n.node, n.at));
    if (d.note) {
      const note = h("div", { class: "yg-fw-note yg-glass" }, h("span", { class: "yg-muted", text: d.note.text }));
      append(inner, note);
      c.up(note, num(d.note.at, 3));
    }
    if (nodes.length > 1) c.draw(glow, num(d.sweepAt, 5), 2.2);
    if (d.stamp) {
      const stamp = h("div", { class: "yg-fw-stamp", text: "✓ " + d.stamp.text });
      append(inner, stamp);
      c.pop(stamp, num(d.stamp.at, 6));
    }
  };

  DEMOS.accessibility = function (inner, d, c) {
    const tl = c.tl;
    const labels = d.labels || {};
    const aa = h("span", { class: "yg-ax-aa", text: "Aa" });
    const ok1 = h("span", { class: "yg-ax-ok", text: "✓" });
    const ok2 = h("span", { class: "yg-ax-ok", text: "✓" });
    const high = h("div", { class: "yg-ax-pill yg-ax-high", text: d.button || "Start ride" });
    const tile1 = h("div", { class: "yg-ax-tile yg-glass" }, h("div", { class: "yg-ax-lbl yg-muted", text: labels.text || "Bigger text" }), aa, ok1);
    const tile2 = h("div", { class: "yg-ax-tile yg-glass" }, h("div", { class: "yg-ax-lbl yg-muted", text: labels.contrast || "Contrast" }),
      h("div", { class: "yg-ax-pill yg-ax-low", text: d.button || "Start ride" }), high, ok2);
    append(inner, h("div", { class: "yg-ax-tiles" }, tile1, tile2));
    const chips = (d.chips || []).map((chip) => ({ at: num(chip.at, 0), node: h("span", { class: "yg-chip", text: chip.text }) }));
    const long = h("span", { class: "yg-ax-long", text: d.sample || "" });
    const fixed = h("span", { class: "yg-ax-fixed", text: d.sample || "" });
    const bad = h("span", { class: "yg-ax-bad" });
    const good = h("span", { class: "yg-ax-good" });
    const badNote = h("span", { class: "yg-ax-note", style: "color:var(--yg-flag)", text: "✕ " + (d.breakNote || "") });
    const goodNote = h("span", { class: "yg-ax-note", style: "color:var(--yg-ok)", text: "✓ " + (d.fixNote || "") });
    const tip = h("div", { class: "yg-ax-tip yg-glass" }, h("div", { class: "yg-ax-q", text: d.tip ? d.tip.text : "" }),
      h("div", { class: "yg-ax-chips" }, chips.map((x) => x.node)),
      h("div", { class: "yg-ax-test" }, long, fixed, bad, good, badNote, goodNote));
    append(inner, tip);
    const growAt = num(d.growAt, 2), contrastAt = num(d.contrastAt, 4);
    c.up([tile1, tile2], num(d.tilesAt, 1), 0.15);
    tl.fromTo(aa, { scale: 0.55 }, { scale: 1.3, duration: 1.0, ease: "power3.out" }, c.at(growAt));
    c.pop(ok1, growAt + 1.0);
    tl.fromTo(high, { opacity: 0 }, { opacity: 1, duration: 0.5, ease: "power2.out" }, c.at(contrastAt));
    c.pop(ok2, contrastAt + 0.6);
    c.up(tip, d.tip ? num(d.tip.at, 6) : 6);
    chips.forEach((x) => c.pop(x.node, x.at));
    const breakAt = num(d.breakAt, 8), fixAt = num(d.fixAt, 10);
    tl.fromTo(long, { opacity: 0 }, { opacity: 1, duration: 0.3 }, c.at(breakAt));
    tl.fromTo([bad, badNote], { opacity: 0 }, { opacity: 1, duration: 0.3 }, c.at(breakAt + 0.6));
    tl.to([long, bad, badNote], { opacity: 0, duration: 0.3 }, c.at(fixAt));
    tl.fromTo([fixed, good, goodNote], { opacity: 0 }, { opacity: 1, duration: 0.35 }, c.at(fixAt + 0.1));
  };

  // ───────────────────────── Ink look ─────────────────────────
  // Handwriting (Virgil) revealed left to right, and marks drawn stroke by stroke over a
  // soft haze. Every wobble comes from a PRNG seeded by the graphic's ID, so a render is
  // repeatable. Positions are in panel pixels; the writing starts at INK_X.

  const INK_X = 130;

  function seeded(text) {
    let s = 2166136261;
    for (let i = 0; i < text.length; i++) { s ^= text.charCodeAt(i); s = Math.imul(s, 16777619); }
    return function () {
      s = (s + 0x6D2B79F5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
  }

  function pen(rand) {
    const j = (amount) => (rand() - 0.5) * 2 * amount;
    const f = (n) => n.toFixed(1);
    const head = (x, y, angle, size) => {
      const s = size || 16, a1 = angle + Math.PI * 0.82, a2 = angle - Math.PI * 0.82;
      return " M" + f(x + Math.cos(a1) * s) + " " + f(y + Math.sin(a1) * s) + " L" + f(x) + " " + f(y) +
        " L" + f(x + Math.cos(a2) * s) + " " + f(y + Math.sin(a2) * s);
    };
    const line = (x1, y1, x2, y2, wobble) => {
      const w = wobble === undefined ? 3 : wobble;
      return "M" + f(x1) + " " + f(y1) + " Q " + f((x1 + x2) / 2 + j(w)) + " " + f((y1 + y2) / 2 + j(w)) + " " + f(x2 + j(1)) + " " + f(y2 + j(1));
    };
    return {
      line,
      arrow: (x1, y1, x2, y2) => line(x1, y1, x2, y2, 4) + head(x2, y2, Math.atan2(y2 - y1, x2 - x1)),
      curve: (x1, y1, cx, cy, x2, y2) => "M" + f(x1) + " " + f(y1) + " Q " + f(cx + j(4)) + " " + f(cy + j(4)) + " " + f(x2) + " " + f(y2) + head(x2, y2, Math.atan2(y2 - cy, x2 - cx)),
      ring(cx, cy, rx, ry) {
        const start = -2.2 + j(0.3), steps = 30, tilt = j(0.06);
        let d = "";
        for (let i = 0; i <= steps; i++) {
          const t = start + (i / steps) * 1.12 * Math.PI * 2;
          const r = 1 + j(0.02) + (i / steps) * 0.06;
          const x = Math.cos(t) * rx * r, y = Math.sin(t) * ry * r;
          d += (i ? " L" : "M") + f(cx + x * Math.cos(tilt) - y * Math.sin(tilt)) + " " + f(cy + x * Math.sin(tilt) + y * Math.cos(tilt));
        }
        return d;
      },
      box: (x, y, w, h) => "M" + f(x + j(2)) + " " + f(y + j(2)) + " L" + f(x + w + j(2)) + " " + f(y + j(2)) + " L" + f(x + w + j(2)) + " " + f(y + h + j(2)) +
        " L" + f(x + j(2)) + " " + f(y + h + j(2)) + " L" + f(x + j(2)) + " " + f(y - 5 + j(2)),
      tick: (x, y, s) => "M" + f(x) + " " + f(y + s * 0.5) + " L" + f(x + s * 0.38 + j(2)) + " " + f(y + s * 0.88 + j(2)) + " L" + f(x + s + j(3)) + " " + f(y - s * 0.1 + j(3)),
      figure: (x, y) => "M" + f(x - 14) + " " + f(y) + " a14 14 0 1 0 28 0 a14 14 0 1 0 -28 0 M" + f(x) + " " + f(y + 14) + " L" + f(x - 1) + " " + f(y + 52) +
        " M" + f(x - 22) + " " + f(y + 30) + " L" + f(x + 22) + " " + f(y + 26) + " M" + f(x - 1) + " " + f(y + 52) + " L" + f(x - 18) + " " + f(y + 78) +
        " M" + f(x - 1) + " " + f(y + 52) + " L" + f(x + 18) + " " + f(y + 77),
      burst(x, y) {
        let d = "";
        for (let i = 0; i < 3; i++) { const a = -2.4 + i * 0.6; d += " M" + f(x + Math.cos(a) * 22) + " " + f(y + Math.sin(a) * 22) + " L" + f(x + Math.cos(a) * 40) + " " + f(y + Math.sin(a) * 40); }
        return d.trim();
      },
      scribble(x1, y, x2) {
        let d = "M" + f(x1) + " " + f(y);
        const n = Math.max(2, Math.round((x2 - x1) / 60));
        for (let i = 1; i <= n; i++) d += " L" + f(x1 + (x2 - x1) * i / n) + " " + f(y + (i % 2 ? -6 : 6) + j(2));
        return d;
      },
    };
  }

  /** Rough width of handwriting: Virgil averages about half an em per character. */
  function inkWidth(text, size) { return String(text || "").length * size * 0.5; }

  function inkKit(inner, c) {
    inner.classList.add("yg-ink");
    const svg = h("svg", { class: "yg-draw", viewBox: "0 0 960 1080" });
    append(inner, svg);
    return {
      text(text, x, y, cls, width) {
        const node = h("div", { class: "yg-w " + (cls || "") + (width ? " yg-wrap" : ""), text,
          style: "left:" + Math.round(x) + "px;top:" + Math.round(y) + "px;" + (width ? "width:" + Math.round(width) + "px;" : "") });
        append(inner, node);
        return node;
      },
      path(d, cls) { const node = h("path", { d, class: cls || null }); append(svg, node); return node; },
      add(node) { append(inner, node); return node; },
    };
  }

  /** Writes a line of handwriting from left to right. */
  function write(c, node, rel, duration) {
    const length = (node.textContent || "").length;
    const d = duration || Math.min(1.4, Math.max(0.35, length * 0.045));
    c.tl.fromTo(node, { opacity: 0, clipPath: "inset(-30% 100% -30% -5%)" },
      { opacity: 1, clipPath: "inset(-30% -5% -30% -5%)", duration: d, ease: "none" }, c.at(rel));
    return d;
  }

  /** "01." in the accent colour, then the title. Returns the y below the underline. */
  function inkHeading(k, c, p, x, top, rel) {
    const size = String(p.title || "").length > 18 ? 60 : 76;
    let y = top;
    if (!p.number && p.kicker) { write(c, k.text(p.kicker, x, y - 50, "yg-tag"), rel); }
    const heading = k.text("", x, y, "yg-h1");
    heading.style.fontSize = size + "px";
    if (p.number) append(heading, h("span", { class: "yg-n", text: p.number + ". " }));
    append(heading, document.createTextNode(p.title || ""));
    const shown = (p.number ? p.number + ". " : "") + (p.title || "");
    const d = write(c, heading, rel + 0.15);
    y += size * 1.2 + 6;
    c.draw(k.path(c.ink.line(x, y, x + Math.min(760, inkWidth(shown, size) * 0.9), y - 4)), rel + 0.2 + d, 0.5);
    return y + 24;
  }

  const INK = {};
  const INK_DEMOS = {};

  INK.panelTitle = function (inner, p, c) {
    const k = inkKit(inner, c);
    const x = INK_X;
    c.enterPanel();
    write(c, k.text(p.kicker, x, 250, "yg-tag"), 0.5);
    const big = k.text(p.title, x, 300, "yg-big", 720);
    const d = write(c, big, 0.9, 1.2);
    c.draw(k.path(c.ink.line(x, 530, x + 430, 524)), 0.9 + d, 0.5);
    const count = Math.min(9, num(p.count, 0));
    const countAt = num(p.countAt, 2);
    for (let i = 0; i < count; i++) {
      const cx = x + 40 + i * 120;
      c.draw(k.path(c.ink.ring(cx, 640, 40, 38), "yg-s-accent"), countAt + i * 0.3, 0.45);
      write(c, k.text(String(i + 1), cx - 14, 606, "yg-l"), countAt + i * 0.3 + 0.2, 0.25);
    }
    c.exitPanel();
  };

  INK.rule = function (inner, p, c) {
    const k = inkKit(inner, c);
    const x = INK_X;
    c.enterPanel();
    let y = inkHeading(k, c, p, x, 110, 0.2);
    if (p.subtitle) { write(c, k.text(p.subtitle, x, y - 6, "yg-sub"), num(p.subtitleAt, 0.7)); y += 60; }
    const demo = p.demo && INK_DEMOS[p.demo.type] ? p.demo : null;
    // Without a demo the points have the panel to themselves, so they are large enough to
    // read on a phone (yg-ink-point); beside a demo they keep the demo's narrow column.
    const layout = demo ? INK_DEMOS[demo.type](k, demo, c, x, Math.max(y + 20, 290)) : { points: { x, y: Math.max(y + 30, 300), width: 760, gap: 140 } };
    if (layout && layout.points) {
      (p.points || []).forEach((pt, i) => {
        const node = k.text("→ " + pt.text, layout.points.x, layout.points.y + i * (layout.points.gap || 130), demo ? "yg-p" : "yg-p yg-ink-point", layout.points.width);
        write(c, node, num(pt.at, 1), 0.9);
      });
    }
    c.exitPanel();
  };

  INK.checklist = function (inner, p, c) {
    const k = inkKit(inner, c);
    const x = INK_X;
    c.enterPanel();
    write(c, k.text(p.kicker, x, 150, "yg-tag"), 0.1);
    const titleSize = 76;
    const title = k.text(p.title, x, 190, "yg-h1");
    const d = write(c, title, 0.2);
    c.draw(k.path(c.ink.line(x, 290, x + Math.min(700, inkWidth(p.title, titleSize) * 0.9), 286)), 0.2 + d, 0.5);
    (p.items || []).forEach((item, i) => {
      const y = 360 + i * 120;
      c.draw(k.path(c.ink.box(x, y, 60, 60)), 0.5 + i * 0.15, 0.5);
      write(c, k.text(item.text, x + 92, y - 4, "yg-l"), 0.6 + i * 0.15, 0.6);
      c.draw(k.path(c.ink.tick(x + 8, y + 10, 48), "yg-s-accent"), num(item.at, 1.5 + i * 0.8), 0.35);
    });
    if (p.footer) write(c, k.text(p.footer, x, 380 + (p.items || []).length * 120, "yg-sub"), num(p.footerAt, 4.6));
    c.exitPanel();
  };

  INK_DEMOS.image = function (k, d, c, x, top) {
    const w = 270, hgt = 533;
    const photo = h("div", { class: "yg-photo", style: "left:" + x + "px;top:" + top + "px;width:" + (w + 16) + "px;height:" + (hgt + 16) + "px;" },
      h("img", { src: d.image, alt: "" }));
    k.add(photo);
    c.tl.fromTo(photo, { opacity: 0, y: 30, rotation: -8 }, { opacity: 1, y: 0, rotation: -3, duration: 0.6, ease: "power3.out" }, c.at(num(d.at, 1)));
    const flag = d.flag;
    if (flag && flag.box) {
      const b = flag.box;
      const cx = x + 8 + (b.x + b.w / 2) * w, cy = top + 8 + (b.y + b.h / 2) * hgt;
      const rx = (b.w * w) / 2 + 22, ry = (b.h * hgt) / 2 + 20;
      const at = num(flag.at, 2);
      c.draw(k.path(c.ink.ring(cx, cy, rx, ry), "yg-s-red"), at, 0.8);
      write(c, k.text(flag.text, x + 330, top + 30, "yg-p yg-red", 420), at + 0.7, 1.0);
      c.draw(k.path(c.ink.curve(x + 330, top + 150, x + 300, cy - 20, cx + rx + 6, cy - 6), "yg-s-red"), at + 1.6, 0.5);
    }
    return { points: { x: x + 330, y: top + 250, width: 440, gap: 140 } };
  };

  INK_DEMOS.account = function (k, d, c, x, top) {
    const at = num(d.at, 1.1);
    c.draw(k.path(c.ink.box(x, top, 340, 440)), at, 0.9);
    write(c, k.text(d.title || "Account", x + 28, top + 22, "yg-p"), at + 0.6, 0.5);
    const rows = (d.rows || []).map((text, i) => {
      const node = k.text(text, x + 28, top + 100 + i * 64, "yg-small");
      write(c, node, at + 0.9 + i * 0.25, 0.5);
      return { node, y: top + 120 + i * 64, width: Math.min(290, inkWidth(text, 30)) };
    });
    c.draw(k.path(c.ink.box(x + 24, top + 330, 292, 66), "yg-s-red"), at + 1.8, 0.5);
    write(c, k.text(d.button || "Delete account", x + 44, top + 344, "yg-small yg-red"), at + 2.1, 0.6);
    const tapAt = num(d.tapAt, 3);
    c.draw(k.path(c.ink.burst(x + 310, top + 334)), tapAt, 0.3);
    const clearAt = num(d.clearAt, tapAt + 2);
    rows.forEach((r, i) => {
      c.draw(k.path(c.ink.scribble(x + 22, r.y, x + 40 + r.width), "yg-s-red"), clearAt + i * 0.15, 0.35);
      c.tl.to(r.node, { opacity: 0.45, duration: 0.3 }, c.at(clearAt + 0.4 + i * 0.15));
    });
    write(c, k.text("✓ " + (d.toast || ""), x, top + 470, "yg-sub yg-green"), clearAt + 1.2, 0.8);
    return { points: { x: x + 380, y: top + 20, width: 380, gap: 175 } };
  };

  INK_DEMOS.flow = function (k, d, c, x, top) {
    const nodes = d.nodes || [];
    const step = 140;
    nodes.forEach((n, i) => {
      const y = top + i * step;
      const at = num(n.at, 1 + i);
      let tx = x + 20;
      if (i === 0) { c.draw(k.path(c.ink.figure(x + 40, y + 6)), at, 0.8); tx = x + 90; }
      else c.draw(k.path(c.ink.arrow(x + 56, y - step + 86, x + 58, y - 6)), at - 0.35, 0.3);
      const node = k.text(n.text, tx, y, "yg-l");
      const dw = write(c, node, i === 0 ? at + 0.3 : at);
      if (n.tone === "danger") {
        const w = inkWidth(n.text, 54);
        c.draw(k.path(c.ink.ring(tx + w / 2 + 6, y + 36, w / 2 + 34, 52), "yg-s-red"), at + dw, 0.7);
      }
      n._end = tx + inkWidth(n.text, 54);
    });
    if (nodes.length > 1) {
      c.draw(k.path(c.ink.line(x - 8, top - 6, x - 6, top + (nodes.length - 1) * step + 76, 6), "yg-s-accent"), num(d.sweepAt, 5), 1.2);
    }
    if (d.note && nodes.length) {
      const nx = Math.max(x + 400, nodes[0]._end + 90);
      write(c, k.text(d.note.text, nx, top - 14, "yg-sub", 820 - nx), num(d.note.at, 3), 1.0);
      c.draw(k.path(c.ink.curve(nx - 12, top + 34, nx - 40, top + 40, nodes[0]._end + 18, top + 40)), num(d.note.at, 3) + 0.9, 0.4);
    }
    if (d.stamp) {
      const node = k.text("= " + d.stamp.text + " ", x + 20, top + nodes.length * step + 20, "yg-l");
      append(node, h("span", { style: "color:var(--yg-accent)", text: "✓" }));
      write(c, node, num(d.stamp.at, 6), 1.1);
    }
    return null;
  };

  INK_DEMOS.accessibility = function (k, d, c, x, top) {
    const tl = c.tl;
    const labels = d.labels || {};
    const growAt = num(d.growAt, 2), contrastAt = num(d.contrastAt, 4);
    const tilesAt = num(d.tilesAt, 1);
    // Bigger text: a small "Aa", an arrow, a big "Aa".
    write(c, k.text("Aa", x, top + 40, "yg-p"), tilesAt, 0.3);
    write(c, k.text(labels.text || "bigger text", x, top + 150, "yg-sub"), tilesAt + 0.3, 0.6);
    c.draw(k.path(c.ink.arrow(x + 70, top + 66, x + 140, top + 66)), growAt, 0.3);
    const big = k.text("Aa", x + 160, top - 30, "yg-l");
    big.style.fontSize = "120px";
    big.style.lineHeight = "1";
    write(c, big, growAt + 0.3, 0.4);
    c.draw(k.path(c.ink.tick(x + 250, top + 150, 40), "yg-s-accent"), growAt + 1.0, 0.3);
    // Contrast: a grey pill, then a yellow one over it.
    const px = x + 400;
    c.draw(k.path(c.ink.box(px, top + 30, 260, 66)), tilesAt + 0.2, 0.5);
    const low = k.text(d.button || "Start ride", px + 36, top + 42, "yg-sub yg-dimmed");
    tl.fromTo(low, { opacity: 0 }, { opacity: 0.35, duration: 0.4, ease: "power2.out" }, c.at(tilesAt + 0.4));
    const sticker = h("div", { class: "yg-sticker", text: d.button || "Start ride",
      style: "left:" + px + "px;top:" + (top + 30) + "px;width:260px;height:66px;background:var(--yg-accent);color:#111;" });
    k.add(sticker);
    tl.fromTo(sticker, { opacity: 0, scale: 0.8, rotation: -4 }, { opacity: 1, scale: 1, rotation: -2, duration: 0.4, ease: "back.out(1.8)" }, c.at(contrastAt));
    write(c, k.text(labels.contrast || "contrast", px, top + 150, "yg-sub"), tilesAt + 0.5, 0.5);
    c.draw(k.path(c.ink.tick(px + 170, top + 150, 40), "yg-s-accent"), contrastAt + 0.6, 0.3);
    // The AI tip and the messy content.
    const tipY = top + 240;
    if (d.tip) write(c, k.text(d.tip.text, x, tipY, "yg-sub"), num(d.tip.at, 6), 1.2);
    let cx = x;
    (d.chips || []).forEach((chip) => {
      const label = "“" + chip.text + "”";
      write(c, k.text(label, cx, tipY + 64, "yg-small"), num(chip.at, 0), 0.5);
      cx += inkWidth(label, 30) + 36;
    });
    const testY = tipY + 150;
    c.draw(k.path(c.ink.box(x, testY, 420, 70)), num(d.tip && d.tip.at, 6) + 0.4, 0.5);
    const sample = d.sample || "";
    const long = k.text(sample, x + 18, testY + 14, "yg-sub");
    long.style.fontSize = "32px";
    const breakAt = num(d.breakAt, 8), fixAt = num(d.fixAt, 10);
    write(c, long, breakAt, 1.0);
    const overflow = Math.max(80, inkWidth(sample, 32) - 400);
    const bad = k.path(c.ink.ring(x + 420 + overflow / 2, testY + 34, overflow / 2 + 26, 50), "yg-s-red");
    c.draw(bad, breakAt + 1.0, 0.6);
    const badNote = k.text("✗ " + (d.breakNote || ""), x, testY + 96, "yg-sub yg-red");
    write(c, badNote, breakAt + 1.4, 0.8);
    tl.to([long, bad, badNote], { opacity: 0, duration: 0.3 }, c.at(fixAt));
    const fixed = k.text(sample.slice(0, 24) + "…", x + 18, testY + 14, "yg-sub");
    fixed.style.fontSize = "32px";
    write(c, fixed, fixAt + 0.2, 0.6);
    write(c, k.text("✓ " + (d.fixNote || ""), x, testY + 96, "yg-sub yg-green"), fixAt + 0.6, 0.8);
    return null;
  };

  // ───────────────────────── Timeline ─────────────────────────

  function context(tl, toTime, graphic, host, delayIn, mode, short) {
    const length = graphic.end - graphic.start;
    const at = (rel) => toTime(graphic.start + rel);
    const end = (rel) => toTime(graphic.end + rel);
    return {
      tl, host, length, at, mode, short: !!short, ink: pen(seeded(String(graphic.id))),
      enterColumn() { tl.fromTo(host, { opacity: 0, x: 56 }, { opacity: 1, x: 0, duration: 0.6, ease: "power3.out" }, at(0)); },
      exitColumn() { tl.to(host, { opacity: 0, x: 36, duration: 0.4, ease: "power2.in" }, end(-0.4)); },
      enterPanel() { tl.fromTo(host, { opacity: 0 }, { opacity: 1, duration: 0.45, ease: "power2.out" }, at(delayIn)); },
      exitPanel() { tl.to(host, { opacity: 0, duration: 0.35, ease: "power2.in" }, end(-0.35)); },
      up(targets, rel, stagger) { tl.fromTo(targets, { opacity: 0, y: 20 }, { opacity: 1, y: 0, duration: 0.5, ease: "power3.out", stagger: stagger || 0 }, at(rel)); },
      pop(targets, rel, stagger) { tl.fromTo(targets, { opacity: 0, scale: 0.6 }, { opacity: 1, scale: 1, duration: 0.45, ease: "back.out(1.8)", stagger: stagger || 0 }, at(rel)); },
      grow(targets, rel) {
        if (!targets || (Array.isArray(targets) && !targets.length)) return;
        tl.fromTo(targets, { scaleX: 0 }, { scaleX: 1, duration: 0.5, ease: "power3.out" }, at(rel));
      },
      draw(path, rel, duration) {
        const length = path.getTotalLength();
        // Hidden until it starts: an undrawn stroke with round caps still shows a dot.
        tl.fromTo(path, { opacity: 0 }, { opacity: 1, duration: 0.01 }, at(rel));
        tl.fromTo(path, { strokeDasharray: length + 1, strokeDashoffset: length + 1 }, { strokeDashoffset: 0, duration, ease: "power2.inOut" }, at(rel));
      },
      along(dot, path, rel, duration) {
        const length = path.getTotalLength();
        const state = { p: 0 };
        tl.to(state, { p: 1, duration, ease: "power2.inOut", onUpdate() {
          const point = path.getPointAtLength(state.p * length);
          dot.setAttribute("cx", point.x.toFixed(2));
          dot.setAttribute("cy", point.y.toFixed(2));
        } }, at(rel));
      },
      count(node, from, to, suffix, rel, duration) {
        const state = { v: from };
        tl.to(state, { v: to, duration, ease: "power2.out", onUpdate() { node.textContent = Math.round(state.v) + suffix; } }, at(rel));
      },
    };
  }

  /** glass or ink for one graphic. "mix" writes the panel kinds in ink and keeps cards for the rest. */
  function lookOf(graphic, style) {
    const want = graphic.look || (style.look === "mix" ? (zoneOf(graphic.kind) === "panel" ? "ink" : "glass") : style.look);
    return want === "ink" && INK[graphic.kind] ? "ink" : "glass";
  }

  let current = null;

  /**
   * Builds the graphics and the timeline. Modes:
   * - "preview": every graphic and panel; the app seeks it. No video.
   * - "unit": one graphic or one panel span, with its own time starting at 0. `origin`
   *   (seconds, default the unit's start) is the data time shown at page time 0; the app
   *   puts it on a frame, so beats land on the same frames as in the preview.
   * - "full": every graphic, plus the video move on #bg-video when the style asks for it.
   */
  function load(data, options) {
    const opts = options || {};
    const mode = opts.mode || "preview";
    const gsap = root.gsap;
    if (current) { current.tl.kill(); current.node.remove(); current = null; }

    const p = plan(data);
    const style = Object.assign({}, DEFAULT_STYLE, data.style || {});
    const short = data.layout && data.layout.canvas === "short" ? shortLayout(data.layout.panels, data.layout.drop) : null;
    const stage = short ? SHORT_STAGE : STAGE;
    setStage(stage);
    document.documentElement.style.setProperty("--yg-accent", style.accent);
    const edge = Math.max(0, Math.min(400, num(style.edge, 170)));
    document.documentElement.style.setProperty("--yg-edge", edge + "px");
    const panelOffset = style.panel === "shade" ? Math.max(0, edge - PANEL_PAD) : 0;
    const rate = parseRate(data.fps);

    let shift = 0, items = p.items, spans = p.spans;
    if (mode === "unit") {
      const unit = p.units.find((u) => u.id === opts.unit);
      if (!unit) throw new Error("Unknown unit: " + opts.unit);
      shift = typeof opts.origin === "number" ? opts.origin : unit.start;
      items = unit.kind === "panel" ? [] : p.items.filter((g) => g.id === unit.id);
      spans = unit.kind === "panel" ? p.spans.filter((s) => s.id === unit.id) : [];
    }
    const toTime = (seconds) => Math.max(0, Math.round((seconds - shift) * rate) / rate);

    const container = h("div", { id: "yg-root" });
    (document.getElementById("stage") || document.body).appendChild(container);
    const tl = gsap.timeline({ paused: true });

    const placement = short ? "short-" + short.panels : style.moveVideo ? "move" : "stay";
    const byID = new Map(p.items.map((g) => [g.id, g]));
    for (const span of spans) {
      const inkSpan = span.items.every((id) => lookOf(byID.get(id), style) === "ink");
      if (inkSpan) {
        const veil = h("div", { class: "yg-veil " + placement });
        if (short && short.panels === "sheet" && short.drop) veil.style.top = short.drop + "px";
        if (short && short.panels === "split") append(veil, splitFrame(short));
        append(container, veil);
        tl.fromTo(veil, { opacity: 0 }, { opacity: 1, duration: PANEL_SLIDE, ease: "power2.out" }, toTime(span.start));
        tl.to(veil, { opacity: 0, duration: PANEL_SLIDE, ease: "power2.in" }, toTime(span.end));
        continue;
      }
      const bg = h("div", { class: "yg-panel-bg " + (style.panel === "solid" ? "solid" : "shade") + " " + placement });
      if (short && short.panels === "sheet" && short.drop) { bg.style.top = short.sheetTop + "px"; bg.style.height = (SHORT_STAGE.height - short.sheetTop) + "px"; }
      if (short && short.panels === "split") append(bg, splitFrame(short));
      append(container, bg);
      if (short) {
        // A Short's sheet rises from the bottom; the full shade and the split fade in.
        const rise = short.panels === "sheet" ? 160 : 0;
        tl.fromTo(bg, { opacity: 0, y: rise }, { opacity: 1, y: 0, duration: PANEL_SLIDE, ease: "power3.out" }, toTime(span.start));
        tl.to(bg, { opacity: 0, y: rise, duration: PANEL_SLIDE, ease: "power3.in" }, toTime(span.end));
      } else if (style.panel === "solid" && style.moveVideo) {
        tl.fromTo(bg, { opacity: 1, x: 960 }, { x: 0, duration: PANEL_SLIDE, ease: smooth }, toTime(span.start));
        tl.to(bg, { x: 960, duration: PANEL_SLIDE, ease: smooth }, toTime(span.end));
      } else {
        tl.fromTo(bg, { opacity: 0, x: 160 }, { opacity: 1, x: 0, duration: PANEL_SLIDE, ease: "power3.out" }, toTime(span.start));
        tl.to(bg, { opacity: 0, x: 160, duration: PANEL_SLIDE, ease: "power3.in" }, toTime(span.end));
      }
    }

    if (mode === "full" && style.moveVideo && !short) {
      // The video moves aside; a blurred copy fills the space it leaves, and its right
      // edge fades into that copy. In the app these three are native (see the plan).
      const video = document.getElementById("bg-video");
      const fill = document.getElementById("bg-fill");
      p.spans.forEach((span, i) => {
        if (!video) return;
        const first = i === 0;
        tl.fromTo(video, { x: 0 }, { x: -VIDEO_SHIFT, duration: PANEL_SLIDE, ease: smooth, immediateRender: first }, toTime(span.start));
        tl.to(video, { x: 0, duration: PANEL_SLIDE, ease: smooth }, toTime(span.end));
        tl.fromTo(video, { "--yg-fade": "1920px" }, { "--yg-fade": "1700px", duration: PANEL_SLIDE, ease: "none", immediateRender: first }, toTime(span.start));
        tl.to(video, { "--yg-fade": "1920px", duration: PANEL_SLIDE, ease: "none" }, toTime(span.end));
        if (fill) {
          tl.fromTo(fill, { opacity: 0 }, { opacity: 1, duration: PANEL_SLIDE, ease: "power2.out", immediateRender: first }, toTime(span.start));
          tl.to(fill, { opacity: 0, duration: PANEL_SLIDE, ease: "power2.in" }, toTime(span.end));
        }
      });
    }

    const screen = p.items.find((g) => g.kind === "endScreen");
    if (mode === "full" && screen && !short) {
      // The end screen: the video moves into the speaker's frame over the blurred copy.
      const video = document.getElementById("bg-video");
      const fill = document.getElementById("bg-fill");
      const f = endLayout(screen.props).frame;
      if (video) {
        tl.fromTo(video, { x: 0, y: 0, scale: 1, transformOrigin: "0 0" },
          { x: f.x, y: f.y, scale: f.w / 1920, transformOrigin: "0 0", duration: PANEL_SLIDE, ease: smooth, immediateRender: false }, toTime(screen.start));
      }
      if (fill) tl.fromTo(fill, { opacity: 0 }, { opacity: 1, duration: PANEL_SLIDE, ease: "power2.out", immediateRender: false }, toTime(screen.start));
    }

    const firstInSpan = new Set(p.spans.map((s) => s.items[0]));
    const places = {};
    for (const graphic of items) {
      const zone = zoneOf(graphic.kind);
      if (short && zone === "screen") continue;   // Shorts have no end screen
      let rect = zone === "column" ? COLUMN : zone === "screen" ? STAGE : (style.moveVideo ? PANEL_MOVE : PANEL_STAY);
      let scaled = null;
      if (zone === "speaker") {
        // A point on the canvas, the Short's as well: the badge's own size comes from its chips.
        const spot = logoSpot(graphic.props, short);
        rect = { left: spot.x, top: spot.y, width: 0, height: 0 };
      } else if (short) {
        // The template's zone, scaled into the Short's own zone for it.
        const z = zone === "column" ? short.column : short.panel;
        const size = zone === "column" ? COLUMN : PANEL_MOVE;
        rect = { left: z.x, top: z.y, width: size.width * z.scale, height: size.height * z.scale };
        scaled = { width: size.width, height: size.height, scale: z.scale };
      }
      const host = h("div", { class: "yg-host yg-kind-" + graphic.kind, "data-graphic-id": graphic.id,
        style: "left:" + rect.left + "px;top:" + rect.top + "px;width:" + rect.width + "px;height:" + rect.height + "px;" });
      const look = lookOf(graphic, style);
      const inner = h("div", { class: "yg-inner" + (zone === "panel" && !style.moveVideo && !short ? " yg-scaled" : "") });
      if (scaled) {
        inner.style.width = scaled.width + "px"; inner.style.height = scaled.height + "px";
        inner.style.transformOrigin = "0 0"; inner.style.transform = "scale(" + scaled.scale + ")";
      } else if (zone === "panel" && style.moveVideo && panelOffset && look === "glass") inner.style.transform = "translateX(" + panelOffset + "px)";
      append(host, inner);
      // The place carries the owner's move and scale; the host keeps the template's own
      // motion, so the two never fight over one transform. Between them, the style's size.
      const place = h("div", { class: "yg-place" });
      place.style.transformOrigin = rect.left + "px " + rect.top + "px";
      setPlace(place, graphic.transform);
      const grow = sizeOf(zone, style, short);
      if (grow > 1) {
        const anchor = SIZE_ANCHOR[zone];
        const sized = h("div", { class: "yg-place yg-sized" });
        sized.style.transformOrigin = anchor.x + "px " + anchor.y + "px";
        sized.style.transform = "scale(" + grow + ")";
        append(sized, host);
        append(place, sized);
      } else {
        append(place, host);
      }
      append(container, place);
      places[graphic.id] = { place, host, rect, graphic };
      const delayIn = zone === "panel" && firstInSpan.has(graphic.id) ? 0.3 : 0;
      (look === "ink" ? INK : KINDS)[graphic.kind](inner, graphic.props || {}, context(tl, toTime, graphic, host, delayIn, mode, short));
    }

    current = { tl, node: container, plan: p, places, shift, stage };
    root.__timelines = root.__timelines || {};
    root.__timelines[opts.compositionId || "yam-graphics"] = tl;
    return tl;
  }

  /** The light frame round the picture in a Short's split layout: an outer shadow only. */
  function splitFrame(short) {
    const f = short.splitFrame;
    return h("div", { class: "yg-split-frame", style: "left:" + f.x + "px;top:" + f.y + "px;width:" + f.w + "px;height:" + f.h + "px;" });
  }

  /** Sizes the page and the stage for a canvas: 1920×1080, or a Short's 1080×1920. */
  function setStage(size) {
    const root = document.documentElement;
    root.style.setProperty("--yg-w", size.width + "px");
    root.style.setProperty("--yg-h", size.height + "px");
  }

  /** The design canvas the graphics are on now. */
  function stageSize() { return current ? { width: current.stage.width, height: current.stage.height } : { width: STAGE.width, height: STAGE.height }; }

  // ───────────────────────── Captions (a Short's Preview) ─────────────────────────
  // The app lays a Short's captions out (lines, size, where each one's bottom sits) and
  // the export burns the same with libass. Here they are drawn for the Preview only.

  let captionList = null;
  let captionNode = null;
  /** {size, outline, left, right, items: [{start, end, lines, bottom}]}, or null for none. */
  function captions(data) {
    captionList = data && Array.isArray(data.items) ? data : null;
    if (!captionNode) {
      captionNode = h("div", { id: "yg-captions" });
      (document.getElementById("stage") || document.body).appendChild(captionNode);
    }
    captionNode.textContent = "";
    captionNode.dataset.shown = "";
    if (current) showCaption(current.tl.time() + current.shift);
  }
  function showCaption(time) {
    if (!captionNode) return;
    const found = captionList ? captionList.items.find((c) => time >= c.start && time < c.end) : null;
    const key = found ? found.start + ":" + found.bottom + ":" + found.lines.join("|") : "";
    if (captionNode.dataset.shown === key) return;
    captionNode.dataset.shown = key;
    captionNode.textContent = "";
    if (!found) return;
    // libass's line ends 0.236 em under the baseline, a 1.18 em CSS line 0.32 em under it.
    const box = h("div", { class: "yg-cap", style: "bottom:" + (stageSize().height - found.bottom - 0.084 * captionList.size) + "px;font-size:" + captionList.size +
      "px;-webkit-text-stroke-width:" + (2 * captionList.outline) + "px;left:" + num(captionList.left, 40) + "px;right:" + num(captionList.right, 40) + "px;" });
    found.lines.forEach((line, i) => { if (i) append(box, h("br")); append(box, line); });
    append(captionNode, box);
  }

  /** A graphic's move and scale on the picture: `transform` {x, y, scale} in design
   * pixels, scaled from the top-left corner of the graphic's zone. */
  function setPlace(place, transform) {
    const x = num(transform && transform.x, 0), y = num(transform && transform.y, 0), s = num(transform && transform.scale, 1);
    place.style.transform = x || y || s !== 1 ? "translate(" + x + "px," + y + "px) scale(" + s + ")" : "";
  }

  /** Moves and scales graphics without rebuilding them: {id: transform or null}. */
  function place(transforms) {
    if (!current) return;
    for (const id in transforms) {
      const entry = current.places[id];
      if (entry) setPlace(entry.place, transforms[id]);
    }
  }

  // What a graphic draws: SVG shapes, images, boxes with a fill or a border, and text,
  // measured tightly. Containers that only hold others add nothing of their own.
  function paintedRects(el) {
    if (el instanceof SVGElement) {
      if (el.tagName === "svg" || el.tagName === "g" || el.tagName === "defs") return [];
      return [el.getBoundingClientRect()];
    }
    if (el.tagName === "IMG") return [el.getBoundingClientRect()];
    const cs = getComputedStyle(el);
    const fill = cs.backgroundImage !== "none" || !/^(transparent|rgba\(\d+, \d+, \d+, 0\))$/.test(cs.backgroundColor);
    const border = ["Top", "Right", "Bottom", "Left"].some((side) => parseFloat(cs["border" + side + "Width"]) > 0);
    if (fill || border) return [el.getBoundingClientRect()];
    const rects = [];
    for (const node of el.childNodes) {
      if (node.nodeType !== 3 || !node.textContent.trim()) continue;
      const range = document.createRange();
      range.selectNode(node);
      rects.push(range.getBoundingClientRect());
    }
    return rects;
  }
  function shows(el, host) {
    for (let node = el; node; node = node.parentElement) {
      const cs = getComputedStyle(node);
      if (cs.display === "none" || cs.visibility === "hidden" || parseFloat(cs.opacity) < 0.02) return false;
      if (node === host) return true;
    }
    return true;
  }
  /** The box a graphic draws now, in design pixels, or null when nothing of it shows. */
  function drawnBox(entry) {
    const stage = document.getElementById("stage") || document.body;
    const sr = stage.getBoundingClientRect();
    const k = sr.width / stageSize().width || 1;
    if (!shows(entry.host, entry.host)) return null;
    let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
    for (const el of entry.host.querySelectorAll("*")) {
      if (!shows(el, entry.host)) continue;
      for (const r of paintedRects(el)) {
        if (r.width <= 0 && r.height <= 0) continue;
        left = Math.min(left, r.left); top = Math.min(top, r.top);
        right = Math.max(right, r.right); bottom = Math.max(bottom, r.bottom);
      }
    }
    if (!(right > left && bottom > top)) return null;
    return { x: (left - sr.left) / k, y: (top - sr.top) / k, w: (right - left) / k, h: (bottom - top) / k };
  }

  /** Each graphic's box once it has fully come in (half a second before it ends), without
   * its own move and scale, and the point its scale works from: {id: {x, y, w, h, ox, oy}}.
   * The playhead is put back afterwards. */
  function bounds() {
    if (!current) return {};
    const tl = current.tl, now = tl.time(), out = {};
    for (const id in current.places) {
      const entry = current.places[id], g = entry.graphic;
      const saved = entry.place.style.transform;
      entry.place.style.transform = "";
      tl.time(Math.max(0, Math.max(g.start, g.end - 0.5) - current.shift), false);
      const box = drawnBox(entry);
      entry.place.style.transform = saved;
      if (box) out[id] = Object.assign(box, { ox: entry.rect.left, oy: entry.rect.top });
    }
    tl.time(now, false);
    return out;
  }

  /** The graphics showing now, as drawn, move and scale included: {id: {x, y, w, h}}. */
  function boxes() {
    if (!current) return {};
    const out = {};
    for (const id in current.places) {
      const box = drawnBox(current.places[id]);
      if (box) out[id] = box;
    }
    return out;
  }

  // ───────────────────────── Thumbnail ─────────────────────────

  const SVG_NS = "http://www.w3.org/2000/svg";
  /** A white outline round whatever it filters: the alpha, grown by `width` px, filled white, under it. */
  function outlineFilter(width) {
    const radius = Math.max(1, Math.min(16, num(width, 9)));
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("width", "0"); svg.setAttribute("height", "0");
    svg.style.position = "absolute";
    const filter = document.createElementNS(SVG_NS, "filter");
    const attrs = { id: "yg-outline", x: "-5%", y: "-5%", width: "110%", height: "110%" };
    for (const key in attrs) filter.setAttribute(key, attrs[key]);
    const steps = [
      ["feMorphology", { in: "SourceAlpha", operator: "dilate", radius: String(radius), result: "dilated" }],
      ["feGaussianBlur", { in: "dilated", stdDeviation: String(Math.min(1.4, radius * 0.3)), result: "grown" }],
      ["feFlood", { "flood-color": "#ffffff", result: "white" }],
      ["feComposite", { in: "white", in2: "grown", operator: "in", result: "ring" }],
    ];
    for (const [tag, values] of steps) {
      const node = document.createElementNS(SVG_NS, tag);
      for (const key in values) node.setAttribute(key, values[key]);
      filter.appendChild(node);
    }
    const merge = document.createElementNS(SVG_NS, "feMerge");
    for (const name of ["ring", "SourceGraphic"]) {
      const node = document.createElementNS(SVG_NS, "feMergeNode");
      node.setAttribute("in", name);
      merge.appendChild(node);
    }
    filter.appendChild(merge);
    svg.appendChild(filter);
    return svg;
  }

  /** Lines of the title; words between asterisks take the accent colour (or its band, with highlight). Text only. */
  function accented(node, text) {
    String(text).split("\n").slice(0, 3).forEach((line, index) => {
      if (index > 0) node.appendChild(document.createElement("br"));
      line.split("*").forEach((part, i) => {
        if (!part) return;
        node.appendChild(i % 2 ? h("em", { text: part }) : document.createTextNode(part));
      });
    });
  }

  /** The largest title size, from 170 px down, at which the text column holds everything. */
  function fitTitle(title, column) {
    for (let size = 170; size >= 56; size -= 4) {
      title.style.fontSize = size + "px";
      if (column.scrollHeight <= column.clientHeight + 1 && title.scrollWidth <= title.clientWidth + 1) return size;
    }
    return 56;
  }

  /**
   * Moves the cut-out speaker clear of the title column (tag, title lines and picture):
   * each band of the speaker's outline keeps clear of the text beside it, so wide
   * shoulders below the title do not push the head away. The speaker moves as little as
   * possible toward the far side, and gets smaller (never past `zoom`, growing from the
   * bottom of their box) when the head would leave the picture. Returns the scale.
   */
  function placeClear(root, cut, column, speaker, head, bands, zoom, textOnLeft, smallest) {
    const stage = root.getBoundingClientRect();
    const k = 1920 / (stage.width || 1920);
    const text = [];
    const add = (r) => {
      if (r.width <= 0 || r.height <= 0) return;
      text.push({ x0: (r.left - stage.left) * k, x1: (r.right - stage.left) * k, y0: (r.top - stage.top) * k, y1: (r.bottom - stage.top) * k });
    };
    for (const node of column.children) {
      if (node.classList.contains("yg-thumb-title")) {
        const range = document.createRange();
        range.selectNodeContents(node);
        Array.from(range.getClientRects()).forEach(add);
      } else add(node.getBoundingClientRect());
    }
    const gapX = 56, gapY = 24, margin = 40;
    const box = { x: num(speaker.x, 0), y: num(speaker.y, 0), w: num(speaker.w, 1920), h: num(speaker.h, 1080) };
    const ox = box.x + box.w / 2, oy = box.y + box.h;
    const map = (r, s) => ({ x0: ox + (num(r.x, 0) - ox) * s, x1: ox + (num(r.x, 0) + num(r.w, 0) - ox) * s,
                             y0: oy + (num(r.y, 0) - oy) * s, y1: oy + (num(r.y, 0) + num(r.h, 0) - oy) * s });
    const parts = bands && bands.length ? bands : [box];
    const top = head || box;
    // For a scale: the smallest move (toward the far side) that clears the text, and the
    // largest that keeps the head inside the picture.
    const limits = (s) => {
      let need = textOnLeft ? -Infinity : Infinity;
      for (const part of parts) {
        const q = map(part, s);
        for (const t of text) {
          if (q.y1 <= t.y0 - gapY || q.y0 >= t.y1 + gapY) continue;
          need = textOnLeft ? Math.max(need, t.x1 + gapX - q.x0) : Math.min(need, t.x0 - gapX - q.x1);
        }
      }
      const h = map(top, s);
      return textOnLeft ? { low: need, high: 1920 - margin - h.x1 } : { low: margin - h.x0, high: need };
    };
    let s = zoom, found = limits(s);
    for (let next = zoom; next >= (smallest || 0.4) && found.low > found.high; next -= 0.02) { s = next; found = limits(s); }
    let tx = textOnLeft ? Math.max(found.low, Math.min(0, found.high)) : Math.min(found.high, Math.max(0, found.low));
    if (!isFinite(tx)) tx = 0;
    cut.style.transform = "translateX(" + tx.toFixed(1) + "px) scale(" + s.toFixed(4) + ")";
    return s;
  }

  /**
   * Draws the picture beside the title `imageSize` (1 to 1.6) times its usual size: at
   * most 520×340 and never larger than the file. The title then fits what is left.
   */
  function sizePicture(img, imageSize) {
    const k = Math.max(1, Math.min(1.6, num(imageSize, 1)));
    if (!img || k === 1 || !img.naturalWidth || !img.naturalHeight) return;
    const f = k * Math.min(1, 520 / img.naturalWidth, 340 / img.naturalHeight);
    img.style.maxWidth = "none"; img.style.maxHeight = "none";
    img.style.width = (img.naturalWidth * f).toFixed(1) + "px";
    img.style.height = (img.naturalHeight * f).toFixed(1) + "px";
  }

  /**
   * A YouTube thumbnail on the stage (drawn at 1280×720): the frame, the speaker cut out
   * and outlined, a big title with *accent* words, a tag, and a photo. Resolves with the
   * title's size once the pictures have loaded and the title fits.
   */
  function thumbnail(data) {
    if (current) { current.tl.kill(); current.node.remove(); current = null; }
    setStage(STAGE);
    const old = document.getElementById("yg-thumb");
    if (old) old.remove();
    const d = data || {};
    document.documentElement.style.setProperty("--yg-accent", d.accent || DEFAULT_STYLE.accent);
    const root = h("div", { id: "yg-thumb", class: "yg-thumb bg-" + (d.background || "dim") + " side-" + (d.side === "left" ? "left" : "right")
      + (d.highlight ? " highlight" : "") });
    const pictures = [];
    const picture = (src, cls) => { const img = h("img", { class: cls, src, alt: "" }); pictures.push(img); return img; };
    append(root, outlineFilter(d.outlineWidth));
    if (d.frame) append(root, picture(d.frame, "yg-thumb-bg"));
    const frost = d.background === "frost" && d.frame;
    // The white frost: a blurred copy of the frame under a white wash, faded out toward the speaker.
    if (frost) {
      const layer = h("div", { class: "yg-thumb-frost" });
      append(layer, picture(d.frame, "yg-thumb-frost-bg"));
      append(root, layer);
    }
    append(root, h("div", { class: "yg-thumb-scrim" }));
    if (d.cutout) {
      const cut = picture(d.cutout, "yg-thumb-cut" + (d.outline ? " outlined" : ""));
      const zoom = Math.max(1, Math.min(1.6, num(d.zoom, 1)));
      const speaker = d.speaker || { x: 0, y: 0, w: 1920, h: 1080 };
      cut.style.transformOrigin = (num(speaker.x, 0) + num(speaker.w, 1920) / 2) + "px " + (num(speaker.y, 0) + num(speaker.h, 1080)) + "px";
      if (zoom !== 1) cut.style.transform = "scale(" + zoom + ")";
      append(root, cut);
    }
    const column = h("div", { class: "yg-thumb-text" });
    if (d.tag) append(column, h("div", { class: "yg-thumb-tag", text: d.tag }));
    const title = h("div", { class: "yg-thumb-title" });
    accented(title, d.title || "");
    append(column, title);
    if (d.image) append(column, picture(d.image, "yg-thumb-image"));
    append(root, column);
    append(document.getElementById("stage") || document.body, root);
    const loaded = pictures.map((img) => (img.decode ? img.decode().catch(() => null) : Promise.resolve()));
    return Promise.all(loaded).then(() => document.fonts.ready).then(() => {
      sizePicture(root.querySelector(".yg-thumb-image"), d.imageSize);
      const size = fitTitle(title, column);
      const cut = root.querySelector(".yg-thumb-cut");
      if (d.place === "clear" && cut) {
        const zoom = Math.max(1, Math.min(1.6, num(d.zoom, 1)));
        // Under the frost the frame moves with the speaker, so it may not get smaller than the picture.
        placeClear(root, cut, column, d.speaker || { x: 0, y: 0, w: 1920, h: 1080 }, d.head, d.bands, zoom, d.side === "left", frost ? 1 : 0.4);
      }
      if (frost && cut) {
        root.querySelectorAll(".yg-thumb-bg, .yg-thumb-frost-bg").forEach((img) => {
          img.style.transformOrigin = cut.style.transformOrigin;
          img.style.transform = cut.style.transform;
        });
      }
      return size;
    });
  }

  /** Reads the inline JSON and loads it. Used by page.html. A thumbnail page starts empty
   * and is drawn by `thumbnail(data)`. */
  function boot(options) {
    if (options && options.mode === "thumbnail") return null;
    const data = JSON.parse(document.getElementById("graphics-data").textContent);
    return load(data, options);
  }

  /** Moves the playhead. Events stay on, so count-ups and the route dot update. */
  function seek(seconds) {
    if (current) current.tl.time(Math.max(0, seconds), false);
    showCaption(seconds);
  }

  const api = { VERSION, plan, load, boot, seek, place, bounds, boxes, thumbnail, endLayout, shortLayout, stageSize, captions,
    smooth, zoneOf, PANEL_SLIDE, VIDEO_SHIFT };
  if (typeof module !== "undefined" && module.exports) module.exports = api;
  else root.YamGraphics = api;
})(typeof window !== "undefined" ? window : globalThis);
