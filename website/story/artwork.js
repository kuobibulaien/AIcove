// Optional hand-made artwork that replaces the procedural layers.
// Drop images into website/assets/story/ under the names below; anything missing falls back to the brush painter.
//
// .webp or .png both work. Every image is a full 1600x900 frame (any multiple, e.g. 3200x1800) with a transparent background where noted:
//   room-back   the bedroom beyond the desk: wall, window (glass transparent), window seat, shelf, clock, bed, floor
//   room-front  the desk top in the foreground with lamp, books, mug, radio, and leaves framing the top corners;
//               transparent everywhere else
//   room-girl   her blurred silhouette on the window seat; transparent elsewhere
// Prompts and the hand-off brief live in design/story/ (not published with the site).
// Only the lit version is needed: the dark version is derived (sunk into night, pale outlines traced from edges).
// Deriving it in the browser is slow for 3200px art, so ship <name>-dark alongside when possible.
// Interactive spots (lamp chain, radio, clock) are positioned by the anchors in room.js; move them if the art moves.

const PAD = 60; // painted layers carry a 60px margin for parallax; images are placed inside it

export const ART = {
  back: 'assets/story/room-back',
  front: 'assets/story/room-front',
  girl: 'assets/story/room-girl',
};

async function loadImage(base) {
  for (const ext of ['.webp', '.png']) {
    const img = await tryImage(base + ext);
    if (img) return img;
  }
  return null;
}

async function tryImage(src) {
  try {
    const res = await fetch(src, { method: 'HEAD' });
    if (!res.ok) return null;
    // onload rather than decode(): decode() can stall while the tab is in the background
    const img = await new Promise((resolve) => {
      const im = new Image();
      im.onload = () => resolve(im);
      im.onerror = () => resolve(null);
      im.src = src;
    });
    // decode off the main thread now rather than on first draw, where it stalls a frame;
    // capped because decode() can hang while the tab is in the background
    if (img) await Promise.race([img.decode().catch(() => {}), new Promise((r) => setTimeout(r, 1500))]);
    return img;
  } catch {
    return null;
  }
}

// Place a 1600x900 image on a canvas matching the painted layer size
function toLayer(img, scale) {
  const cv = document.createElement('canvas');
  cv.width = Math.round((1600 + PAD * 2) * scale);
  cv.height = Math.round((900 + PAD * 2) * scale);
  const g = cv.getContext('2d');
  g.drawImage(img, PAD * scale, PAD * scale, 1600 * scale, 900 * scale);
  return cv;
}

// Night version of a lit layer: darkened, desaturated, with pale outlines traced from luminance edges
export function darkify(src, { night = [27, 26, 40], line = [156, 149, 181] } = {}) {
  const w = src.width, h = src.height;
  const cv = document.createElement('canvas');
  cv.width = w;
  cv.height = h;
  const g = cv.getContext('2d');
  g.drawImage(src, 0, 0);
  const img = g.getImageData(0, 0, w, h);
  const d = img.data;
  const lum = new Float32Array(w * h);
  for (let i = 0, j = 0; i < d.length; i += 4, j++) lum[j] = (d[i] * 0.3 + d[i + 1] * 0.59 + d[i + 2] * 0.11) * (d[i + 3] / 255);
  const out = g.createImageData(w, h);
  const o = out.data;
  for (let y = 1; y < h - 1; y++) {
    for (let x = 1; x < w - 1; x++) {
      const k = y * w + x, i = k * 4;
      const gx = -lum[k - w - 1] - 2 * lum[k - 1] - lum[k + w - 1] + lum[k - w + 1] + 2 * lum[k + 1] + lum[k + w + 1];
      const gy = -lum[k - w - 1] - 2 * lum[k - w] - lum[k - w + 1] + lum[k + w - 1] + 2 * lum[k + w] + lum[k + w + 1];
      const edge = Math.min(1, Math.max(0, (Math.hypot(gx, gy) - 70) / 160));
      const a = d[i + 3];
      // base: the colour sunk most of the way into night
      const t = 0.86;
      let r = d[i] + (night[0] - d[i]) * t, gg = d[i + 1] + (night[1] - d[i + 1]) * t, b = d[i + 2] + (night[2] - d[i + 2]) * t;
      r += (line[0] - r) * edge * 0.75;
      gg += (line[1] - gg) * edge * 0.75;
      b += (line[2] - b) * edge * 0.75;
      o[i] = r;
      o[i + 1] = gg;
      o[i + 2] = b;
      o[i + 3] = Math.max(a, edge * 200);
    }
  }
  g.putImageData(out, 0, 0);
  return cv;
}

// A single prop (note bubble, finale icons): artwork file if present, otherwise the painted canvas
export async function prop(name, paint) {
  const img = await loadImage(`assets/story/${name}`);
  return img || paint();
}

// Returns the room layers, preferring artwork files over painted ones
export async function roomLayers(paint, scale) {
  // night versions may be shipped pre-baked (<name>-dark); otherwise they are derived here, which is slow on big images
  const [back, front, girl, backNight, frontNight] = await Promise.all([
    loadImage(ART.back), loadImage(ART.front), loadImage(ART.girl), loadImage(`${ART.back}-dark`), loadImage(`${ART.front}-dark`),
  ]);
  const out = paint(scale, { back: !back, front: !front, girl: !girl });
  out.source = { back: back ? 'art' : 'brush', front: front ? 'art' : 'brush', girl: girl ? 'art' : 'brush' };
  if (back) {
    out.backLit = toLayer(back, scale);
    out.backDark = backNight ? toLayer(backNight, scale) : darkify(out.backLit);
  }
  if (front) {
    out.frontLit = toLayer(front, scale);
    out.frontDark = frontNight ? toLayer(frontNight, scale) : darkify(out.frontLit);
  }
  if (girl) out.girl = toLayer(girl, scale);
  return out;
}
