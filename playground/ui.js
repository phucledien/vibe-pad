"use strict";
const $ = (s) => document.querySelector(s);
const post = (action, values = {}) =>
  window.webkit.messageHandlers.playground.postMessage({ action, ...values });
const bindingDefaults = { talk: "l1", submit: "cross", clear: "circle" };
const bindings = { ...bindingDefaults };
let online = false,
  phase = "idle",
  sending = false,
  previous = 0,
  renderQueued = false,
  generation = 0;
function notice(text, error = false) {
  $("#notice").textContent = text;
  $("#notice").classList.toggle("error", error);
}
function update() {
  const draft = $("#draft").value.trim(),
    remote = $("#target").value !== "";
  $("#submit").textContent = remote ? "Send to agent" : "Preview prompt";
  $("#submit").disabled = !draft || sending || phase !== "idle";
  $("#clear").disabled =
    (!draft && phase !== "transcribing") ||
    sending ||
    phase === "opening" ||
    phase === "recording" || phase === "stalled" || phase === "finishing";
  $("#target").disabled = sending;
  $("#refresh").disabled = sending;
  $("#draft").placeholder =
    "Hold " + label(bindings.talk) + " to dictate, or type a prompt…";
  for (const el of document.querySelectorAll("#guide select"))
    el.disabled = phase !== "idle" || sending;
}
function label(name) {
  return buttonLabels[padNames.indexOf(name)];
}
function setPhase(value, detail) {
  phase = value;
  $("#mic").textContent = detail;
  $("#mic").classList.toggle(
    "active",
    value === "opening" || value === "recording",
  );
  update();
}
function clearDraft() {
  if ($("#clear").disabled) return;
  generation++;
  $("#draft").value = "";
  notice("Draft cleared.");
  update();
}
function remember(text, heading) {
  $("#last-heading").textContent = heading;
  $("#last").textContent = text;
}
function submit() {
  if ($("#submit").disabled) return;
  const draft = $("#draft").value.trim(),
    target = $("#target").value;
  if (!target) {
    remember(draft, "Last local preview");
    notice("Previewed locally.");
    return;
  }
  sending = true;
  update();
  notice("Sending to Herdr…");
  post("send", { target, text: draft });
}
function configure() {
  for (const action of Object.keys(bindings))
    $("#bind-" + action).value = bindings[action];
  post("bindings", { bindings });
  update();
}
for (const [id, title, detail] of [
  ["talk", "Push to talk", "Hold and speak"],
  ["submit", "Submit prompt", "Press to preview or send"],
  ["clear", "Clear draft", "Press to discard text"],
]) {
  const row = document.createElement("label");
  row.className = "guide-row";
  const text = document.createElement("span"),
    strong = document.createElement("strong"),
    small = document.createElement("small");
  strong.textContent = title;
  small.textContent = detail;
  text.append(strong, small);
  const select = document.createElement("select");
  select.id = "bind-" + id;
  select.ariaLabel = "Controller button for " + title;
  padNames.forEach((n, i) => select.add(new Option(buttonLabels[i], n)));
  select.value = bindings[id];
  select.onchange = () => {
    const other = Object.keys(bindings).find(
      (k) => bindings[k] === select.value,
    );
    if (other) bindings[other] = bindings[id];
    bindings[id] = select.value;
    configure();
  };
  row.append(text, select);
  $("#guide").append(row);
}
function input(state) {
  const rising = state.buttons & ~previous;
  previous = state.buttons;
  Object.assign(padState, state);
  const names = padNames
    .filter(pressed)
    .map(label)
    .concat(directions[state.hat] || []);
  $("#buttons").textContent = names.length
    ? names.join(" + ")
    : online
      ? "No buttons pressed"
      : "Waiting for controller";
  if (!renderQueued) {
    renderQueued = true;
    requestAnimationFrame(() => {
      renderQueued = false;
      renderPad();
    });
  }
  if (
    phase === "idle" &&
    rising & (1 << (padNames.indexOf(bindings.clear) + 4))
  )
    clearDraft();
  else if (
    phase === "idle" &&
    rising & (1 << (padNames.indexOf(bindings.submit) + 4))
  )
    submit();
}
let takeURLs = {}, partialTake = false;
function wavURL(base64) {
  const binary = atob(base64);
  const bytes = Uint8Array.from(binary, char => char.charCodeAt(0));
  return URL.createObjectURL(new Blob([bytes], { type: "audio/wav" }));
}
function selectTakeSource() {
  const player = $("#take-audio");
  player.pause();
  const source = takeURLs[$("#take-source").value];
  if (source) player.src = source;
  else player.removeAttribute("src");
  player.load();
}
function showTake(take) {
  partialTake = take.seconds > 0 && take.held - take.startup - take.seconds > 0.4;
  const previousURLs = new Set(Object.values(takeURLs));
  takeURLs = {};
  if (take.original) {
    takeURLs.original = wavURL(take.original);
    takeURLs.adjusted = take.adjusted ? wavURL(take.adjusted) : takeURLs.original;
  }
  $("#take-source").value = "adjusted";
  $("#take-source").disabled = !take.adjusted;
  selectTakeSource();
  for (const url of previousURLs) URL.revokeObjectURL(url);
  const stats = [take.seconds.toFixed(2) + " s captured / " + take.held.toFixed(2) + " s held"];
  if (take.original) {
    stats.push("first audio at " + take.startup.toFixed(2) + " s",
               "original level " + Math.round(take.level) + " dBFS",
               "boost +" + Math.round(take.gain) + " dB");
    stats.push(take.tail.toFixed(2) + " s audio received after release");
    if (take.held - take.startup - take.beforeRelease > 0.4)
      stats.push("audio shortfall at release");
  }
  if (take.gaps) stats.push(take.gaps + " missing frames");
  if (take.rearms) stats.push(take.rearms + " mic retries");
  if (partialTake) stats.unshift("Partial recording");
  if (!take.original) stats.unshift("No audio captured", take.micPackets + " mic packets");
  $("#take-stats").textContent = stats.join(" · ");
}
$("#take-source").onchange = selectTakeSource;
$("#take-audio").onplay = () => {
  if (["opening", "recording", "stalled", "finishing"].includes(phase)) $("#take-audio").pause();
};
let takeGeneration = 0;
function playgroundEvent(event) {
  switch (event.kind) {
    case "connection":
      online = event.connected;
      document.body.classList.toggle("connected", online);
      $("#connection").textContent = event.text;
      if (!online) input({ buttons: 0, hat: 8, axes: [128, 128, 128, 128] });
      else $("#buttons").textContent = "No buttons pressed";
      break;
    case "input":
      input(event);
      break;
    case "take":
      showTake(event);
      break;
    case "phase":
      if (event.phase === "opening") {
        $("#take-audio").pause();
        takeGeneration = generation;
        notice("Wait for the headset audio before speaking.");
      }
      if (event.phase === "recording")
        notice(
          "Speak now. Release " + label(bindings.talk) + " to transcribe.",
        );
      if (event.phase === "finishing") notice("Collecting the last headset audio…");
      if (event.phase === "stalled")
        notice("Mic audio stopped arriving. Keep holding to reconnect, or release to review the partial take.", true);
      setPhase(event.phase, event.text);
      break;
    case "transcript":
      if (generation === takeGeneration && event.text) {
        const field = $("#draft");
        field.value +=
          (field.value && !/\s$/.test(field.value) ? " " : "") + event.text;
        if (partialTake) notice("Only part of this take arrived. Review the playback and draft before sending.", true);
        else notice(
          "Transcript added. Edit the text or press " +
            label(bindings.submit) +
            ".",
        );
      } else if (generation === takeGeneration)
        notice("No speech recognized. Try another take.", true);
      setPhase("idle", "Headset idle");
      break;
    case "error":
      notice(event.text, true);
      break;
    case "settings":
      if (
        event.bindings &&
        Object.keys(bindings).every((k) =>
          padNames.includes(event.bindings[k]),
        ) &&
        new Set(Object.values(event.bindings)).size === 3
      )
        Object.assign(bindings, event.bindings);
      $("#language").value = event.language || "en";
      configure();
      break;
    case "targets": {
      const select = $("#target"),
        chosen = select.value;
      select.replaceChildren(new Option("Local preview", ""));
      event.agents.forEach((a) => select.add(new Option(a.name, a.id)));
      if ([...select.options].some((o) => o.value === chosen))
        select.value = chosen;
      if (event.message) notice(event.message);
      update();
      break;
    }
    case "sent":
      sending = false;
      if (event.ok) {
        remember(event.text, "Last sent prompt");
        notice("Sent to " + event.target + ".");
      } else notice(event.text, true);
      update();
      break;
  }
}
window.playgroundEvent = playgroundEvent;
$("#draft").oninput = update;
$("#clear").onclick = clearDraft;
$("#submit").onclick = submit;
$("#target").onchange = update;
$("#refresh").onclick = () => post("targets");
$("#language").onchange = () =>
  post("language", { value: $("#language").value });
update();
post("ready");
