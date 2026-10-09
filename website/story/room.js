// Her room, on the other side of the phone. Painted with the ink brush into stacked canvases:
// back (wall, window, shelf, floor, chair) → her shadow → front (desk and what sits on it, plant).
// Each layer is painted twice with the same seed: lit, and sunk in darkness with only outlines.
import { Painter, spline, circle, layer, TAU } from './paint.js';

export const W = 1600, H = 900;
// Layout: the view is her phone lying on the desk, looking across the bedroom.
export const WIN = { x0: 662, x1: 959, top: 13, base: 467, cx: 810, r: 148 };
export const LAMP = { x: 224, y: 480 };
export const RADIO = { x: 1105, y: 718 };
// the note bubble rises from the radio's left side so the floating phone never covers it
export const BUBBLE_X = 1050;
export const BUBBLE_Y = 500;
export const CLOCK = { x: 377, y: 240, r: 40 };
export const GIRL = { x: 800, y: 546, s: 1 };

const C = {
  wall: '#fff3dc', wallLow: '#f7e2c2', sprig: '#9fd3a4',
  panel: '#bfe3c4', panelShade: '#93cba0',
  wood: '#e0a576', woodShade: '#bf8058', woodDark: '#8f5a44', woodLight: '#f2c495',
  frame: '#fffaf0', curtain: '#7fd197', curtainShade: '#4fae74', tie: '#f6c445',
  rose: '#ff9e8c', roseShade: '#e9786a', blue: '#7ab8f0', blueShade: '#4f93d6',
  cream: '#fffaf0', brass: '#f2bd3e', leaf: '#4fb87a', leafDark: '#2f8f5e', leafLight: '#9be3a9',
  desk: '#fff3e2', rug: '#8fd0f2', rugShade: '#5daee0', floor: '#d99c72', floorShade: '#b87a54',
  bookA: '#ff9e8c', bookB: '#7ab8f0', bookC: '#7fd197', bookD: '#ffd25e', bookE: '#b48ee6',
};

/* ---------- shared motifs ---------- */

function rect(x0, y0, x1, y1) { return [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]; }

// straight-edged polygon with a hand tremor: corners stay sharp, edges never look ruled
function poly(p, corners, color, opts = {}) {
  const pts = [];
  const n = corners.length;
  for (let i = 0; i < n; i++) {
    const a = corners[i], b = corners[(i + 1) % n];
    const k = Math.max(2, Math.round(Math.hypot(b[0] - a[0], b[1] - a[1]) / 40));
    for (let j = 0; j < k; j++) pts.push([a[0] + ((b[0] - a[0]) * j) / k, a[1] + ((b[1] - a[1]) * j) / k]);
  }
  const d = p.jitter(pts, opts.jit ?? 0.7);
  p.fill(d, color, opts);
  if (opts.ink !== false) p.contour(d, { w: opts.w ?? 2, breaks: opts.breaks ?? 2 });
  return d;
}

function box(p, x0, y0, x1, y1, color, opts = {}) {
  const pts = [];
  const seg = (a, b) => {
    const n = Math.max(2, Math.round(Math.hypot(b[0] - a[0], b[1] - a[1]) / 60));
    for (let i = 0; i < n; i++) pts.push([a[0] + ((b[0] - a[0]) * i) / n, a[1] + ((b[1] - a[1]) * i) / n]);
  };
  const r = rect(x0, y0, x1, y1);
  for (let i = 0; i < 4; i++) seg(r[i], r[(i + 1) % 4]);
  const d = p.jitter(pts, opts.jit ?? 0.8);
  p.fill(d, color, opts);
  if (opts.ink !== false) p.contour(d, { w: opts.w ?? 2, breaks: opts.breaks ?? 2 });
  return d;
}

function bigLeaf(p, x, y, ang, L, Wd, light, dark, curl = 0.15, split = false) {
  const c = Math.cos(ang), s = Math.sin(ang);
  const T = (u, v) => [x + u * c - v * s, y + u * s + v * c];
  const top = [], bot = [], mid = [];
  for (let i = 0; i <= 14; i++) {
    const u = i / 14;
    const bend = Math.sin(u * Math.PI) * curl * L * u;
    const v = Wd * Math.sin(Math.PI * Math.pow(u, 0.7)) * (1 - u * 0.15);
    top.push(T(u * L, -v + bend));
    bot.push(T(u * L, v + bend));
    mid.push(T(u * L, bend * 1.05));
  }
  const outline = spline([...top, ...bot.slice(1, -1).reverse()], true, 2.5);
  p.fill(outline, light, { grain: 0.16, wash: [light, dark, ang + Math.PI / 2] });
  p.fill(spline([...mid, ...bot.slice(1, -1).reverse()], true, 2.5), dark, { grain: 0.14 });
  for (let i = 2; i < 13; i += 2) {
    const a = mid[i], b = top[Math.min(14, i + 2)], b2 = bot[Math.min(14, i + 2)];
    p.line([a, [(a[0] + b[0]) / 2, (a[1] + b[1]) / 2], b], { w: 1, taper: 0.5, alpha: 0.5 });
    if (split && i > 3 && i < 12) {
      // monstera slits cut back to paper
      const q = [[(a[0] * 0.4 + b2[0] * 0.6), (a[1] * 0.4 + b2[1] * 0.6)], b2];
      p.stroke(spline(q, false, 2), { w: 3.2, color: p.dark ? p.night : C.wall, taper: 0.3 });
    }
  }
  p.line(mid.filter((_, i) => i % 2 === 0), { w: 1.4, taper: 0.3, alpha: 0.9 });
  p.contour(outline, { w: 2.1, breaks: 2 });
}

