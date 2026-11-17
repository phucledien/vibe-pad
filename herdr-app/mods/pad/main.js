// Herdr Pad panel: an arcade cabinet for the DualShock inside the window.
// The herdr-pad helper (a plain binary in this mod) owns the controller and
// the mic. The panel starts it when it isn't running, the helper writes
// ~/.config/herdr-pad/state.json, and this panel draws it. Buttons queue
// actions with `herdr-pad --send <action>`. Click the header for settings
// (the same mod, opened as a popup with props.settings).
import { View, div, svg, image } from "gpui-kit";
import { v_flex, h_flex } from "gpui-base";
import { agents, home, appHome, props, readTextFile, watchFolder, exec, run, checking, openOverlay, closeOverlay } from "herdr";

const PIXEL = "Press Start 2P";
const LCD = "VT323";
const C = {
  cross: "#7cb2e8", circle: "#ff6b6b", square: "#e79bd9", triangle: "#3ee0c4",
  gold: "#ffd25a", rec: "#ff2e5f", lcd: "#5fd4ff", lcdDim: "#0f2a36", ink: "#07081a",
  idle: "#1d2142", line: "#3ee0c4", stage: "#0b0d20", muted: "#7a80aa", text: "#eef0ff",
};
const STATUS = { working: "#4f8cff", blocked: "#ff9a1f", done: "#2fe08a", idle: "#7a80aa", unknown: "#5f6590" };
const PILL = { l1: "L1", r1: "R1", l2: "L2", r2: "R2", l3: "L3", r3: "R3", share: "SHARE", options: "OPT", touchpad: "PAD", ps: "PS" };
const FACES = ["cross", "circle", "square", "triangle"];
const LIVE = ["opening", "recording", "finishing", "stalled"];

// Fighting-game names for each action.
const MOVES = {
  handsfree: "Hands-free", confirm: "Confirm", back: "Back dash", mode: "Stance switch", interrupt: "Finisher",
  zoom: "Focus zoom", prev_tab: "Stage select", next_tab: "Stage select", prev_workspace: "World warp",
  next_workspace: "World warp", attention: "Rescue", toggle_hud: "Panel", language: "Language", pause: "Pause",
};

// The ctl/*.svg layers draw into viewBox -18 -6 356 222.5: a 320×200 canvas plus a margin.
const STAGE_W = 276, STAGE_H = 172, S = STAGE_W / 356, OX = 18, OY = 6;
const STICKS = { lstick: [122, 124], rstick: [198, 124] };
const HAT = { 0: ["dpad-up"], 1: ["dpad-up", "dpad-right"], 2: ["dpad-right"], 3: ["dpad-right", "dpad-down"],
  4: ["dpad-down"], 5: ["dpad-down", "dpad-left"], 6: ["dpad-left"], 7: ["dpad-left", "dpad-up"] };

export default class Pad extends View {
  init(_props, cx) {
    this.state = null;
    this.alive = false;
    this.dir = `${home()}/.config/herdr-pad`;
    this.bin = `${appHome()}/mods/pad/herdr-pad`;
    this.settings = Boolean(props()?.settings);
    this.launch = "starting";
    if (checking()) return;
    cx.spawn(async (cx) => {
      await this.load();
      if (!this.alive && !this.settings) await this.start(cx);   // once per panel: the bundled helper
      for (;;) {
        await this.load();
        cx.notify();
        try { await watchFolder(this.dir); }
        catch { await this.sleep(cx, 1500); }   // folder missing until the helper first runs
      }
    });
    // The clock while recording, callouts fading out, and a slow liveness check.
    this.ticks = 0;
    cx.timer.every(500, (cx) => {
      this.ticks++;
      const s = this.state;
      if (s && !this.settings && (LIVE.includes(s.phase) || this.callout())) cx.notify();
      if (this.ticks % 10 === 0) cx.spawn(async (cx) => { await this.load(); cx.notify(); });
    });
  }

