// Ink-and-wash brush engine on canvas 2D.
// Lines are filled polygons with pressure taper and tremor, fills carry paper grain and wash shading,
// so shapes read as inked illustration instead of uniform vector strokes.

export function mulberry32(a) {
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const TAU = Math.PI * 2;

/* ---------- geometry ---------- */

// Catmull-Rom sampled into a dense polyline
export function spline(pts, closed = false, step = 3) {
  const n = pts.length;
  if (n < 2) return pts.slice();
  const P = (i) => (closed ? pts[(i + n) % n] : pts[Math.max(0, Math.min(n - 1, i))]);
  const out = [];
  const segs = closed ? n : n - 1;
  for (let i = 0; i < segs; i++) {
    const p0 = P(i - 1), p1 = P(i), p2 = P(i + 1), p3 = P(i + 2);
    const len = Math.hypot(p2[0] - p1[0], p2[1] - p1[1]);
    const k = Math.max(2, Math.ceil(len / step));
    for (let j = 0; j < k; j++) {
      const t = j / k, t2 = t * t, t3 = t2 * t;
      out.push([
        0.5 * (2 * p1[0] + (-p0[0] + p2[0]) * t + (2 * p0[0] - 5 * p1[0] + 4 * p2[0] - p3[0]) * t2 + (-p0[0] + 3 * p1[0] - 3 * p2[0] + p3[0]) * t3),
        0.5 * (2 * p1[1] + (-p0[1] + p2[1]) * t + (2 * p0[1] - 5 * p1[1] + 4 * p2[1] - p3[1]) * t2 + (-p0[1] + 3 * p1[1] - 3 * p2[1] + p3[1]) * t3),
      ]);
    }
  }
  if (!closed) out.push(pts[n - 1]);
  return out;
}

export function circle(cx, cy, rx, ry = rx, n = 24, rot = 0) {
  return Array.from({ length: n }, (_, i) => {
    const a = (i / n) * TAU + rot;
    return [cx + Math.cos(a) * rx, cy + Math.sin(a) * ry];
  });
}

export function bbox(pts) {
  let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
  for (const [x, y] of pts) {
    if (x < x0) x0 = x;
    if (y < y0) y0 = y;
    if (x > x1) x1 = x;
    if (y > y1) y1 = y;
  }
  return { x0, y0, x1, y1, w: x1 - x0, h: y1 - y0 };
}

/* ---------- colour ---------- */

export function parseColor(c) {
  if (c[0] === '#') {
    const h = c.length === 4 ? c.slice(1).split('').map((x) => x + x).join('') : c.slice(1, 7);
    return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16), 1];
  }
  const m = c.match(/rgba?\(([^)]+)\)/);
  if (!m) return [0, 0, 0, 1];
  const v = m[1].split(',').map((x) => parseFloat(x));
  return [v[0], v[1], v[2], v.length > 3 ? v[3] : 1];
}

export function mix(a, b, t) {
  const A = parseColor(a), B = parseColor(b);
  const r = (i) => Math.round(A[i] + (B[i] - A[i]) * t);
  return `rgba(${r(0)},${r(1)},${r(2)},${A[3]})`;
}

/* ---------- textures (built once) ---------- */

let GRAIN = null;
function grainCanvas() {
  if (GRAIN) return GRAIN;
  const c = document.createElement('canvas');
  c.width = c.height = 256;
  const g = c.getContext('2d');
  const img = g.createImageData(256, 256);
  const r = mulberry32(7);
  for (let i = 0; i < img.data.length; i += 4) {
    const v = 150 + r() * 105;
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v;
    img.data[i + 3] = 255;
  }
  g.putImageData(img, 0, 0);
  // soft blotches: pigment pooling
  for (let i = 0; i < 40; i++) {
    const x = r() * 256, y = r() * 256, rad = 10 + r() * 40;
    const gr = g.createRadialGradient(x, y, 0, x, y, rad);
    gr.addColorStop(0, `rgba(120,110,105,${0.06 + r() * 0.08})`);
    gr.addColorStop(1, 'rgba(120,110,105,0)');
    g.fillStyle = gr;
    g.fillRect(x - rad, y - rad, rad * 2, rad * 2);
  }
  GRAIN = c;
  return c;
}

/* ---------- painter ---------- */

export class Painter {
  constructor(ctx, seed = 1) {
    this.ctx = ctx;
    this.r = mulberry32(seed);
    this.ink = '#2c2838';
    // dark: everything sunk into the night, only pale outlines remain
    this.dark = false;
    this.night = '#1b1a28';
    this.darkInk = '#9c95b5';
  }