function sprig(p, x, y, s, color) {
  p.line([[x, y + s], [x + s * 0.1, y], [x - s * 0.1, y - s]], { w: 1, color, taper: 0.3 });
  for (const [dx, dy, a] of [[0, 0.3, -0.7], [0, -0.2, 0.7], [0, -0.7, -0.6]]) {
    const L = s * 0.6;
    const bx = x + dx * s, by = y + dy * s;
    p.line([[bx, by], [bx + Math.cos(a - 1.2) * L * 0.6, by + Math.sin(a - 1.2) * L * 0.6], [bx + Math.cos(a - 1.4) * L, by + Math.sin(a - 1.4) * L]], { w: 1.4, color, taper: 0.5 });
  }
}

/* ---------- far layer: her bedroom seen from the desk ---------- */

const VP = { x: 800, y: 300 }; // vanishing point of the floor and desk boards

function paintWall(p) {
  const c = p.ctx;
  const g = c.createLinearGradient(0, 0, 0, 560);
  g.addColorStop(0, p.col(C.wall));
  g.addColorStop(1, p.col(C.wallLow));
  c.fillStyle = g;
  c.fillRect(-80, -80, W + 160, 660);
  p.fill(rect(-80, -80, W + 80, 580), 'rgba(0,0,0,0)', { grain: 0.16 });
  for (let y = 30; y < 470; y += 60) {
    for (let x = (y / 60) % 2 ? 0 : 30; x < W; x += 60) sprig(p, x + p.rnd(-3, 3), y + p.rnd(-3, 3), 7, C.sprig);
  }
  // wainscot
  box(p, -40, 470, W + 40, 566, C.panel, { wash: [C.panel, C.panelShade, Math.PI / 2], grain: 0.18, w: 1.8 });
  box(p, -40, 462, W + 40, 474, C.woodLight, { grain: 0.12, w: 1.6 });
  for (let x = 30; x < W; x += 110) box(p, x, 488, x + 84, 552, C.panel, { wash: [C.panelShade, C.panel, Math.PI / 2], grain: 0.1, w: 1.2, breaks: 3 });
}

function paintFloor(p) {
  box(p, -60, 566, W + 60, 760, C.floor, { wash: [C.woodLight, C.floorShade, Math.PI / 2], grain: 0.2, w: 1.8 });
  // boards run toward the vanishing point
  for (let x = -600; x < W + 600; x += 120) {
    const t0 = (566 - VP.y) / (760 - VP.y);
    p.line([[VP.x + (x - VP.x) * t0, 566], [x, 760]], { w: 1.2, taper: 0.1, alpha: 0.55 });
  }
  for (const y of [600, 650, 712]) p.line([[-60, y], [W + 60, y]], { w: 1, taper: 0.1, alpha: 0.35 });
  const rug = spline(p.jitter(circle(700, 650, 360, 52, 40), 1), true, 2.5);
  p.fill(rug, C.rug, { wash: [C.rug, C.rugShade, Math.PI / 2], grain: 0.16 });
  p.contour(spline(circle(700, 650, 330, 40, 40), true, 2.5), { w: 1.2, breaks: 3, alpha: 0.7 });
  for (let i = 0; i < 36; i++) {
    const a = (i / 36) * TAU;
    p.line([[700 + Math.cos(a) * 345 - 3, 650 + Math.sin(a) * 46], [700 + Math.cos(a) * 345 + 3, 650 + Math.sin(a) * 46]], { w: 2, color: C.cream, taper: 0.3, alpha: 0.8 });
  }
  p.contour(rug, { w: 1.8, breaks: 3 });
}