  // --detach forks the helper into its own session and returns at once.
  async start(cx) {
    this.launch = "starting";
    cx.notify();
    const r = await exec(this.bin, ["--detach"], { timeout: 10000 }).catch((e) => ({ code: 1, stderr: String(e) }));
    if (r.code !== 0) { this.launch = "missing"; cx.notify(); return; }
    for (let i = 0; i < 10 && !this.alive; i++) { await this.sleep(cx, 500); await this.load(); }
    this.launch = this.alive ? "running" : "failed";
    cx.notify();
  }

  send(action) { return exec(this.bin, ["--send", action], { timeout: 5000 }).catch(() => null); }
  sleep(cx, ms) { return new Promise((done) => cx.timer.after(ms, () => done())); }

  async load() {
    const text = await readTextFile(`${this.dir}/state.json`);
    let state = null;
    try { state = text ? JSON.parse(text) : null; } catch { state = this.state; }
    let alive = false;
    if (state?.pid) {
      try { alive = (await exec("/bin/kill", ["-0", String(state.pid)], { timeout: 2000 })).code === 0; } catch { alive = false; }
    }
    this.state = state;
    this.alive = alive;
  }

  // ── small parts ────────────────────────────────────────────────────────

  pixel(text, size, color) { return div().font_family(PIXEL).text_size(size).text_color(color).child(text); }

  key(button, size = 15) {
    if (FACES.includes(button)) return svg(`mods/pad/${button}.svg`).size(size).text_color(C[button]);
    if (button === "dpad") return svg("mods/pad/dpad.svg").size(size).text_color("#c8cbe6");
    return div().px(4).py(2).rounded(4).border(1).border_color("#3a4070").bg("#20244a")
      .font_family(PIXEL).text_size(7).text_color(C.text).child(PILL[button] ?? button.toUpperCase());
  }

  arrow(text) { return div().text_size(12).font_bold().text_color(C.gold).child(text); }

  // The latest move or event, for a second and a half.
  callout() {
    const s = this.state;
    if (!s) return null;
    const items = [];
    if (s.toast?.type === "done") items.push({ at: s.toast.at, text: "STAGE CLEAR!", color: "#2fe08a" });
    if (s.toast?.type === "alert" && /needs you/.test(s.toast.text)) items.push({ at: s.toast.at, text: "WARNING!", color: "#ff9a1f" });
    if (s.lastSent) items.push({ at: s.lastSent.at, text: s.combo > 1 ? `${s.combo} HIT COMBO!` : "SENT! K.O.", color: C.gold });
    if (s.lastPress) {
      const b = s.lastPress.button;
      const action = b.startsWith("dpad") ? null : (s.bindings ?? {})[b];
      const name = b === (s.talk ?? "l1") ? "Voice strike" : b.startsWith("dpad") ? "Sidestep"
        : typeof action === "string" ? MOVES[action] : action?.tap ? MOVES[action.tap] : null;
      if (name) items.push({ at: s.lastPress.at, text: name.toUpperCase() + "!", color: C.text });
    }
    const latest = items.sort((a, b) => b.at - a.at)[0];
    return latest && Date.now() - latest.at < 1500 ? latest : null;
  }

  // ── header: click for settings ─────────────────────────────────────────

  header() {
    const s = this.state ?? {};
    return h_flex().id("header").gap(8).items_center().px(4).py(4).rounded(8)
      .hover((st) => st.bg("#ffffff0d"))
      .on_click(() => openOverlay({ mod: "pad", props: { settings: true }, kind: "popup", width: 260, height: 330 }))
      .child(div().px(5).py(3).rounded(3).bg(C.gold).font_family(PIXEL).text_size(8).text_color(C.ink).child("1P"))
      .child(v_flex().gap(4).flex_1().min_w(0)
        .child(h_flex().gap(4).child(this.pixel("HERDR", 10, C.text)).child(this.pixel("PAD", 10, C.triangle)))
        .child(div().font_family(LCD).text_size(14).text_color(C.muted).truncate()
          .child(`${s.controller ? "●" : "○"} PAD  ${s.mic === "system" ? "MAC MIC" : "HEADSET"}  ${(s.language ?? "en").toUpperCase()}`)))
      .child(v_flex().items_end().gap(4).flex_none()
        .child(this.pixel("SCORE", 6, C.muted))
        .child(this.pixel(String(s.score ?? 0).padStart(6, "0"), 9, C.gold))
        .when((s.combo ?? 0) > 1, (el) => el.child(this.pixel(`x${s.combo} COMBO`, 6, C.rec)
          .loop("opacity", { from: 0.4, to: 1, period: 700 }))))
      .child(svg("mods/pad/gear.svg").size(14).flex_none().text_color(C.muted));
  }

