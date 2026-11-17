// Draws Partner Panel's ping icons: floating white-and-gold halftone dots on a clear
// background, each as a little looping animation of FRAMES frames side by side
// (a "flipbook", media/ping-*.tga, FRAMES*128 x 128) that WoW can read and play.
// No packages needed. Run from the project root:
//   node scripts/make-icons.js [preview.html]
// The optional preview is a web page that plays the animations on dark and grassy
// backdrops, at full size and at in-game size.
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const SIZE = 128;                 // one frame
const FRAMES = 8;
const CELLS = 26;                 // dots across: many small ones
const SCALE = 0.76;               // shapes use this much of the frame, leaving room to glow
const WHITE = [255, 255, 255];
const GOLD = [255, 205, 96];
const GLOW = [255, 190, 70];

// ---- Shape pieces, in u,v from -1 to 1 with v pointing up --------------------------------
const circle = (u, v, cx, cy, r) => (u - cx) ** 2 + (v - cy) ** 2 <= r * r;
const ellipse = (u, v, cx, cy, rx, ry, a = 0) => {
  const c = Math.cos(a), s = Math.sin(a);
  const x = (u - cx) * c + (v - cy) * s, y = -(u - cx) * s + (v - cy) * c;
  return (x / rx) ** 2 + (y / ry) ** 2 <= 1;
};
const capsule = (u, v, x1, y1, x2, y2, r) => {
  const dx = x2 - x1, dy = y2 - y1;
  const t = Math.max(0, Math.min(1, ((u - x1) * dx + (v - y1) * dy) / (dx * dx + dy * dy)));
  return (u - x1 - t * dx) ** 2 + (v - y1 - t * dy) ** 2 <= r * r;
};
const star = (u, v, cx, cy, R, p) => Math.abs(u - cx) ** p + Math.abs(v - cy) ** p <= R ** p;
const roundBox = (u, v, cx, cy, a, b) => ((u - cx) / a) ** 4 + ((v - cy) / b) ** 4 <= 1;
const wave = (x) => 0.5 - 0.5 * Math.cos(x * 2 * Math.PI); // 0..1..0 over one loop

// A footprint seen from above: sole, heel and a row of toes, big toe on the `inner` side.
// Toes sit apart from the sole, with a gap a dot wide, so they survive as dots.
function foot(u, v, cx, cy, inner) {
  const k = 1.3; // overall size
  const at = (x, y) => [cx + x * k * inner, cy + y * k];
  const [bx, by] = at(0.02, 0.1), [hx, hy] = at(-0.03, -0.34);
  if (ellipse(u, v, bx, by, 0.18 * k, 0.16 * k)) return true;          // ball of the foot
  if (ellipse(u, v, hx, hy, 0.12 * k, 0.14 * k)) return true;          // heel
  const [ax, ay] = at(-0.05, 0.02), [ex, ey] = at(-0.04, -0.3);
  if (capsule(u, v, ax, ay, ex, ey, 0.095 * k)) return true;            // arch
  const toes = [[0.13, 0.42, 0.075], [-0.03, 0.45, 0.058], [-0.15, 0.39, 0.05]];
  return toes.some(([tx, ty, r]) => { const [x, y] = at(tx, ty); return circle(u, v, x, y, r * k); });
}

// A slim, pointed heart: the classic heart curve, narrowed. A polygon of points.
const HEART = Array.from({ length: 240 }, (_, i) => {
  const a = (i / 240) * 2 * Math.PI;
  const x = 16 * Math.sin(a) ** 3;
  const y = 13 * Math.cos(a) - 5 * Math.cos(2 * a) - 2 * Math.cos(3 * a) - Math.cos(4 * a);
  return [(x / 17) * 0.78 * 0.88, (y / 17) * 0.88 + 0.12];
});
function inPolygon(u, v, pts) {
  let inside = false;
  for (let i = 0, j = pts.length - 1; i < pts.length; j = i++) {
    const [xi, yi] = pts[i], [xj, yj] = pts[j];
    if ((yi > v) !== (yj > v) && u < ((xj - xi) * (v - yi)) / (yj - yi) + xi) inside = !inside;
  }
  return inside;
}