function paintWindow(p) {
  const c = p.ctx;
  const { x0, x1, top, base, cx, r } = WIN;
  const arch = (pad) => {
    const pts = [[x0 - pad, base + pad * 0.2]];
    const ry = top + r - pad;
    for (let i = 0; i <= 24; i++) {
      const a = Math.PI + (i / 24) * Math.PI;
      pts.push([cx + Math.cos(a) * (r + pad), ry + Math.sin(a) * (r + pad) + pad]);
    }
    pts.push([x1 + pad, base + pad * 0.2]);
    return pts;
  };
  const outer = spline(p.jitter(arch(16), 0.5), true, 2.5);
  p.fill(outer, C.frame, { wash: [C.cream, '#eadfcd', Math.PI / 2], grain: 0.12 });
  const glass = spline(arch(0), true, 2.5);
  c.save();
  c.globalCompositeOperation = 'destination-out';
  p.path(glass);
  c.fill();
  c.restore();
  // leaf lattice in the arch, plain panes below
  box(p, cx - 5, top - 2, cx + 5, base, C.frame, { grain: 0.1, w: 1.4 });
  box(p, x0, 262, x1, 270, C.frame, { grain: 0.1, w: 1.4 });
  for (const s of [-1, 1]) p.line([[cx, 168], [cx + s * 54, 196], [cx + s * 96, 262]], { w: 3.4, color: C.brass, taper: 0.1 });
  for (const [gx, gy] of [[520, 170], [650, 330]]) p.line([[gx, gy + 34], [gx + 24, gy]], { w: 2, color: 'rgba(255,255,255,.75)', taper: 0.5 });
  p.contour(glass, { w: 1.6, breaks: 3 });
  p.contour(outer, { w: 2, breaks: 3 });
  // window seat with cushions, where she sits
  box(p, x0 - 50, base, x1 + 50, base + 16, C.woodLight, { grain: 0.14, w: 1.8 });
  box(p, x0 - 44, base + 16, x1 + 44, 566, C.curtain, { wash: [C.curtain, C.curtainShade, Math.PI / 2], grain: 0.16, w: 1.8 });
  for (let x = x0 - 20; x < x1 + 30; x += 80) p.line([[x, base + 30], [x, 556]], { w: 1, taper: 0.2, alpha: 0.5 });
  for (const [px, col] of [[x0 - 4, C.rose], [x1 - 40, C.brass]]) {
    const pil = spline(p.jitter([[px, base], [px + 8, base - 40], [px + 50, base - 46], [px + 58, base - 6]], 1), true, 2);
    p.fill(pil, col, { grain: 0.14, wash: ['rgba(255,255,255,.25)', 'rgba(60,40,60,.12)', 0.6] });
    p.contour(pil, { w: 1.6, breaks: 1 });
  }
}

function curtain(p, side) {
  const m = (x) => (side < 0 ? x : 2 * WIN.cx - x);
  const pts = [[402, 58], [478, 58], [474, 170], [462, 300], [470, 322], [488, 420], [494, 500], [400, 500], [404, 420], [410, 322], [404, 220], [406, 120]].map(([x, y]) => [m(x), y]);
  const d = spline(p.jitter(pts, 1), true, 2.5);
  p.fill(d, C.curtain, { wash: side < 0 ? [C.curtainShade, C.curtain, 0] : [C.curtain, C.curtainShade, 0], grain: 0.18 });
  for (const xt of [418, 434, 450, 466]) {
    p.line([[m(xt), 64], [m((xt + 440) / 2), 200], [m(440), 312]], { w: 1.1, taper: 0.4, alpha: 0.7 });
    p.line([[m(440), 330], [m((440 + xt) / 2 + 6), 420], [m(xt + 14), 496]], { w: 1.1, taper: 0.4, alpha: 0.7 });
  }
  p.contour(d, { w: 1.8, breaks: 3 });
  const tie = spline(p.jitter([[m(404), 310], [m(440), 304], [m(472), 310], [m(474), 326], [m(440), 322], [m(406), 328]], 0.5), true, 2);
  p.fill(tie, C.tie, { grain: 0.1 });
  p.contour(tie, { w: 1.4, breaks: 1 });
}

function paintClock(p) {
  const { x, y, r } = CLOCK;
  const rim = spline(circle(x, y, r + 7, r + 7, 32), true, 2);
  p.fill(rim, C.wood, { wash: [C.woodLight, C.woodShade, 0.8], grain: 0.14 });
  p.contour(rim, { w: 1.8, breaks: 2 });
  const face = spline(circle(x, y, r, r, 32), true, 2);
  p.fill(face, C.cream, { grain: 0.08 });
  p.contour(face, { w: 1.4, breaks: 2 });
  for (let i = 0; i < 12; i++) {
    const a = (i / 12) * TAU;
    const r0 = i % 3 === 0 ? r - 9 : r - 6;
    p.line([[x + Math.cos(a) * r0, y + Math.sin(a) * r0], [x + Math.cos(a) * (r - 3), y + Math.sin(a) * (r - 3)]], { w: i % 3 === 0 ? 2 : 1.2, taper: 0.1 });
  }
  // two leaves sprouting from the top
  bigLeaf(p, x, y - r - 4, -2.3, 24, 8, C.leafLight, C.leaf, 0.1);
  bigLeaf(p, x, y - r - 4, -0.8, 22, 7, C.leafLight, C.leaf, -0.1);
}