  // map a paint colour through the current lighting mode
  col(c) {
    if (!this.dark || !c) return c;
    const [, , , a] = parseColor(c);
    return mix(c, this.night, 0.86).replace(/,[\d.]+\)$/, `,${a})`);
  }

  rnd(a = 0, b = 1) { return a + (b - a) * this.r(); }
  grain() { return grainCanvas(); }
  pick(arr) { return arr[Math.floor(this.r() * arr.length)]; }

  // smooth low-frequency noise along arc length
  tremor() {
    const ph = [this.rnd(0, TAU), this.rnd(0, TAU), this.rnd(0, TAU)];
    const fq = [this.rnd(0.03, 0.05), this.rnd(0.09, 0.14), this.rnd(0.2, 0.3)];
    return (s) => Math.sin(s * fq[0] + ph[0]) * 0.55 + Math.sin(s * fq[1] + ph[1]) * 0.3 + Math.sin(s * fq[2] + ph[2]) * 0.15;
  }

  // jitter control points along their normal for a hand-placed contour
  jitter(pts, amp, closed = true) {
    const n = pts.length;
    return pts.map((p, i) => {
      const a = pts[(i - 1 + n) % n], b = pts[(i + 1) % n];
      if (!closed && (i === 0 || i === n - 1)) return p;
      let nx = -(b[1] - a[1]), ny = b[0] - a[0];
      const l = Math.hypot(nx, ny) || 1;
      const k = this.rnd(-amp, amp);
      return [p[0] + (nx / l) * k, p[1] + (ny / l) * k];
    });
  }

  path(pts, closed = true) {
    const c = this.ctx;
    c.beginPath();
    c.moveTo(pts[0][0], pts[0][1]);
    for (let i = 1; i < pts.length; i++) c.lineTo(pts[i][0], pts[i][1]);
    if (closed) c.closePath();
  }

  /*
   * Variable-width ink stroke over a dense polyline.
   * w: nominal width; taper: share of length used to swell in/out; press: pressure variation 0..1
   */
  stroke(line, { w = 2, color = this.ink, taper = 0.25, press = 0.45, alpha = 1, startW = 0.05, endW = 0.05 } = {}) {
    const n = line.length;
    if (n < 2) return;
    const c = this.ctx;
    const tr = this.tremor();
    const L = [];
    let total = 0;
    for (let i = 1; i < n; i++) total += Math.hypot(line[i][0] - line[i - 1][0], line[i][1] - line[i - 1][1]);
    let s = 0;
    const left = [], right = [];
    for (let i = 0; i < n; i++) {
      if (i > 0) s += Math.hypot(line[i][0] - line[i - 1][0], line[i][1] - line[i - 1][1]);
      const u = total ? s / total : 0;
      const a = line[Math.max(0, i - 1)], b = line[Math.min(n - 1, i + 1)];
      let nx = -(b[1] - a[1]), ny = b[0] - a[0];
      const l = Math.hypot(nx, ny) || 1;
      nx /= l;
      ny /= l;
      let k = 1;
      if (taper > 0) {
        if (u < taper) k = startW + (1 - startW) * Math.sin((u / taper) * Math.PI / 2);
        else if (u > 1 - taper) k = endW + (1 - endW) * Math.sin(((1 - u) / taper) * Math.PI / 2);
      }
      const hw = Math.max(0.15, (w / 2) * k * (1 + press * tr(s)));
      left.push([line[i][0] + nx * hw, line[i][1] + ny * hw]);
      right.push([line[i][0] - nx * hw, line[i][1] - ny * hw]);
      L.push(hw);
    }
    c.save();
    c.globalAlpha = this.dark ? alpha * (color === this.ink ? 0.7 : 0.5) : alpha;
    c.fillStyle = this.dark ? (color === this.ink ? this.darkInk : this.col(color)) : color;
    c.beginPath();
    c.moveTo(left[0][0], left[0][1]);
    for (let i = 1; i < n; i++) c.lineTo(left[i][0], left[i][1]);
    for (let i = n - 1; i >= 0; i--) c.lineTo(right[i][0], right[i][1]);
    c.closePath();
    c.fill();
    c.restore();
  }

  // open curve through control points, inked
  line(ctrl, opts = {}) {
    this.stroke(spline(ctrl, false, 2.5), opts);
  }

  // Closed contour inked in 2-4 overlapping strokes with small gaps, like a real pen lifting
  contour(dense, { w = 2.2, color = this.ink, breaks = 3, alpha = 1, press = 0.5 } = {}) {
    const n = dense.length;
    const k = Math.max(1, breaks);
    let start = Math.floor(this.rnd(0, n));
    for (let i = 0; i < k; i++) {
      const len = Math.floor(n / k);
      const gap = this.r() < 0.55 ? Math.floor(this.rnd(2, 6)) : -Math.floor(this.rnd(1, 4));
      const seg = [];
      for (let j = 0; j <= len - Math.max(0, gap); j++) seg.push(dense[(start + j) % n]);
      if (seg.length > 2) this.stroke(seg, { w, color, taper: 0.12, press, alpha, startW: 0.2, endW: 0.2 });
      start = (start + len) % n;
    }
  }

  // Flat colour + wash gradient + paper grain, clipped to the shape
  fill(dense, color, { wash = null, grain = 0.16, edge = 0 } = {}) {
    const c = this.ctx;
    const bb = bbox(dense);
    c.save();
    this.path(dense);
    c.fillStyle = this.col(color);
    c.fill();
    c.clip();
    if (wash && !this.dark) {
      // wash: [colorA, colorB, angle] darker pigment collecting on one side
      const [ca, cb, ang = Math.PI / 2] = wash;
      const cx = (bb.x0 + bb.x1) / 2, cy = (bb.y0 + bb.y1) / 2;
      const R = Math.max(bb.w, bb.h) / 2;
      const g = c.createLinearGradient(cx - Math.cos(ang) * R, cy - Math.sin(ang) * R, cx + Math.cos(ang) * R, cy + Math.sin(ang) * R);
      g.addColorStop(0, ca);
      g.addColorStop(1, cb);
      c.fillStyle = g;
      c.fillRect(bb.x0 - 2, bb.y0 - 2, bb.w + 4, bb.h + 4);
    }
    if (edge > 0 && !this.dark) {
      // watercolour edge darkening: inner stroke blurred
      c.save();
      c.filter = `blur(${edge * 0.8}px)`;
      c.lineWidth = edge * 2;
      c.strokeStyle = 'rgba(60,40,60,.10)';
      this.path(dense);
      c.stroke();
      c.restore();
    }
    if (grain > 0) {
      c.globalCompositeOperation = 'multiply';
      c.globalAlpha = this.dark ? grain * 0.6 : grain;
      c.fillStyle = c.createPattern(grainCanvas(), 'repeat');
      c.fillRect(bb.x0 - 2, bb.y0 - 2, bb.w + 4, bb.h + 4);
    }
    c.restore();
  }

  // Region of short parallel tapered strokes, clipped
  hatch(clipDense, { angle = -0.9, gap = 7, w = 1.1, color = this.ink, alpha = 0.55, jitter = 0.35, len = [8, 30], density = 1 } = {}) {
    const c = this.ctx;
    const bb = bbox(clipDense);
    c.save();
    this.path(clipDense);
    c.clip();
    const dx = Math.cos(angle), dy = Math.sin(angle);
    const nx = -dy, ny = dx;
    const cx = (bb.x0 + bb.x1) / 2, cy = (bb.y0 + bb.y1) / 2;
    const R = Math.hypot(bb.w, bb.h) / 2 + 10;
    for (let o = -R; o <= R; o += gap) {
      let t = -R + this.rnd(0, 10);
      while (t < R) {
        const l = this.rnd(len[0], len[1]);
        if (this.r() < density) {
          const off = o + this.rnd(-gap * jitter, gap * jitter);
          const x = cx + nx * off + dx * t, y = cy + ny * off + dy * t;
          this.stroke([[x, y], [x + dx * l * 0.5, y + dy * l * 0.5], [x + dx * l, y + dy * l]], { w, color, alpha, taper: 0.5, press: 0.2 });
        }
        t += l + this.rnd(3, 12);
      }
    }
    c.restore();
  }

  // Convenience: inked, filled shape from control points
  shape(ctrl, color, opts = {}) {
    const dense = spline(opts.rough === false ? ctrl : this.jitter(ctrl, opts.jit ?? 1.2), true, 2.5);
    this.fill(dense, color, opts);
    if (opts.shade) opts.shade(dense);
    if (opts.ink !== false) this.contour(dense, { w: opts.w ?? 2.2, breaks: opts.breaks ?? 3, color: opts.inkColor || this.ink, alpha: opts.inkAlpha ?? 1 });
    return dense;
  }

  // soft glow / light pool
  glow(x, y, r, color, alpha = 1) {
    if (this.dark) return;
    const c = this.ctx;
    const g = c.createRadialGradient(x, y, 0, x, y, r);
    g.addColorStop(0, color);
    g.addColorStop(1, color.replace(/[\d.]+\)$/, '0)'));
    c.save();
    c.globalAlpha = alpha;
    c.fillStyle = g;
    c.fillRect(x - r, y - r, r * 2, r * 2);
    c.restore();
  }
}

// Offscreen layer canvas at device resolution
export function layer(w, h, scale) {
  const cv = document.createElement('canvas');
  cv.width = Math.round(w * scale);
  cv.height = Math.round(h * scale);
  const ctx = cv.getContext('2d');
  ctx.scale(scale, scale);
  ctx.lineJoin = 'round';
  ctx.lineCap = 'round';
  return { cv, ctx };
}