// The path for "Come here": stepping stones winding up to an X, a clear gap between each
// (about two dots wide), so it reads as a trail rather than a line.
const STONES = [[-0.74, -0.8], [-0.42, -0.64], [-0.27, -0.32], [-0.05, -0.06], [0.2, 0.15]];

// Each icon: shape(u, v, t) says what is inside; bright(u, v, t) how lit a dot is.
// `t` runs 0 to 1 over the loop.
const ICONS = {
  // Stand here: two feet side by side, glowing left, right, as if shifting weight
  stand: {
    shape: (u, v) => foot(u, v, -0.4, -0.02, 1) || foot(u, v, 0.4, -0.02, -1),
    bright: (u, v, t) => 0.55 + 0.45 * (u < 0 ? wave(t) : wave(t + 0.5)),
  },
  // Come here: a path of stones to an X; a light walks along it to the X
  come: {
    shape: (u, v) =>
      STONES.some(([x, y]) => ellipse(u, v, x, y, 0.1, 0.08, 0.5)) ||
      capsule(u, v, 0.42, 0.42, 0.82, 0.82, 0.075) || capsule(u, v, 0.42, 0.82, 0.82, 0.42, 0.075),
    bright: (u, v, t) => {
      const s = Math.max(0, Math.min(1, (u + v + 1.5) / 3.1)); // 0 at the start, 1 at the X
      const lit = Math.exp(-(((s - t * 1.15) / 0.13) ** 2));
      return u > 0.35 && v > 0.35 ? 0.6 + 0.4 * Math.max(lit, wave(t) * 0.5) : 0.45 + 0.55 * lit;
    },
  },
  // Not a ping: the heart that can float over your partner's head. Slim and pointed, with
  // a white shine on one side, a tiny twinkle beside it, and a soft heartbeat (two quick
  // beats and a rest).
  heart: {
    shape: (u, v) => inPolygon(u, v, HEART) || star(u, v, 0.8, 0.8, 0.2, 0.5),
    bright: (u, v, t) => {
      if (u > 0.6 && v > 0.6) return 0.2 + 0.8 * wave(t + 0.6); // the twinkle
      const beat = Math.max(Math.exp(-(((t - 0.1) / 0.07) ** 2)), 0.8 * Math.exp(-(((t - 0.32) / 0.07) ** 2)));
      return 0.62 + 0.38 * beat;
    },
    shine: (u, v) => Math.max(0, 1 - Math.hypot((u + 0.3) / 0.2, (v - 0.3) / 0.15)),
  },
  // Follow me: a sparkle and a small one beside it, twinkling
  follow: {
    shape: (u, v) => star(u, v, -0.1, -0.1, 0.82, 0.5) || star(u, v, 0.6, 0.62, 0.3, 0.5),
    bright: (u, v, t) => {
      const twinkle = wave(t + ((Math.sin(u * 91.7 + v * 37.3) + 1) * 0.5));
      return u > 0.3 && v > 0.3 ? 0.25 + 0.75 * wave(t + 0.25) : 0.6 + 0.4 * twinkle;
    },
  },
  // Watch out: an exclamation mark, blinking
  watch: {
    shape: (u, v) => capsule(u, v, 0, -0.08, 0, 0.78, 0.2) || circle(u, v, 0, -0.72, 0.21),
    bright: (u, v, t) => 0.5 + 0.5 * wave(t + 0.5),
  },
  // Grab this: a hand, index finger pointing down at the thing, tapping
  grab: {
    shape: (u, v, t) => {
      v += 0.09 * wave(t); // the whole hand dips down and back up
      return roundBox(u, v, 0.12, 0.38, 0.3, 0.2) ||                 // palm
        capsule(u, v, -0.08, 0.3, -0.08, -0.84, 0.12) ||              // index finger, pointing down
        capsule(u, v, 0.14, 0.12, 0.36, 0.12, 0.1) ||                 // curled fingers, knuckles
        capsule(u, v, 0.16, -0.12, 0.32, -0.12, 0.09) ||
        capsule(u, v, -0.22, 0.46, -0.56, 0.3, 0.1) ||                // thumb, sticking out
        roundBox(u, v, 0.12, 0.8, 0.27, 0.07);                        // cuff, a gap above the palm
    },
    bright: () => 1,
  },
};