function paintShelf(p) {
  const x0 = 50, x1 = 310, y0 = 120, y1 = 566;
  box(p, x0, y0, x1, y1, C.woodShade, { wash: [C.wood, C.woodDark, 0], grain: 0.18, w: 2 });
  box(p, x0 + 14, y0 + 14, x1 - 14, y1 - 8, '#a9765c', { wash: ['#b98266', '#7f5444', Math.PI / 2], grain: 0.14, w: 1.2 });
  const shelves = [230, 340, 450];
  for (const y of shelves) {
    p.hatch([[x0 + 14, y + 10], [x1 - 14, y + 10], [x1 - 14, y + 34], [x0 + 14, y + 24]], { angle: -0.9, gap: 5, alpha: 0.3, len: [6, 16] });
    box(p, x0 + 14, y, x1 - 14, y + 10, C.wood, { grain: 0.1, w: 1.4 });
  }
  const books = [C.bookA, C.bookB, C.bookC, C.bookD, C.bookE];
  for (const [yb, from, to] of [[230, 68, 200], [340, 120, 292], [450, 68, 220], [558, 150, 292]]) {
    let x = from;
    while (x < to) {
      const w = p.rnd(12, 22), h = p.rnd(56, 92);
      const lean = p.r() < 0.12 ? p.rnd(6, 12) : 0;
      poly(p, [[x, yb], [x + w, yb], [x + w + lean, yb - h], [x + lean, yb - h]], p.pick(books), { grain: 0.14, w: 1.2, breaks: 1, jit: 0.4 });
      p.line([[x + 3 + lean * 0.3, yb - h * 0.72], [x + w - 3 + lean * 0.3, yb - h * 0.72]], { w: 1, color: C.cream, taper: 0.2, alpha: 0.8 });
      x += w + (lean ? 8 : 1);
    }
  }
  // a little round plush, a jar of glowing seeds, a sprout on top
  const plush = spline(p.jitter(circle(250, 205, 30, 26, 20), 0.8), true, 2);
  p.fill(plush, C.leafLight, { grain: 0.1, wash: [C.leafLight, C.leaf, 0.8] });
  p.contour(plush, { w: 1.6, breaks: 1 });
  for (const ex of [240, 262]) p.fill(spline(circle(ex, 202, 3, 3, 8), true, 2), '#2c2838', { grain: 0 });
  bigLeaf(p, 250, 180, -1.7, 22, 7, C.leafLight, C.leaf, 0.1);
  const jar = spline(p.jitter([[90, 340], [86, 286], [96, 278], [130, 278], [140, 286], [136, 340]], 0.5), true, 2);
  p.fill(jar, 'rgba(225,245,235,.8)', { grain: 0.05 });
  for (let i = 0; i < 7; i++) p.fill(spline(circle(p.rnd(98, 128), p.rnd(298, 332), 4, 5, 8), true, 2), C.brass, { grain: 0 });
  p.contour(jar, { w: 1.4, breaks: 1 });
  const pot = spline(p.jitter([[150, 120], [144, 86], [206, 86], [200, 120]], 0.5), true, 2);
  for (const a of [-2.3, -1.6, -0.9, -2.7, -0.5]) bigLeaf(p, 175, 88, a, p.rnd(30, 44), p.rnd(9, 12), C.leafLight, C.leaf, 0.1);
  p.fill(pot, C.rose, { wash: [C.rose, C.roseShade, 0], grain: 0.14 });
  p.contour(pot, { w: 1.6, breaks: 1 });
}

function paintBed(p) {
  // canopy drapes from the ceiling
  for (const [xa, xb] of [[870, 930], [1160, 1220]]) {
    const d = spline(p.jitter([[xa, -40], [xb, -40], [xb - 6, 200], [xb + 6, 420], [xa - 6, 420], [xa + 8, 200]], 1), true, 2.5);
    p.fill(d, 'rgba(225,246,232,.85)', { grain: 0.08 });
    for (let k = 1; k < 4; k++) p.line([[xa + ((xb - xa) * k) / 4, -30], [xa + ((xb - xa) * k) / 4 + 4, 200], [xa + ((xb - xa) * k) / 4 - 2, 410]], { w: 1, taper: 0.4, alpha: 0.5 });
    p.contour(d, { w: 1.4, breaks: 2 });
  }
  // headboard
  const hb = spline(p.jitter([[900, 470], [900, 330], [960, 270], [1045, 252], [1130, 270], [1190, 330], [1190, 470]], 1), true, 2.5);
  p.fill(hb, C.woodLight, { wash: [C.woodLight, C.wood, Math.PI / 2], grain: 0.16 });
  p.contour(hb, { w: 1.8, breaks: 2 });
  const leafCarve = [[1045, 300], [1015, 330], [1045, 372], [1075, 330]];
  p.fill(spline(leafCarve, true, 2), C.leaf, { grain: 0 });
  p.contour(spline(leafCarve, true, 2), { w: 1.2, breaks: 1 });
  // pillows and quilt
  for (const [px, col] of [[930, C.cream], [1060, '#e6f6e9']]) {
    const pil = spline(p.jitter([[px, 440], [px + 6, 396], [px + 60, 388], [px + 116, 396], [px + 120, 440]], 1), true, 2);
    p.fill(pil, col, { grain: 0.08, wash: ['rgba(255,255,255,.4)', 'rgba(60,80,70,.12)', Math.PI / 2] });
    p.contour(pil, { w: 1.5, breaks: 1 });
  }
  const quilt = spline(p.jitter([[880, 430], [1210, 430], [1220, 540], [1200, 566], [880, 566], [870, 540]], 1), true, 2.5);
  p.fill(quilt, C.curtain, { wash: ['#a9e7b9', C.curtainShade, Math.PI / 2], grain: 0.16 });
  for (let i = 0; i < 9; i++) bigLeaf(p, p.rnd(900, 1190), p.rnd(450, 545), p.rnd(0, TAU), 16, 6, C.cream, '#d9f1df', 0);
  p.line([[880, 446], [1210, 446]], { w: 1.4, color: C.cream, taper: 0.1 });
  p.contour(quilt, { w: 1.8, breaks: 2 });
  const plush = spline(p.jitter(circle(1150, 418, 24, 21, 18), 0.6), true, 2);
  p.fill(plush, C.rose, { grain: 0.1, wash: [C.rose, C.roseShade, 0.8] });
  p.contour(plush, { w: 1.4, breaks: 1 });
}