  // ── live controller ────────────────────────────────────────────────────

  stage() {
    const s = this.state;
    const [names, hat, sticks] = s.held ?? [[], 8, [0, 0, 0, 0]];
    const lit = new Set([...names, ...(HAT[hat] ?? [])]);
    const layer = (name, color, opacity = 1) =>
      svg(`mods/pad/ctl/${name}.svg`).absolute().top(0).left(0).w(STAGE_W).h(STAGE_H).text_color(color).opacity(opacity);
    const part = (name, color) => layer(name, lit.has(name) ? color : C.idle);
    const layers = [
      image("mods/pad/backdrop.png").absolute().top(0).left(0).w(STAGE_W).h(STAGE_H).opacity(0.85),
      layer("body-fill", "#0d1030", 0.92),
      layer("body-line", C.line, s.controller ? 0.9 : 0.35),
      part("l2", C.gold), part("r2", C.gold), part("l1", C.gold), part("r1", C.gold),
      part("touchpad", "#b07cff"), part("share", C.text), part("options", C.text), part("ps", C.text),
      ...["dpad-up", "dpad-down", "dpad-left", "dpad-right"].map((d) => part(d, C.text)),
      ...FACES.flatMap((f) => [
        layer(f, lit.has(f) ? C[f] : C.idle),
        layer(`${f}-sym`, lit.has(f) ? C.ink : C[f], lit.has(f) ? 1 : 0.85),
      ]),
      layer("lstick-well", lit.has("l3") ? C.gold : "#3a4070"),
      layer("rstick-well", lit.has("r3") ? C.gold : "#3a4070"),
    ];
    // Stick caps move with the sticks (five steps each way).
    for (const [[x, y], dx, dy, click] of [[STICKS.lstick, sticks[0], sticks[1], "l3"], [STICKS.rstick, sticks[2], sticks[3], "r3"]]) {
      const moved = dx || dy;
      const left = (x + OX) * S - 10 + dx * 3.5, top = (y + OY) * S - 10 + dy * 3.5;
      layers.push(svg("mods/pad/ctl/cap.svg").absolute().left(left).top(top).size(20)
        .text_color(lit.has(click) ? C.gold : moved ? C.triangle : "#2a2f5a"));
      layers.push(svg("mods/pad/ctl/cap-ring.svg").absolute().left(left).top(top).size(20).text_color(moved ? C.ink : "#5f6590"));
    }
    const call = this.callout();
    if (call) layers.push(h_flex().absolute().top(STAGE_H - 34).left(0).w(STAGE_W).justify_center()
      .child(div().px(8).py(4).rounded(4).bg("#07081add").border(1).border_color(call.color)
        .font_family(PIXEL).text_size(10).text_color(call.color).child(call.text)
        .loop("opacity", { from: 0.55, to: 1, period: 400 })));
    if (!s.controller) layers.push(h_flex().absolute().top(8).left(0).w(STAGE_W).justify_center()
      .child(this.pixel("PRESS PS TO CONNECT", 7, "#ff9a1f").loop("opacity", { from: 0.2, to: 1, period: 1400 })));
    return div().relative().w(STAGE_W).h(STAGE_H).rounded(14).overflow_hidden().border(1).border_color("#262b52").bg(C.stage)
      .children(layers);
  }

  // ── voice recorder (compact) ───────────────────────────────────────────

