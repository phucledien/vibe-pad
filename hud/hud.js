"use strict";
// Renders state pushed by the native app. No logic here acts on Herdr.

const $ = (id) => document.getElementById(id);
const FACE = ["cross", "circle", "square", "triangle"];
const PILL = { l1: "L1", r1: "R1", l2: "L2", r2: "R2", l3: "L3", r3: "R3", share: "SHARE", options: "OPT", touchpad: "PAD", ps: "PS" };
const ACTIONS = {
  handsfree: "Hands-free mic",
  confirm: "Enter · send draft",
  back: "Esc · cancel",
  mode: "Agent mode",
  interrupt: "Stop agent",
  zoom: "Zoom pane",
  prev_tab: "Prev stage",
  next_tab: "Next stage",
  prev_workspace: "Prev world",
  next_workspace: "Next world",
  attention: "Jump to alert",
  toggle_hud: "HUD size",
  language: "Voice language",
};
const ORDER = ["cross", "circle", "square", "triangle", "r1", "l2", "r2", "share", "options", "touchpad", "l3", "r3", "ps"];
const svgNS = "http://www.w3.org/2000/svg";

let state = null;
let legendKey = "";
let sentUntil = 0;

function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
}

function glyph(name) {
  const svg = document.createElementNS(svgNS, "svg");
  svg.setAttribute("class", "glyph");
  const use = document.createElementNS(svgNS, "use");
  use.setAttribute("href", "#g-" + name);
  svg.appendChild(use);
  return svg;
}

function cap(button) {
  if (FACE.includes(button)) return glyph(button);
  if (button === "dpad") return glyph("dpad");
  return el("span", "pill", PILL[button] || button.toUpperCase());
}

function actionLabel(action) {
  if (typeof action !== "string") return "";
  if (action.startsWith("keys:")) return "Keys " + action.slice(5);
  if (action.startsWith("text:")) return "Type “" + action.slice(5) + "”";
  return ACTIONS[action] || action;
}

function bindRow(buttons, label, key) {
  const row = el("div", "bind");
  row.dataset.key = key;
  const caps = el("span", "cap");
  buttons.forEach((b) => caps.appendChild(cap(b)));
  row.append(caps, el("span", "", label));
  return row;
}

function renderLegend(bindings, talk) {
  const key = JSON.stringify([bindings, talk]);
  if (key === legendKey) return;
  legendKey = key;
  const legend = $("legend");
  legend.replaceChildren();
  legend.append(
    bindRow([talk], "Hold to talk", talk),
    bindRow(["dpad"], "Move between panes", "dpad"),
    bindRow(["l3"], "", "lstick"),
    bindRow(["r3"], "", "rstick"),
  );
  // Sticks: relabel the two placeholder rows.
  const [ls, rs] = legend.querySelectorAll('[data-key="lstick"], [data-key="rstick"]');
  ls.replaceChildren(el("span", "cap"), el("span", "", "Arrow keys"));
  ls.firstChild.appendChild(el("span", "pill", "L-STICK"));
  rs.replaceChildren(el("span", "cap"), el("span", "", "Scroll history"));
  rs.firstChild.appendChild(el("span", "pill", "R-STICK"));
  for (const button of ORDER) {
    const b = bindings[button];
    if (!b || b === "none" || button === talk) continue;
    if (typeof b === "string") legend.appendChild(bindRow([button], actionLabel(b), button));
    else {
      const parts = [];
      if (b.tap) parts.push(actionLabel(b.tap));
      if (b.hold) parts.push("hold: " + actionLabel(b.hold));
      legend.appendChild(bindRow([button], parts.join(" · "), button));
    }
  }
}

function renderChips(container, items, small) {
  container.replaceChildren(
    ...items.map((item) => {
      const chip = el("div", "chip" + (item.focused ? " focused" : ""));
      chip.append(el("span", "num", String(item.number)), el("span", "gem " + item.status), el("span", "name", item.label || ""));
      if (small && !item.label) chip.lastChild.remove();
      return chip;
    }),
  );
}

function renderMap(layout) {
  const map = $("minimap");
  const box = map.getBoundingClientRect();
  const area = layout.area || { width: 1, height: 1 };
  const sx = box.width / Math.max(1, area.width);
  const sy = box.height / Math.max(1, area.height);
  const gap = 2;
  const nodes = layout.panes.map((p) => {
    const r = p.rect || { x: 0, y: 0, width: area.width, height: area.height };
    const node = el("div", "pane " + (p.status || "none") + (p.focused ? " focused" : ""));
    node.style.left = r.x * sx + gap + "px";
    node.style.top = r.y * sy + gap + "px";
    node.style.width = Math.max(10, r.width * sx - gap * 2) + "px";
    node.style.height = Math.max(10, r.height * sy - gap * 2) + "px";
    const who = el("div", "who");
    who.append(el("span", "gem " + (p.agent ? p.status : "none")), el("span", "", p.agent || "shell"));
    node.append(who);
    if (p.title) node.append(el("div", "what", p.title));
    node.append(el("span", "pid", p.id));
    return node;
  });
  if (layout.zoomed) nodes.push(el("span", "zoom-tag", "ZOOM"));
  if (!layout.panes.length) nodes.push(el("div", "pane", "No panes"));
  map.replaceChildren(...nodes);
}