function paintFairyLights(p) {
  const pts = [];
  for (let i = 0; i <= 40; i++) {
    const u = i / 40;
    pts.push([-40 + u * (W + 80), 36 + Math.sin(u * Math.PI * 3) ** 2 * 46]);
  }
  p.line(pts, { w: 1.3, taper: 0.02 });
  for (let i = 2; i < 40; i += 2) {
    const [x, y] = pts[i];
    bigLeaf(p, x, y, Math.PI / 2 + p.rnd(-0.4, 0.4), 14, 5, C.leafLight, C.leaf, 0);
    p.fill(spline(circle(x + 2, y + 18, 5, 6, 10), true, 2), '#ffe28a', { grain: 0 });
  }
}

function paintBack(p) {
  paintWall(p);
  paintFloor(p);
  paintWindow(p);
  p.line([[388, 56], [852, 56]], { w: 4, taper: 0.02, startW: 0.8, endW: 0.8, color: C.woodShade });
  curtain(p, -1);
  curtain(p, 1);
  paintShelf(p);
  paintClock(p);
  paintBed(p);
  paintFairyLights(p);
}

/* ---------- near layer: the top of her desk, right in front of the phone ---------- */

function paintDesk(p) {
  // a white painted desk with a pale green felt mat, so it reads apart from the wooden floor
  const top = 700;
  box(p, -60, top - 14, W + 60, top + 2, '#e9dcc8', { grain: 0.12, w: 2.4 });
  box(p, -60, top, W + 60, 960, C.desk, { wash: ['#fffaf0', '#eadcc6', Math.PI / 2], grain: 0.16, w: 2.4 });
  for (let x = -800; x < W + 800; x += 160) {
    const t0 = (top - VP.y) / (960 - VP.y);
    p.line([[VP.x + (x - VP.x) * t0, top], [x, 960]], { w: 1, taper: 0.2, alpha: 0.25 });
  }
  const mat = [[380, 724], [1180, 724], [1260, 960], [300, 960]];
  poly(p, mat, '#cfeccf', { wash: ['#dff5dc', '#b2ddb6', Math.PI / 2], grain: 0.14, w: 1.8, breaks: 3 });
  p.line([[400, 734], [1166, 734]], { w: 1, color: '#fffaf0', taper: 0.1, alpha: 0.8 });
}

function shadowUnder(p, x, y, rx, ry) {
  const c = p.ctx;
  c.save();
  c.fillStyle = p.dark ? 'rgba(0,0,0,.25)' : 'rgba(90,55,40,.3)';
  c.filter = 'blur(6px)';
  c.beginPath();
  c.ellipse(x, y, rx, ry, 0, 0, TAU);
  c.fill();
  c.restore();
}

function paintLamp(p) {
  const { x } = LAMP;
  shadowUnder(p, x + 20, 800, 120, 18);
  const base = spline(circle(x, 792, 92, 20, 30), true, 2);
  p.fill(base, C.brass, { wash: ['#ffe08a', '#c9922a', 0], grain: 0.1 });
  p.contour(base, { w: 2.4, breaks: 1 });
  p.line([[x, 786], [x - 4, 640], [x, 480]], { w: 14, taper: 0, startW: 1, endW: 1, color: '#d9a43a' });
  p.line([[x - 7, 786], [x - 11, 640], [x - 7, 480]], { w: 2, taper: 0.1 });
  p.line([[x + 7, 786], [x + 3, 640], [x + 7, 480]], { w: 2, taper: 0.1 });
  poly(p, [[x - 62, 320], [x + 62, 320], [x + 150, 470], [x - 150, 470]], C.rose, { wash: ['#ffc0b0', C.roseShade, 0.2], grain: 0.16, w: 3 });
  for (let k = -4; k <= 4; k++) p.line([[x + k * 13, 324], [x + k * 32, 466]], { w: 1.4, taper: 0.3, alpha: 0.4 });
  p.line([[x - 120, 420], [x + 120, 420]], { w: 2, color: C.cream, taper: 0.2, alpha: 0.9 });
  p.line([[x - 112, 430], [x + 112, 430]], { w: 2, color: C.cream, taper: 0.2, alpha: 0.9 });
  poly(p, [[x - 154, 466], [x + 154, 466], [x + 150, 480], [x - 150, 480]], C.roseShade, { grain: 0.1, w: 2.2, breaks: 1 });
}