  meter(levels, live) {
    const COLS = 46, ROWS = 6;
    const cols = levels.slice(-COLS);
    while (cols.length < COLS) cols.unshift(0);
    return h_flex().gap(2).children(cols.map((v, i) => {
      const h = live ? Math.max(1, Math.round(v * ROWS)) : 1;
      return v_flex().id(`m${i}`).gap(2).children(Array.from({ length: ROWS }, (_, r) => {
        const on = ROWS - r <= h;
        return div().size(3).rounded(1).bg(on ? (ROWS - r > ROWS * 0.7 ? "#b8f0ff" : C.lcd) : C.lcdDim);
      }));
    }));
  }

  devKey(id, icon, text, action, look) {
    const fill = look === "send" ? "#2f8fa0" : look === "rec" ? "#a3213f" : "#34363f";
    const dim = look === "off";
    return h_flex().id(id).flex_1().h(32).rounded(8).bg(dim ? "#24262c" : fill).border(1)
      .border_color(look === "send" ? "#5fd4ff66" : "#ffffff14").items_center().justify_center().gap(6)
      .when(!dim, (el) => el.hover((st) => st.opacity(0.85)).on_click(() => this.send(action)))
      .child(div().text_size(13).font_bold().text_color(dim ? "#55575f" : "#f2f4ff").child(icon))
      .child(div().font_family(PIXEL).text_size(6).text_color(dim ? "#55575f" : "#dfe3f2").child(text));
  }

  voice() {
    const s = this.state;
    const live = LIVE.includes(s.phase);
    const busy = s.phase === "transcribing";
    const recent = s.lastSent && Date.now() - s.lastSent.at < 4000;
    const pausedFor = s.paused ? Date.now() - s.pausedAt : 0;
    const secs = live && s.started ? Math.max(0, Math.floor((Date.now() - s.started - (s.pausedTotal ?? 0) - pausedFor) / 1000)) : 0;
    const clock = `${String(Math.floor(secs / 60)).padStart(2, "0")}:${String(secs % 60).padStart(2, "0")}`;
    const label = live ? (s.paused ? "Paused" : s.phase === "opening" ? "Opening" : s.phase === "finishing" ? "Wrapping" : "Recording")
      : busy ? "Transcribing" : recent ? (s.lastSent.typed ? "Typed" : "Sent") : "Ready";
    const dot = div().size(6).rounded(3).bg(live ? (s.paused ? C.gold : C.lcd) : busy ? "#b07cff" : recent ? "#2fe08a" : "#2a4652");
    const talk = (s.talk ?? "l1").toUpperCase();
    const screen = v_flex().gap(2).px(10).py(8).rounded(10).bg("#000000").border(1).border_color("#ffffff10")
      .child(h_flex().items_center().gap(6)
        .child(div().flex_1().min_w(0).truncate().font_family(LCD).text_size(14).text_color(C.lcd)
          .child(live && s.target ? s.target : recent ? s.lastSent.target : `Hold ${talk} to talk`))
        .child(h_flex().gap(4).items_center().flex_none()
          .child(live && !s.paused ? dot.loop("opacity", { from: 0.15, to: 1, period: 1000 }) : dot)
          .child(div().font_family(LCD).text_size(14).text_color(C.lcd).child(label))))
      .child(busy
        ? div().font_family(LCD).text_size(32).text_color("#b07cff").frames(["·    ", "··   ", "···  ", " ··· ", "  ···", "   ··", "    ·", "     "], 140)
        : div().font_family(LCD).text_size(32).text_color(recent ? "#2fe08a" : C.lcd).child(live ? clock : recent ? "SENT ✓" : "00:00"))
      .when(Boolean(recent && !live), (el) => el.child(div().font_family(LCD).text_size(14).text_color("#9adfff").truncate().child(`“${s.lastSent.text}”`)))
      .child(this.meter(s.levels ?? [], live && !s.paused));
    let keys;
    if (live) keys = [
      this.devKey("k-cancel", "✕", "CANCEL", "back"),
      s.mic === "system" ? this.devKey("k-pause", s.paused ? "▶" : "❚❚", s.paused ? "RESUME" : "PAUSE", "pause") : null,
      s.handsFree ? this.devKey("k-send", "↵", "SEND", "handsfree", "send") : null,
    ].filter(Boolean);
    else if (busy) keys = [this.devKey("k-wait", "…", "TRANSCRIBING", "", "off")];
    else keys = [this.devKey("k-talk", "●", "TALK", "handsfree", "rec")];
    return v_flex().p(6).gap(6).rounded(14).bg("#1b1d24").border(1).border_color(live ? "#ff2e5f88" : "#2a2d36")
      .child(screen)
      .child(h_flex().gap(6).children(keys))
      .when(s.micPermission === "denied" && s.mic === "system", (el) => el.child(div().px(2).text_size(10.5).text_color("#ff9a1f")
        .child("Mic access is off. Allow Herdr in System Settings → Privacy & Security → Microphone.")));
  }