// ---- Halftone rendering -----------------------------------------------------------------
function renderFrame(icon, f) {
  const t = f / FRAMES;
  const cell = SIZE / CELLS;
  const inside = (x, y) => icon.shape(((x / SIZE) * 2 - 1) / SCALE, (1 - (y / SIZE) * 2) / SCALE, t);
  const dots = [];
  for (let row = -1; row <= CELLS + 2; row++) {
    for (let col = -1; col <= CELLS + 1; col++) {
      const cx = (col + 0.5 + (row % 2 ? 0.5 : 0)) * cell;
      const cy = (row + 0.5) * cell * 0.88;
      let hits = 0, total = 0;
      for (let i = -2; i <= 2; i++) for (let j = -2; j <= 2; j++) {
        total++;
        if (inside(cx + i * cell * 0.25, cy + j * cell * 0.25)) hits++;
      }
      const cover = hits / total;
      if (cover === 0) continue;
      const du = ((cx / SIZE) * 2 - 1) / SCALE, dv = (1 - (cy / SIZE) * 2) / SCALE;
      const b = icon.bright(du, dv, t);
      const w = icon.shine ? Math.min(1, icon.shine(du, dv, t) * 2) : 0; // pure white here
      const r = cell * 0.31 * Math.sqrt(cover) * (0.7 + 0.3 * b);
      if (r > 0.45) dots.push([cx, cy, r, cover, b, w]);
    }
  }
  const px = new Float32Array(SIZE * SIZE * 4);
  for (let y = 0; y < SIZE; y++) {
    for (let x = 0; x < SIZE; x++) {
      let core = 0, glow = 0, t2 = 1, depth = 0, white = 0;
      for (const [cx, cy, r, cover, b, w] of dots) {
        const d = Math.hypot(x + 0.5 - cx, y + 0.5 - cy);
        if (d > r * 3.4) continue;
        const a = Math.max(0, Math.min(1, r + 0.55 - d)) * (0.35 + 0.65 * b);
        if (a > core) { core = a; t2 = Math.min(1, d / r); depth = cover; white = w; }
        glow += 0.26 * b * Math.exp(-((d / (r * 2.2)) ** 2));
      }
      glow = Math.min(0.55, glow);
      const k = Math.min(1, Math.pow(t2, 1.4) * 0.6 + (1 - depth) * 0.8) * (1 - white);
      const dot = WHITE.map((w, i) => w + (GOLD[i] - w) * k);
      const a = core + glow * (1 - core);
      const i = (y * SIZE + x) * 4;
      for (let c = 0; c < 3; c++) {
        px[i + c] = a > 0 ? (dot[c] * core + GLOW[c] * glow * (1 - core)) / a : 0;
      }
      px[i + 3] = a;
    }
  }
  return px;
}

// All frames side by side: a FRAMES*SIZE x SIZE strip.
function renderStrip(icon) {
  const W = SIZE * FRAMES;
  const strip = new Float32Array(W * SIZE * 4);
  for (let f = 0; f < FRAMES; f++) {
    const px = renderFrame(icon, f);
    for (let y = 0; y < SIZE; y++) {
      strip.set(px.subarray(y * SIZE * 4, (y + 1) * SIZE * 4), (y * W + f * SIZE) * 4);
    }
  }
  return { w: W, h: SIZE, px: strip };
}

// ---- Writers ----------------------------------------------------------------------------
function tga({ w, h, px }) {
  const head = Buffer.alloc(18);
  head[2] = 2;                       // uncompressed true-colour
  head.writeUInt16LE(w, 12);
  head.writeUInt16LE(h, 14);
  head[16] = 32;                     // bits per pixel
  head[17] = 0x08;                   // 8 alpha bits, bottom-left origin (the usual kind)
  const body = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4, o = ((h - 1 - y) * w + x) * 4; // bottom row first
    body[o] = Math.round(px[i + 2]);
    body[o + 1] = Math.round(px[i + 1]);
    body[o + 2] = Math.round(px[i]);
    body[o + 3] = Math.round(px[i + 3] * 255);
  }
  return Buffer.concat([head, body]);
}