function paintDeskThings(p) {
  // picture books, a cup of tea, a sprout and the radio
  shadowUnder(p, 520, 778, 110, 12);
  for (const [y, x0, x1, col] of [[748, 420, 620, C.bookB], [722, 432, 608, C.bookA], [696, 424, 600, C.bookD]]) {
    box(p, x0, y, x1, y + 26, col, { grain: 0.14, w: 2 });
    p.line([[x1 - 8, y + 5], [x1 - 8, y + 21]], { w: 1.4, color: C.cream, taper: 0.1 });
    p.line([[x0 + 12, y + 13], [x0 + 70, y + 13]], { w: 1.2, color: C.cream, taper: 0.2, alpha: 0.8 });
  }
  bigLeaf(p, 560, 698, -0.3, 40, 12, C.leafLight, C.leaf, 0.1);
  shadowUnder(p, 700, 776, 60, 10);
  const mug = spline(p.jitter([[650, 650], [750, 650], [744, 770], [656, 770]], 0.6), true, 2);
  p.fill(mug, C.blue, { wash: ['#a8d4ff', C.blueShade, 0], grain: 0.14 });
  bigLeaf(p, 700, 712, -0.6, 30, 10, C.leafLight, C.leaf, 0.1);
  p.contour(mug, { w: 2.4, breaks: 1 });
  p.line([[748, 670], [780, 676], [780, 726], [744, 740]], { w: 4, taper: 0 });
  for (const sx of [676, 712]) p.line([[sx, 640], [sx - 10, 610], [sx + 6, 584], [sx - 4, 556]], { w: 2, taper: 0.5, alpha: 0.5 });
  shadowUnder(p, 820, 774, 46, 8);
  const pot = spline(p.jitter([[788, 770], [780, 712], [860, 712], [852, 770]], 0.6), true, 2);
  for (const a of [-2.3, -1.6, -1.0, -2.7, -0.5]) bigLeaf(p, 820, 714, a, p.rnd(44, 60), p.rnd(13, 17), C.leafLight, C.leaf, 0.1);
  p.fill(pot, C.rose, { wash: [C.rose, C.roseShade, 0], grain: 0.14 });
  p.contour(pot, { w: 2.2, breaks: 1 });
  // radio
  const { x, y } = RADIO;
  shadowUnder(p, x, y + 86, 130, 14);
  p.line([[x + 70, y - 70], [x + 130, y - 170]], { w: 3, taper: 0.1 });
  const ball = spline(circle(x + 131, y - 172, 6, 6, 10), true, 2);
  p.fill(ball, C.brass, { grain: 0 });
  p.contour(ball, { w: 1.6, breaks: 1 });
  const body = spline(p.jitter([[x - 112, y - 74], [x + 112, y - 74], [x + 118, y - 60], [x + 118, y + 80], [x - 118, y + 80], [x - 118, y - 60]], 0.8), true, 2.5);
  p.fill(body, C.blue, { wash: ['#a8d4ff', C.blueShade, 0.4], grain: 0.16 });
  p.contour(body, { w: 2.8, breaks: 2 });
  box(p, x - 118, y - 74, x + 118, y - 56, C.woodLight, { grain: 0.1, w: 2 });
  const grille = spline(circle(x - 50, y + 8, 46, 46, 36), true, 2);
  p.fill(grille, C.cream, { grain: 0.1 });
  p.hatch(grille, { angle: 0, gap: 6, alpha: 0.6, len: [80, 100], w: 1.4 });
  p.contour(grille, { w: 2.2, breaks: 1 });
  box(p, x + 10, y - 34, x + 100, y + 8, '#fff1c9', { grain: 0.06, w: 2 });
  for (let i = 0; i < 11; i++) p.line([[x + 16 + i * 8, y - 30], [x + 16 + i * 8, y - 22]], { w: 1.2, taper: 0 });
  p.line([[x + 52, y - 34], [x + 46, y + 8]], { w: 2.4, color: '#e0503e', taper: 0 });
  for (const kx of [x + 30, x + 80]) {
    const k = spline(circle(kx, y + 40, 12, 12, 14), true, 2);
    p.fill(k, C.brass, { grain: 0 });
    p.contour(k, { w: 1.8, breaks: 1 });
  }
}

// leaves of a hanging plant right in front of the lens, framing the top corners
function paintFraming(p) {
  for (const [x, y, a, L, Wd] of [[-60, -60, 0.95, 300, 80], [40, -80, 1.35, 240, 66], [-80, 120, 0.35, 220, 60], [140, -70, 1.75, 180, 52]]) {
    bigLeaf(p, x, y, a, L, Wd, C.leaf, C.leafDark, 0.12, true);
  }
  for (const [x, y, a, L, Wd] of [[1680, -60, 2.2, 260, 70], [1600, -90, 1.8, 200, 56]]) {
    bigLeaf(p, x, y, a, L, Wd, C.leaf, C.leafDark, -0.12, true);
  }
}

function paintFront(p) {
  paintDesk(p);
  paintDeskThings(p);
  paintLamp(p);
  paintFraming(p);
}