  draft() {
    const s = this.state;
    return v_flex().gap(5).p(8).rounded(10).border(1).border_color(C.gold).bg("#16140c")
      .child(this.pixel("HELD DRAFT", 7, C.gold).loop("opacity", { from: 0.5, to: 1, period: 900 }))
      .child(div().text_size(12).text_color("#f2f0e6").child(`“${s.draft}”`))
      .child(div().font_family(LCD).text_size(14).text_color("#a8a48a").truncate().child(`→ ${s.draftTarget || "?"}`))
      .child(h_flex().gap(6)
        .child(this.devKey("d-send", "✕", "SEND", "confirm", "send"))
        .child(this.devKey("d-drop", "○", "DISCARD", "back")));
  }

  // ── agents as fighters ─────────────────────────────────────────────────

  fighters() {
    const s = this.state;
    const list = agents().slice(0, 5);
    const [r, g, b, flash] = s.light ?? [0, 0, 48, false];
    const hex = "#" + [r, g, b].map((v) => Math.max(0, Math.min(255, v | 0)).toString(16).padStart(2, "0")).join("");
    const power = div().h(8).flex_1().rounded(2).bg(hex);
    const rows = list.map((a, i) => {
      const color = STATUS[a.status] ?? STATUS.unknown;
      const fill = { working: 0.7, blocked: 0.25, done: 1, idle: 1 }[a.status] ?? 0.5;
      const bar = div().h(5).w(Math.round(248 * fill)).rounded(1).bg(color);
      const name = a.name || a.app || a.terminal || "agent";
      return v_flex().id(`f${i}`).gap(3)
        .child(h_flex().items_center().gap(6)
          .child(div().flex_1().min_w(0).truncate().font_family(LCD).text_size(15).text_color(C.text).child(String(name).toUpperCase()))
          .child(this.pixel(String(a.status ?? "?").toUpperCase(), 6, color)))
        .child(div().w_full().h(9).p(1).rounded(2).bg("#000000").border(1).border_color("#3a4070")
          .child(a.status === "working" ? bar.loop("width", { from: 248 * 0.4, to: 248 * 0.9, period: 1600 })
            : a.status === "blocked" ? bar.loop("opacity", { from: 0.3, to: 1, period: 600 }) : bar));
    });
    return v_flex().gap(8).p(10).rounded(10).bg("#0d1030").border(1).border_color("#262b52")
      .child(h_flex().items_center().gap(8)
        .child(this.pixel("POWER", 7, C.muted))
        .child(flash ? power.loop("opacity", { from: 0.3, to: 1, period: 700 }) : power))
      .child(this.pixel(list.length ? "FIGHTERS" : "NO FIGHTERS YET", 7, C.muted))
      .children(rows);
  }

  // ── move list ──────────────────────────────────────────────────────────