const CRC = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return (buf) => { let c = 0xffffffff; for (const b of buf) c = t[(c ^ b) & 255] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
})();
function png({ w, h, px }) {
  const rgba = Buffer.alloc(w * h * 4);
  for (let i = 0; i < w * h; i++) {
    rgba[i * 4] = Math.round(px[i * 4]); rgba[i * 4 + 1] = Math.round(px[i * 4 + 1]);
    rgba[i * 4 + 2] = Math.round(px[i * 4 + 2]); rgba[i * 4 + 3] = Math.round(px[i * 4 + 3] * 255);
  }
  const chunk = (type, data) => {
    const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
    const td = Buffer.concat([Buffer.from(type), data]);
    const crc = Buffer.alloc(4); crc.writeUInt32BE(CRC(td));
    return Buffer.concat([len, td, crc]);
  };
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const raw = Buffer.alloc((w * 4 + 1) * h);
  for (let y = 0; y < h; y++) rgba.copy(raw, y * (w * 4 + 1) + 1, y * w * 4, (y + 1) * w * 4);
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

function previewPage(strips) {
  const names = { stand: "Stand here", come: "Come here", heart: "Your partner (optional)", follow: "Follow me", watch: "Watch out", grab: "Grab this" };
  const data = Object.fromEntries(Object.entries(strips).map(([k, s]) => [k, png(s).toString("base64")]));
  const cells = (size) => Object.keys(strips).map((k) =>
    `<figure><div class="icon" style="width:${size}px;height:${size}px;background-image:url(data:image/png;base64,${data[k]});background-size:${size * FRAMES}px ${size}px;--end:-${size * FRAMES}px"></div><figcaption>${names[k]}</figcaption></figure>`
  ).join("");
  return `<!doctype html><html><head><meta charset="utf-8"><title>Ping icons</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
body{margin:0;font:14px/1.4 system-ui,sans-serif;color:#eee;background:#161210}
h2{font-weight:600;font-size:15px;margin:0 0 10px}
section{padding:18px 16px}
.dark{background:#161210}.grass{background:#5c4e30}
.row{display:flex;flex-wrap:wrap;gap:18px}
figure{margin:0;text-align:center}
figcaption{margin-top:6px;font-size:12px;opacity:.85}
.icon{animation:play 1.2s steps(${FRAMES}) infinite}
@keyframes play{to{background-position:var(--end) 0}}
</style></head><body>
<section class="dark"><h2>Full size, on dark</h2><div class="row">${cells(128)}</div></section>
<section class="grass"><h2>Full size, on grass</h2><div class="row">${cells(128)}</div></section>
<section class="dark"><h2>Roughly in-game size (64px marker), on dark</h2><div class="row">${cells(64)}</div></section>
<section class="grass"><h2>Roughly in-game size, on grass</h2><div class="row">${cells(64)}</div></section>
</body></html>`;
}

// Also a still sheet of every frame, for looking at closely.
function framesSheet(strips) {
  const list = Object.values(strips);
  const W = SIZE * FRAMES, H = SIZE * list.length;
  const px = new Float32Array(W * H * 4);
  list.forEach((s, n) => px.set(s.px, n * W * SIZE * 4));
  for (let i = 0; i < W * H; i++) { // on dark, so the glow shows
    const a = px[i * 4 + 3];
    px[i * 4] = px[i * 4] * a + 22 * (1 - a); px[i * 4 + 1] = px[i * 4 + 1] * a + 18 * (1 - a);
    px[i * 4 + 2] = px[i * 4 + 2] * a + 16 * (1 - a); px[i * 4 + 3] = 1;
  }
  return png({ w: W, h: H, px });
}

const root = path.join(__dirname, "..");
fs.mkdirSync(path.join(root, "media"), { recursive: true });
const strips = {};
for (const [name, icon] of Object.entries(ICONS)) {
  strips[name] = renderStrip(icon);
  fs.writeFileSync(path.join(root, "media", `ping-${name}.tga`), tga(strips[name]));
}
const out = process.argv[2];
if (out) {
  fs.writeFileSync(out, previewPage(strips));
  fs.writeFileSync(out.replace(/\.html?$/, "") + "-frames.png", framesSheet(strips));
}
console.log(`wrote ${Object.keys(ICONS).length} flipbooks (${FRAMES} frames of ${SIZE}px)`, out ? `and ${out}` : "");