/* ---------- her shadow ---------- */

// Sitting on the window seat, seen from across the room: long hair, a side ponytail, small shoulders.
function paintGirl(ctx) {
  const p = new Painter(ctx, 5);
  const col = '#4b3d58';
  // drawn in seat-relative units, then placed on the window seat
  ctx.translate(GIRL.x, GIRL.y);
  ctx.scale(GIRL.s, GIRL.s);
  const shape = (pts) => {
    const d = spline(pts, true, 3);
    p.path(d);
    ctx.fillStyle = col;
    ctx.fill();
  };
  shape(circle(0, -128, 32, 36, 24));
  shape([[-34, -136], [-30, -168], [-8, -184], [18, -182], [36, -164], [40, -128], [44, -80], [48, -30], [34, -12], [22, -60], [14, -100], [-14, -100], [-24, -54], [-40, -8], [-52, -32], [-46, -86]]);
  shape([[30, -162], [56, -156], [70, -120], [74, -68], [66, -14], [52, 0], [56, -50], [52, -104], [40, -136]]);
  shape([[-40, -112], [40, -112], [46, -40], [-46, -40]]);
  shape([[-60, 0], [-56, -42], [-38, -66], [-10, -76], [10, -76], [38, -66], [56, -42], [60, 0]]);
  // knees on the seat
  shape([[-50, 0], [50, 0], [56, 22], [-56, 22]]);
}

/* ---------- plugins for the finale ---------- */

export function paintPlugin(kind, scale) {
  const L = layer(150, 150, scale);
  const p = new Painter(L.ctx, kind.length * 13);
  const c = L.ctx;
  c.translate(75, 75);
  if (kind === 'tavern') {
    p.line([[-50, -60], [50, -60]], { w: 3, taper: 0.05, color: C.woodShade });
    p.line([[-30, -60], [-30, -40]], { w: 1.6, taper: 0 });
    p.line([[30, -60], [30, -40]], { w: 1.6, taper: 0 });
    box(p, -52, -40, 52, 28, C.wood, { wash: [C.woodLight, C.woodShade, 0.6], grain: 0.18, w: 2.2 });
    const mug = spline(p.jitter([[-18, -26], [14, -26], [12, 16], [-16, 16]], 0.5), true, 2);
    p.fill(mug, '#e8c88f', { grain: 0.1 });
    p.contour(mug, { w: 1.8, breaks: 1 });
    const foam = spline(p.jitter([[-22, -26], [-14, -36], [-2, -32], [10, -38], [18, -26]], 0.5), true, 2);
    p.fill(foam, C.cream, { grain: 0 });
    p.contour(foam, { w: 1.6, breaks: 1 });
    p.line([[13, -18], [26, -16], [26, 4], [12, 8]], { w: 2.2, taper: 0 });
    for (const sx of [-10, -2, 6]) p.line([[sx, -18], [sx, 10]], { w: 1, taper: 0.2, alpha: 0.5 });
  } else if (kind === 'search') {
    p.line([[16, 16], [48, 48]], { w: 12, taper: 0, startW: 1, endW: 1, color: C.woodShade });
    p.line([[18, 14], [50, 46]], { w: 1.4, taper: 0.1 });
    const ring = spline(circle(-8, -8, 38, 38, 32), true, 2);
    p.fill(ring, C.brass, { grain: 0.1 });
    p.contour(ring, { w: 2.2, breaks: 1 });
    const lens = spline(circle(-8, -8, 29, 29, 32), true, 2);
    p.fill(lens, '#dbe8ee', { wash: ['#f4fbfd', '#b9cfdc', 0.8], grain: 0.06 });
    p.contour(lens, { w: 1.6, breaks: 1 });
    p.line([[-24, -14], [-12, -28]], { w: 3, color: 'rgba(255,255,255,.9)', taper: 0.4 });
  } else if (kind === 'chest') {
    const body = box(p, -52, -6, 52, 46, C.wood, { wash: [C.woodLight, C.woodShade, 0.5], grain: 0.18, w: 2.2 });
    void body;
    const lid = spline(p.jitter([[-54, -6], [-52, -30], [-30, -46], [30, -46], [52, -30], [54, -6]], 0.6), true, 2.5);
    p.fill(lid, C.woodShade, { wash: [C.wood, C.woodDark, 0.5], grain: 0.16 });
    p.contour(lid, { w: 2.2, breaks: 1 });
    for (const bx of [-34, 30]) box(p, bx, -44, bx + 8, 46, C.brass, { grain: 0, w: 1.4 });
    box(p, -10, -14, 10, 10, C.brass, { grain: 0, w: 1.6 });
    for (let i = 0; i < 5; i++) {
      const a = -Math.PI / 2 + (i - 2) * 0.35;
      p.line([[Math.cos(a) * 52, -50 + Math.sin(a) * 18], [Math.cos(a) * 64, -56 + Math.sin(a) * 26]], { w: 2, color: '#e8b14f', taper: 0.4 });
    }
  } else if (kind === 'brush') {
    const pal = spline(p.jitter([[-52, 10], [-44, -26], [0, -40], [44, -22], [50, 14], [20, 36], [-6, 22], [-30, 40]], 1), true, 2.5);
    p.fill(pal, C.woodLight, { grain: 0.14 });
    p.contour(pal, { w: 2.2, breaks: 1 });
    for (const [dx, dy, col] of [[-26, -14, C.rose], [0, -24, '#e8c88f'], [24, -12, C.blue], [26, 14, C.leaf]]) {
      const d = spline(p.jitter(circle(dx, dy, 9, 8, 12), 0.6), true, 2);
      p.fill(d, col, { grain: 0 });
      p.contour(d, { w: 1.3, breaks: 1 });
    }
    p.line([[-40, 50], [30, -50]], { w: 6, taper: 0, startW: 1, endW: 1, color: C.woodShade });
    p.line([[30, -50], [40, -64]], { w: 9, taper: 0.4, color: C.roseShade });
  } else if (kind === 'record') {
    const disc = spline(circle(0, 0, 50, 50, 40), true, 2);
    p.fill(disc, '#3c3a52', { grain: 0.1 });
    for (const r of [42, 34, 26]) p.contour(spline(circle(0, 0, r, r, 32), true, 2), { w: 1, breaks: 2, color: '#8f88a8' });
    const lab = spline(circle(0, 0, 16, 16, 24), true, 2);
    p.fill(lab, C.rose, { grain: 0 });
    p.contour(lab, { w: 1.4, breaks: 1 });
    p.contour(disc, { w: 2.2, breaks: 1 });
    p.line([[-30, -34], [-16, -42]], { w: 2.4, color: 'rgba(255,255,255,.5)', taper: 0.5 });
  } else if (kind === 'diary') {
    const cover = spline(p.jitter([[-40, -52], [40, -52], [44, 52], [-36, 52]], 0.8), true, 2.5);
    p.fill(cover, C.curtain, { wash: [C.leafLight, C.curtainShade, 0.6], grain: 0.16 });
    p.contour(cover, { w: 2.2, breaks: 1 });
    box(p, -40, -52, -28, 52, C.curtainShade, { grain: 0, w: 1.6 });
    const heart = spline([[6, -6], [-10, -22], [-18, -6], [6, 18], [30, -6], [22, -22]], true, 2);
    p.fill(heart, C.rose, { grain: 0 });
    p.contour(heart, { w: 1.6, breaks: 1 });
    p.line([[30, -52], [30, -20], [36, -26], [42, -20], [42, -52]], { w: 1.4, taper: 0 });
  }
  return L.cv;
}

