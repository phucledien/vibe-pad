// The diagram uses DS4 report order so the drawing and textual readout agree.
const padNames = [
  "square",
  "cross",
  "circle",
  "triangle",
  "l1",
  "r1",
  "l2",
  "r2",
  "share",
  "options",
  "l3",
  "r3",
  "ps",
  "touchpad",
];
const buttonLabels = [
  "Square",
  "Cross",
  "Circle",
  "Triangle",
  "L1",
  "R1",
  "L2",
  "R2",
  "Share",
  "Options",
  "L3",
  "R3",
  "PS",
  "Touchpad",
];
const padState = { buttons: 0, hat: 8, axes: [128, 128, 128, 128] };
const pressed = (name) =>
  !!(padState.buttons & (1 << (padNames.indexOf(name) + 4)));
const directions = [
  ["Up"],
  ["Up", "Right"],
  ["Right"],
  ["Right", "Down"],
  ["Down"],
  ["Down", "Left"],
  ["Left"],
  ["Left", "Up"],
];
function renderPad() {
  const canvas = document.querySelector("#pad"),
    box = canvas.getBoundingClientRect(),
    dpr = devicePixelRatio;
  const w = Math.round(box.width * dpr),
    h = Math.round(box.height * dpr);
  if (!w || !h) return;
  if (canvas.width !== w || canvas.height !== h) {
    canvas.width = w;
    canvas.height = h;
  }
  const c = canvas.getContext("2d");
  c.resetTransform();
  c.clearRect(0, 0, w, h);
  const scale = Math.min(w / 580, h / 300);
  c.translate((w - 580 * scale) / 2, (h - 300 * scale) / 2);
  c.scale(scale, scale);
  const mint = "#a6f4d1",
    edge = "#646a76";
  function fill(path, color, stroke, width = 1) {
    c.fillStyle = color;
    c.fill(path);
    if (stroke) {
      c.strokeStyle = stroke;
      c.lineWidth = width;
      c.stroke(path);
    }
  }
  function rect(x, y, w, h, r, color, stroke) {
    let p = new Path2D();
    p.roundRect(x, y, w, h, r);
    fill(p, color, stroke);
  }
  function disc(x, y, r, color, stroke) {
    let p = new Path2D();
    p.arc(x, y, r, 0, Math.PI * 2);
    fill(p, color, stroke);
  }
  function grad(y1, y2, a, b) {
    let g = c.createLinearGradient(0, y1, 0, y2);
    g.addColorStop(0, a);
    g.addColorStop(1, b);
    return g;
  }
  function label(s, x, y, size, color, weight = 600) {
    c.font = weight + " " + size + "px -apple-system, sans-serif";
    c.fillStyle = color;
    c.textAlign = "center";
    c.textBaseline = "middle";
    c.fillText(s, x, y);
  }
  for (const [x, side] of [
    [119, "l"],
    [405, "r"],
  ]) {
    for (const [n, y] of [
      [2, 12],
      [1, 32],
    ]) {
      const on = pressed(side + n);
      rect(x, y, 56, 28, 8, on ? mint : "#2c3039", on ? mint : edge);
      label(
        side.toUpperCase() + n,
        x + 28,
        y + 9,
        9,
        on ? "#163a2a" : "#dfe1ea",
      );
    }
  }
  const body = new Path2D(
    "M147 49 C119 46 98 56 86 83 C72 120 54 178 44 235 C34 287 55 302 85 280 C105 265 119 237 136 209 C148 194 161 195 178 204 C192 219 216 226 235 212 L248 199 Q290 194 332 199 L345 212 C364 226 388 219 402 204 C419 195 432 194 444 209 C461 237 475 265 495 280 C525 302 546 287 536 235 C526 178 508 120 494 83 C482 56 461 46 433 49 Q290 35 147 49 Z",
  );
  c.save();
  c.shadowColor = "#101116bb";
  c.shadowBlur = 12 * scale;
  c.shadowOffsetY = 5 * scale;
  fill(body, grad(45, 282, "#686d78", "#343842"), "#89909c", 1.7);
  c.restore();
  for (const [x, y] of [
    [139, 112],
    [441, 112],
  ])
    disc(x, y, 55, grad(56, 166, "#555b67", "#4a4e59"), "#686f7c");
  const touch = new Path2D(
    "M205 49 Q290 43 375 49 Q382 50 379 61 L365 113 Q364 119 355 119 L225 119 Q216 119 215 113 L201 61 Q198 50 205 49 Z",
  );
  fill(
    touch,
    pressed("touchpad") ? "#588e7a" : grad(48, 118, "#353945", "#282d37"),
    pressed("touchpad") ? mint : "#20242d",
    2,
  );
  c.save();
  c.clip(touch);
  c.fillStyle = "#ffffff18";
  for (let y = 52; y < 119; y += 4)
    for (let x = 201 + (y % 8 ? 1 : 0); x < 380; x += 4) c.fillRect(x, y, 1, 1);
  c.restore();
  rect(245, 48, 90, 2.3, 1, "#b4a5ff");
  for (const [x, key] of [
    [188, "share"],
    [392, "options"],
  ]) {
    rect(x - 4, 63, 8, 18, 4, pressed(key) ? mint : "#282d35", "#9295a1");
    label(key.toUpperCase(), x, 88, 6.8, "#eaebef");
  }
  const activeDirs = directions[padState.hat] || [];
  ["Up", "Right", "Down", "Left"].forEach((d, i) => {
    c.save();
    c.translate(139, 112);
    c.rotate((i * Math.PI) / 2);
    fill(
      new Path2D("M-10 -34 Q0 -37 10 -34 L10 -15 L0 -6 L-10 -15 Z"),
      activeDirs.includes(d) ? mint : "#252932",
      "#777c88",
      1.6,
    );
    c.restore();
  });
  for (const [x, y, n, glyph, col] of [
    [441, 83, "triangle", "△", "#80d4be"],
    [470, 112, "circle", "○", "#f2a7a0"],
    [441, 141, "cross", "×", "#a8c5f4"],
    [412, 112, "square", "□", "#e2a1cc"],
  ]) {
    disc(
      x,
      y,
      14.2,
      pressed(n) ? mint : grad(y - 14, y + 15, "#3a404b", "#262a32"),
      pressed(n) ? "#dcffef" : "#878d99",
    );
    label(glyph, x, y - 0.4, 23, pressed(n) ? "#143e31" : col, 500);
  }
  for (const [x, idx, key] of [
    [216, 0, "l3"],
    [364, 2, "r3"],
  ]) {
    disc(x, 174, 36, grad(136, 211, "#3a404c", "#656977"), "#383d46");
    disc(x, 174, 30, "#252932", "#757c89");
    const dx = ((padState.axes[idx] - 128) / 128) * 9,
      dy = ((padState.axes[idx + 1] - 128) / 128) * 9;
    disc(
      x + dx,
      174 + dy,
      23,
      pressed(key) ? mint : grad(150, 200, "#515864", "#363b46"),
      pressed(key) ? mint : "#747b87",
    );
    disc(
      x + dx,
      174 + dy,
      18,
      pressed(key) ? "#85d0b1" : "#3e444e",
      pressed(key) ? "#80c3aa" : "#535a65",
    );
  }
  for (let row = 0; row < 3; row++)
    for (let col = 0; col < 7; col++)
      disc(278 + col * 4 + (row % 2) * 2, 132 + row * 4, 1.15, "#20232b");
  disc(290, 168, 11, pressed("ps") ? mint : "#30343d", "#7c818d");
  label("PS", 290, 168, 8, pressed("ps") ? "#18392e" : "#d3d6df", 700);
}
new ResizeObserver(renderPad).observe(document.querySelector("#pad"));