function renderVoice(v) {
  const voice = $("voice");
  const phase = Date.now() < sentUntil && v.phase === "idle" ? "sent" : v.phase;
  voice.className = "voice " + phase;
  const title = $("voice-title"),
    sub = $("voice-sub");
  if (["opening", "recording", "finishing", "stalled"].includes(v.phase)) {
    title.textContent = v.phase === "opening" ? "Opening mic…" : v.phase === "finishing" ? "Wrapping up…" : v.phase === "stalled" ? "Audio interrupted…" : v.handsFree ? "REC · hands-free" : "REC";
    sub.textContent = (v.handsFree ? "Tap R1 to send · ○ cancels · " : "Release to send · ") + "→ " + (v.target || "focused pane");
  } else if (v.phase === "transcribing") {
    title.textContent = "Transcribing…";
    sub.textContent = "Whisper on-device · " + v.language.toUpperCase();
  } else if (phase !== "sent") {
    title.replaceChildren("Hold ", el("b", "key", (state.talk || "l1").toUpperCase()), " to talk · tap ", el("b", "key", "R1"), " hands-free");
    sub.textContent = "→ " + (state.focus.label || "focused pane");
  }
  $("lang").textContent = (v.language || "en").toUpperCase();
  const draft = $("draft");
  draft.hidden = !v.draft;
  $("draft-text").textContent = v.draft ? "“" + v.draft + "” → " + (v.draftTarget || "?") : "";
}

function tickTimer() {
  const v = state && state.voice;
  const live = v && ["opening", "recording", "finishing", "stalled"].includes(v.phase) && v.started;
  $("voice-timer").textContent = live ? formatTime((Date.now() - v.started) / 1000) : "";
  requestAnimationFrame(tickTimer);
}
function formatTime(s) {
  const m = Math.floor(s / 60),
    r = Math.floor(s % 60);
  return m + ":" + String(r).padStart(2, "0");
}

function render() {
  if (!state) return;
  document.body.className = state.mode || "full";
  const pad = $("link-pad"),
    herdr = $("link-herdr");
  pad.className = "link " + (state.controller ? "on" : "off");
  herdr.className = "link " + (state.herdr ? "on" : "off");
  renderChips($("workspaces"), state.workspaces, false);
  renderChips($("tabs"), state.tabs, true);
  renderMap(state.layout);
  $("target-label").textContent = state.focus.label || "—";
  const badge = $("target-status");
  const status = state.focus.agent ? state.focus.status : "shell";
  badge.className = "badge " + status;
  badge.textContent = status;
  renderVoice(state.voice);
  renderLegend(state.bindings || {}, state.talk || "l1");
}

function toast(text, type, rich) {
  const box = $("toasts");
  const node = el("div", "toast " + (type || "info"));
  if (rich) node.append(...rich);
  else node.textContent = text;
  box.appendChild(node);
  while (box.children.length > 3) box.firstChild.remove();
  setTimeout(() => {
    node.classList.add("leaving");
    setTimeout(() => node.remove(), 320);
  }, type === "error" || type === "alert" ? 5200 : 3000);
}

function flash(button) {
  let key = button;
  if (button.startsWith("dpad-")) key = "dpad";
  const row = document.querySelector('.bind[data-key="' + key + '"]');
  if (row) {
    row.classList.remove("flash");
    void row.offsetWidth;
    row.classList.add("flash");
    setTimeout(() => row.classList.remove("flash"), 160);
  }
}

window.padEvent = (event) => {
  switch (event.kind) {
    case "state":
      state = event;
      render();
      break;
    case "toast":
      toast(event.text, event.type);
      break;
    case "press":
      flash(event.button);
      break;
    case "sent":
      sentUntil = Date.now() + 1800;
      toast(null, "sent", [el("b", "", event.typed ? "TYPED ▸ " : "SENT ▸ "), event.target + ": “" + event.text + "”"]);
      if (state) {
        $("voice-title").textContent = event.typed ? "Typed ✓" : "Sent ✓";
        $("voice-sub").textContent = event.text;
        renderVoice(state.voice);
      }
      break;
  }
};

addEventListener("resize", render);
requestAnimationFrame(tickTimer);
window.webkit?.messageHandlers?.pad?.postMessage({ action: "ready" });