// Music-note bubble that floats out of the radio
export function paintBubble(scale) {
  const L = layer(170, 170, scale);
  const p = new Painter(L.ctx, 9);
  const c = L.ctx;
  c.translate(85, 85);
  const b = spline(p.jitter(circle(0, 0, 66, 64, 36), 0.8), true, 2);
  p.fill(b, 'rgba(251,245,236,.92)', { grain: 0.08, wash: ['rgba(255,255,255,.9)', 'rgba(214,190,206,.85)', 0.9] });
  p.line([[-44, -22], [-36, -40], [-18, -52]], { w: 4, color: 'rgba(255,255,255,.95)', taper: 0.5 });
  // eighth notes
  const head = (x, y) => {
    const d = spline(circle(x, y, 11, 8, 16, -0.4), true, 2);
    p.fill(d, C.rose, { grain: 0 });
    p.contour(d, { w: 1.8, breaks: 1 });
  };
  head(-14, 26);
  head(22, 16);
  p.line([[-4, 24], [-4, -22]], { w: 3, taper: 0, startW: 1, endW: 1 });
  p.line([[32, 14], [32, -32]], { w: 3, taper: 0, startW: 1, endW: 1 });
  poly(p, [[-5, -24], [33, -34], [33, -24], [-5, -14]], '#2c2838', { grain: 0, w: 1.4, breaks: 1, jit: 0.2 });
  p.contour(b, { w: 2.4, breaks: 2 });
  return L.cv;
}

/* ---------- entry ---------- */

function paint(fn, dark, seed, scale, w = W, h = H) {
  const pad = 60;
  const L = layer(w + pad * 2, h + pad * 2, scale);
  L.ctx.translate(pad, pad);
  const p = new Painter(L.ctx, seed);
  p.dark = dark;
  fn(p);
  return L.cv;
}

// Brush-painted fallback for whichever layers have no artwork file; painting is skipped for the rest.
export function paintRoom(scale, need = { back: true, front: true, girl: true }) {
  const out = {};
  if (need.girl) {
    const girl = layer(W + 120, H + 120, scale);
    girl.ctx.translate(60, 60);
    paintGirl(girl.ctx);
    out.girl = girl.cv;
  }
  if (need.back) {
    out.backLit = paint(paintBack, false, 101, scale);
    out.backDark = paint(paintBack, true, 101, scale);
  }
  if (need.front) {
    out.frontLit = paint(paintFront, false, 202, scale);
    out.frontDark = paint(paintFront, true, 202, scale);
  }
  return out;
}