  moves() {
    const s = this.state;
    const b = s.bindings ?? {};
    const talk = s.talk ?? "l1";
    const held = new Set((s.held ?? [[]])[0]);
    const find = (action) => Object.keys(b).find((k) => b[k] === action || b[k]?.tap === action || b[k]?.hold === action);
    const k = (btn) => this.key(btn);
    const list = [
      { name: "Voice strike", hint: "speak", keys: [k(talk), this.arrow("hold"), this.arrow("→ 🎙 →"), this.arrow("release")], buttons: [talk] },
      { name: "Hands-free", hint: "speak", keys: [k(find("handsfree") ?? "r1"), this.arrow("→ 🎙 →"), k(find("handsfree") ?? "r1")], buttons: [find("handsfree")] },
      { name: "Sidestep", hint: "panes", keys: [k("dpad"), this.arrow("↑ → ↓ ←")], buttons: [], dpad: true },
      { name: "Stage select", hint: "tabs", keys: [k(find("prev_tab") ?? "l2"), this.arrow("◀ ▶"), k(find("next_tab") ?? "r2")], buttons: [find("prev_tab"), find("next_tab")] },
      { name: "World warp", hint: "spaces", keys: [k(find("prev_workspace") ?? "share"), this.arrow("◀ ▶"), k(find("next_workspace") ?? "options")], buttons: [find("prev_workspace"), find("next_workspace")] },
      { name: "Confirm", hint: "enter", keys: [k(find("confirm") ?? "cross")], buttons: [find("confirm")] },
      { name: "Back dash", hint: "esc", keys: [k(find("back") ?? "circle")], buttons: [find("back")] },
      { name: "Stance switch", hint: "agent mode", keys: [k(find("mode") ?? "square"), this.arrow("tap")], buttons: [find("mode")] },
      { name: "Finisher", hint: "stop agent", keys: [k(find("interrupt") ?? "square"), this.arrow("hold ●●●")], buttons: [find("interrupt")], super: true },
      { name: "Focus zoom", hint: "pane", keys: [k(find("zoom") ?? "triangle")], buttons: [find("zoom")] },
      { name: "Rescue", hint: "agent in need", keys: [k(find("attention") ?? "touchpad")], buttons: [find("attention")], super: true },
      { name: "Menu walk", hint: "arrows", keys: [this.key("L-STICK"), this.arrow("↑ ↓ ← →")], buttons: [] },
      { name: "Scroll", hint: "history", keys: [this.key("R-STICK"), this.arrow("↑ ↓")], buttons: [] },
    ];
    const hat = (s.held ?? [[], 8])[1];
    const rows = list.map((m, i) => {
      const hot = m.buttons.some((x) => x && held.has(x)) || (m.dpad && hat < 8);
      return v_flex().id(`mv${i}`).gap(5).px(8).py(6).rounded(6)
        .bg(hot ? "#ffd25a26" : i % 2 ? "#0d1030" : "#10133a")
        .border(1).border_color(hot ? C.gold : "#00000000")
        .child(h_flex().items_center().gap(6)
          .child(div().font_bold().text_size(12.5).text_color(m.super ? "#ff6b8a" : C.gold).child(m.name.toUpperCase()))
          .when(Boolean(m.super), (el) => el.child(this.pixel("SUPER", 5, "#ff6b8a")))
          .child(div().flex_1())
          .child(div().font_family(LCD).text_size(14).text_color(C.muted).child(m.hint)))
        .child(h_flex().gap(5).items_center().children(m.keys));
    });
    return v_flex().gap(3)
      .child(h_flex().items_center().gap(8).pb(4)
        .child(this.pixel("MOVE LIST", 8, C.gold))
        .child(div().h(1).flex_1().bg("#ffd25a55")))
      .children(rows);
  }

  // ── settings popup ─────────────────────────────────────────────────────

  option(id, text, on, action) {
    return h_flex().id(id).px(8).py(4).rounded(6).border(1).border_color(on ? C.triangle : "#2a2f55")
      .bg(on ? "#3ee0c422" : "#161936").text_size(11.5).text_color(on ? C.triangle : "#c8cbe6")
      .hover((st) => st.border_color(C.triangle))
      .on_click((_e, cx) => cx.spawn(async (cx) => { await this.send(action); await this.sleep(cx, 250); await this.load(); cx.notify(); }))
      .child(text);
  }

  row(title, options) {
    return v_flex().gap(5).child(this.pixel(title, 6, C.muted)).child(h_flex().gap(5).flex_wrap().children(options));
  }

  settingsView() {
    const s = this.state ?? {};
    const close = () => closeOverlay(props().overlay);
    return v_flex().size_full().p(12).gap(12).bg(C.ink)
      .child(h_flex().items_center()
        .child(this.pixel("SETTINGS", 8, C.gold))
        .child(div().flex_1())
        .child(div().id("x").text_size(13).text_color(C.muted).hover((st) => st.text_color(C.text)).on_click(close).child("✕")))
      .when(!this.alive, (el) => el.child(div().text_size(11.5).text_color("#ff9a1f").child("The helper isn't running, so changes won't apply.")))
      .child(this.row("MICROPHONE", [
        this.option("mic-sys", "Mac mic", s.mic === "system", "mic:system"),
        this.option("mic-pad", "Controller headset", s.mic === "controller", "mic:controller")]))
      .child(this.row("LANGUAGE", [
        this.option("l-en", "English", s.language === "en", "lang:en"),
        this.option("l-vi", "Tiếng Việt", s.language === "vi", "lang:vi"),
        this.option("l-auto", "Auto", s.language === "auto", "lang:auto")]))
      .child(this.row("FLOATING OVERLAY", [
        this.option("h-full", "Full", s.hud === "full", "hud:full"),
        this.option("h-compact", "Compact", s.hud === "compact", "hud:compact"),
        this.option("h-off", "Off", s.hud === "hidden", "hud:hidden")]))
      .child(this.row("FEEDBACK", [
        this.option("snd", "Sounds", Boolean(s.sounds), "sounds"),
        this.option("rmb", "Rumble", Boolean(s.haptics), "haptics")]))
      .child(this.row("BUTTONS", [
        this.option("cfg", "Edit button map…", false, "config"),
        this.option("rld", "Reload", false, "reload")]));
  }

  // ── screens ────────────────────────────────────────────────────────────

  offline() {
    return v_flex().size_full().p(12).gap(12).bg(C.ink)
      .child(h_flex().gap(4).child(this.pixel("HERDR", 10, C.text)).child(this.pixel("PAD", 10, C.triangle)))
      .child(div().relative().w(STAGE_W).h(130).rounded(14).overflow_hidden()
        .child(image("mods/pad/art.png").absolute().top(0).left(0).w(STAGE_W).h(130)))
      .child(h_flex().justify_center().child(this.pixel(this.launch === "starting" ? "LOADING..." : "INSERT COIN", 10, C.gold)
        .loop("opacity", { from: 0.15, to: 1, period: 1200 })))
      .child(div().text_size(11.5).text_color(C.muted).child(this.launch === "missing"
        ? "The herdr-pad helper is missing from mods/pad. Reinstall the layout (make install-layout)."
        : "The herdr-pad helper reads the DualShock and the mic, and drives Herdr's panes, tabs, spaces and voice prompts."))
      .child(div().id("start").px(10).py(8).rounded(8).bg(C.gold).hover((st) => st.opacity(0.85))
        .on_click((_e, cx) => cx.spawn(async (cx) => this.start(cx)))
        .child(this.pixel("▶ PRESS START", 9, C.ink)));
  }

  render() {
    if (this.settings) return this.settingsView();
    if (!this.state || !this.alive) return this.offline();
    return v_flex().id("pad").size_full().bg(C.ink).overflow_y_scrollbar().p(12).gap(12)
      .child(this.header())
      .child(this.stage())
      .child(this.voice())
      .when(Boolean(this.state.draft), (el) => el.child(this.draft()))
      .child(this.fighters())
      .child(this.moves())
      .child(div().id("hide").pt(2).font_family(LCD).text_size(14).text_color("#5f6590").hover((st) => st.text_color(C.triangle))
        .on_click(() => run("layout.toggle", { id: "padbar" })).child("Hide panel · L3 brings it back"));
  }
}
