import { paintRoom, paintBubble, paintPlugin, BUBBLE_X, BUBBLE_Y, CLOCK, GIRL } from './room.js';
import { Painter, spline } from './paint.js';
import { roomLayers, prop } from './artwork.js';

const $ = (s) => document.querySelector(s);
const params = new URLSearchParams(location.search);
const reduceMotion = matchMedia('(prefers-reduced-motion: reduce)').matches;
// ?at=N fast-forwards through the story to chapter N (for review)
const AT = Number(params.get('at') || 0);
let chapter = 0;
const fast = () => chapter < AT;
// waits run on GSAP's clock, so the story and its animations pause together when the tab is hidden and stay in step
const sleep = (ms) => new Promise((r) => gsap.delayedCall(fast() ? 0.03 * gsap.globalTimeline.timeScale() : ms / 1000, r));
const speed = () => gsap.globalTimeline.timeScale(fast() ? 40 : reduceMotion ? 3 : 1);

/* ---------- preload ----------
 * Everything the story uses starts downloading the moment the page opens, all at once, and the start
 * button waits for it, so no scene ever stops to fetch a file.
 */
const FINALE_ITEMS = [
  ['tavern', '酒馆', 360, 140], ['search', '搜索', 250, 360], ['brush', '画画', 380, 560],
  ['record', '声音', 1090, 140], ['diary', '记忆', 1200, 360], ['chest', '工具箱 · MCP', 1070, 560],
];
// first URL that answers, as an in-memory blob URL (blobs also keep audio seekable; see bgm)
const fetchBlob = async (urls) => {
  for (const url of urls) {
    try {
      const res = await fetch(url);
      if (res.ok) return URL.createObjectURL(await res.blob());
    } catch { /* try the next one */ }
  }
  return null;
};
const imageLoaded = (img) => (img.complete ? Promise.resolve() : new Promise((r) => { img.onload = img.onerror = r; }));
const preload = {
  bgm: Object.fromEntries(['night', 'home', 'finale'].map((n) => [n, fetchBlob([`assets/story/bgm/${n}.m4a`, `assets/story/bgm/${n}.mp3`])])),
  voice: fetchBlob(['assets/story/voice-hello.mp3']),
  bubble: prop('note-bubble', () => paintBubble(2)),
  icons: Promise.all(FINALE_ITEMS.map(([kind]) => prop(`plugin-${kind}`, () => paintPlugin(kind, 2)))),
};
// the start button counts the downloads in and unlocks once they are all here (or after a long wait on a slow line)
const startGate = (roomReady) => {
  const jobs = [roomReady, ...Object.values(preload.bgm), preload.voice, preload.bubble, preload.icons,
    imageLoaded(document.querySelector('#selfie')), document.fonts.ready];
  const btn = document.querySelector('#start');
  const pct = btn.querySelector('b');
  let done = 0;
  const show = () => { pct.textContent = Math.round((done / jobs.length) * 100); };
  show();
  jobs.forEach((j) => Promise.resolve(j).catch(() => {}).finally(() => { done++; show(); }));
  return Promise.race([Promise.allSettled(jobs), new Promise((r) => setTimeout(r, 20000))]).then(() => {
    btn.disabled = false;
  });
};

/* ---------- stage fit ---------- */
const stage = $('#stage');
const fit = () => { stage.style.transform = `scale(${Math.min(innerWidth / 1600, innerHeight / 900)})`; };
addEventListener('resize', fit);
fit();

/* ---------- paint the room ---------- */
const artScale = Math.min(2, Math.max(1, (devicePixelRatio || 1) * Math.min(innerWidth / 1600, innerHeight / 900)));
// artwork files in assets/story/ win over the brush; see artwork.js
const roomReady = roomLayers(paintRoom, artScale);
const ready = startGate(roomReady);
// show the title once its fonts are in (with a cap, so a blocked font host can't hide it)
Promise.race([document.fonts.ready, new Promise((r) => setTimeout(r, 2500))]).then(() => $('#title').classList.add('fonts'));
const room = await roomReady;
room.girl.className = 'girl';
const fx = (cls) => Object.assign(document.createElement('div'), { className: cls });
const depth = (el, d) => { el.dataset.depth = d; return el; };
// her shadow sits in a wrapper so parallax and her own sway never fight over the same transform
const girlWrap = depth(fx('layer'), 0.45);
girlWrap.append(room.girl);
depth(room.backDark, 0.25);
depth(room.backLit, 0.25);
depth(room.frontDark, 1);
depth(room.frontLit, 1);
$('#darkRoom').append(room.backDark, room.frontDark);
$('#litRoom').append(room.backLit, girlWrap, room.frontLit, fx('vignette'), depth(fx('pool'), 1), depth(fx('cone'), 1), depth(fx('bulb'), 1));
// the room fades up behind the title instead of popping in mid-load
gsap.to('#room', { opacity: 1, duration: 1.2, ease: 'sine.out' });

/* ---------- parallax: near things drift more than far ones ---------- */
const movers = [...document.querySelectorAll('[data-depth]')].map((el) => ({
  d: Number(el.dataset.depth),
  x: gsap.quickTo(el, 'x', { duration: 1.1, ease: 'power3' }),
  y: gsap.quickTo(el, 'y', { duration: 1.1, ease: 'power3' }),
}));
addEventListener('pointermove', (e) => {
  const nx = e.clientX / innerWidth - 0.5, ny = e.clientY / innerHeight - 0.5;
  for (const m of movers) {
    m.x(-nx * 30 * m.d);
    m.y(-ny * 14 * m.d);
  }
});
for (let i = 0; i < 26; i++) {
  const s = document.createElement('i');
  s.style.left = `${Math.random() * 100}%`;
  s.style.top = `${Math.random() * 70}%`;
  s.style.animationDelay = `-${Math.random() * 3}s`;
  s.style.transform = `scale(${0.5 + Math.random()})`;
  $('#stars').append(s);
}

/* ---------- background music ----------
 * Optional tracks in assets/story/bgm/ (m4a or mp3): night, home, finale. Chapter four plays the quiet opening of finale,
 * so the story only changes track twice. Prompts: 配乐提示词.md.
 * When a track exists it replaces the synthesised pad and music box; sound effects stay synthesised.
 */
const bgm = {
  names: ['night', 'home', 'finale'],
  tracks: {},
  current: null,
  level: 0.6,
  ducked: false,
  scene: 1, // per-scene loudness: the quiet stretch of chapter four sits low, the reunion swells back up
  target() { return audio.muted ? 0 : this.level * this.scene * (this.ducked ? 0.6 : 1); }, // her voice carries on its own; only ease the music back
  // ride the volume of whatever is playing without switching tracks
  swell(scene, seconds) {
    this.scene = scene;
    if (this.current) gsap.to(this.current, { volume: this.target(), duration: seconds, ease: 'sine.inOut', overwrite: 'auto' });
  },
  found: new Set(), // tracks whose files have arrived
  pending: {},       // name -> promise of the ready <audio>, or null
  want: null,        // the track the story most recently asked for
  // The files were already requested by the preloader at page open; this only wraps them as players.
  load() {
    for (const n of this.names) {
      this.pending[n] = preload.bgm[n].then((url) => {
        if (!url) return null;
        this.found.add(n);
        const el = new Audio(url);
        el.loop = true;
        el.volume = 0;
        this.tracks[n] = el;
        return el;
      });
    }
    // the story may start once the first track is in hand (or after a short wait)
    return Promise.race([this.pending.night, sleep(4000)]);
  },
  get active() { return this.found.size > 0; },
  play(name, fade = 2.5, from = 0) {
    this.want = name;
    const next = this.tracks[name];
    if (!next) {
      // still downloading: start it when it arrives, unless the story has moved on by then
      this.pending[name]?.then((el) => { if (el && this.want === name) this.play(name, fade, from); });
      return;
    }
    if (this.current === next) return;
    const prev = this.current;
    this.current = next;
    // roughly equal-power crossfade: the old track holds on while the new one rises, so the overlap never dips
    if (prev) gsap.to(prev, { volume: 0, duration: fade, ease: 'sine.in', overwrite: 'auto', onComplete: () => prev.pause() });
    // seeking before metadata has loaded is silently ignored, so wait for it when needed
    const seek = () => { next.currentTime = from; };
    if (next.readyState >= 1) seek();
    else next.addEventListener('loadedmetadata', seek, { once: true });
    next.play().catch(() => {});
    gsap.to(next, { volume: this.target(), duration: fade, ease: 'sine.out', overwrite: 'auto' });
  },
  // Keep the current track circling between `from` and `to` (seconds), crossfading a second copy back to `from`
  // each time, so a quiet passage can wait as long as the viewer needs.
  hold(from, to, fade = 3) {
    this.release();
    const tick = () => {
      const el = this.current;
      if (el && !el.paused && el.currentTime >= to - fade) this.handover(from, fade, fade);
    };
    this.holding = setInterval(tick, 100);
  },
  release() {
    clearInterval(this.holding);
    this.holding = null;
  },
  // jump the current track to `at` through a crossfade with a fresh copy of itself
  handover(at, fadeIn, fadeOut) {
    const prev = this.current;
    if (!prev) return;
    const next = new Audio(prev.src);
    next.loop = true;
    next.volume = 0;
    this.current = next;
    gsap.to(prev, { volume: 0, duration: fadeOut, ease: 'sine.in', overwrite: 'auto', onComplete: () => prev.pause() });
    const go = () => {
      next.currentTime = at;
      next.play().catch(() => {});
      gsap.to(next, { volume: this.target(), duration: fadeIn, ease: 'sine.out', overwrite: 'auto' });
    };
    if (next.readyState >= 1) go();
    else next.addEventListener('loadedmetadata', go, { once: true });
  },
  // land on the track's turn right now, at full scene loudness
  turn(at) {
    this.release();
    this.scene = 1;
    if (this.current) this.handover(at, 0.9, 1.4);
  },
  setMuted() {
    if (this.current) gsap.to(this.current, { volume: this.target(), duration: 0.4, overwrite: 'auto' });
  },
  // lower the music under her voice, then bring it back
  duck(on) {
    this.ducked = on;
    if (this.current) gsap.to(this.current, { volume: this.target(), duration: on ? 0.6 : 1.8, ease: 'sine.inOut', overwrite: 'auto' });
  },
  fadeOut(seconds = 1) {
    if (!this.current) return Promise.resolve();
    return new Promise((r) => gsap.to(this.current, { volume: 0, duration: seconds, onComplete: r, overwrite: 'auto' }));
  },
};
const bgmReady = bgm.load();
// seconds into finale.m4a where the music opens up (the original Sunlight_Through_Leaves turns at about 34 s; 3 s were trimmed)
const FINALE_TURN = 31.0;
// the quiet stretch of finale's opening that chapter four circles in while it waits for your answer
const FINALE_HOLD = [2, 23];
if (AT) window.__bgm = bgm; // review hook

// her recorded voice for the chapter-two voice message
const voice = new Audio();
voice.preload = 'auto';
let voiceOk = true;
voice.addEventListener('error', () => { voiceOk = false; });
preload.voice.then((url) => { if (url) voice.src = url; else voiceOk = false; });

/* ---------- sound effects: synthesised, no audio files ---------- */
const audio = {
  ctx: null,
  muted: false,
  init() {
    if (this.ctx) return;
    const AC = window.AudioContext || window.webkitAudioContext;
    if (!AC) return;
    this.ctx = new AC();
    this.master = this.ctx.createGain();
    this.master.gain.value = this.muted ? 0 : 0.9;
    this.master.connect(this.ctx.destination);
    if (!bgm.active) this.pad();
  },
  setMuted(m) {
    this.muted = m;
    bgm.setMuted(m);
    gsap.to(voice, { volume: m ? 0 : 1, duration: 0.3, overwrite: 'auto' });
    if (this.ctx) this.ramp(this.master.gain, m ? 0 : 0.9, 0.4);
  },
  ramp(param, value, seconds) {
    const now = this.ctx.currentTime;
    param.cancelScheduledValues(now);
    param.setValueAtTime(param.value, now);
    param.linearRampToValueAtTime(value, now + seconds);
  },
  pad() {
    const c = this.ctx;
    this.padFilter = c.createBiquadFilter();
    this.padFilter.type = 'lowpass';
    this.padFilter.frequency.value = 320;
    this.padGain = c.createGain();
    this.padGain.gain.value = 0;
    this.padFilter.connect(this.padGain).connect(this.master);
    [110, 164.81, 220, 277.18].forEach((hz, i) => {
      const o = c.createOscillator();
      o.type = i % 2 ? 'triangle' : 'sine';
      o.frequency.value = hz;
      o.detune.value = (i - 1.5) * 5;
      const g = c.createGain();
      g.gain.value = i === 3 ? 0 : 0.25;
      if (i === 3) this.warmVoice = g;
      o.connect(g).connect(this.padFilter);
      o.start();
    });
    const lfo = c.createOscillator();
    const depth = c.createGain();
    lfo.frequency.value = 0.07;
    depth.gain.value = 100;
    lfo.connect(depth).connect(this.padFilter.frequency);
    lfo.start();
    this.ramp(this.padGain.gain, 0.04, 4);
  },
  warm() {
    if (!this.ctx || !this.padGain) return;
    this.ramp(this.padGain.gain, 0.07, 3);
    this.ramp(this.padFilter.frequency, 950, 3);
    this.ramp(this.warmVoice.gain, 0.16, 4);
  },
  tone(freq, vol, dur, delay = 0, type = 'sine') {
    if (!this.ctx) return;
    const c = this.ctx, t = c.currentTime + delay;
    const o = c.createOscillator(), g = c.createGain();
    o.type = type;
    o.frequency.value = freq;
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(vol, t + 0.008);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    o.connect(g).connect(this.master);
    o.start(t);
    o.stop(t + dur + 0.05);
  },
  thump(freq = 60, vol = 0.6, dur = 0.28, delay = 0, attack = 0.01) {
    if (!this.ctx) return;
    const c = this.ctx, t = c.currentTime + delay;
    const o = c.createOscillator(), g = c.createGain();
    o.frequency.setValueAtTime(freq * 1.6, t);
    o.frequency.exponentialRampToValueAtTime(freq * 0.6, t + dur);
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(vol, t + attack);
    g.gain.exponentialRampToValueAtTime(0.001, t + dur);
    o.connect(g).connect(this.master);
    o.start(t);
    o.stop(t + dur + 0.05);
  },
  noise(dur, from, to, vol, q = 1.2) {
    if (!this.ctx) return;
    const c = this.ctx, t = c.currentTime;
    const buf = c.createBuffer(1, Math.ceil(c.sampleRate * dur), c.sampleRate);
    const data = buf.getChannelData(0);
    for (let i = 0; i < data.length; i++) data[i] = Math.random() * 2 - 1;
    const src = c.createBufferSource();
    const flt = c.createBiquadFilter();
    const g = c.createGain();
    src.buffer = buf;
    flt.type = 'bandpass';
    flt.Q.value = q;
    flt.frequency.setValueAtTime(from, t);
    flt.frequency.exponentialRampToValueAtTime(to, t + dur);
    g.gain.setValueAtTime(0, t);
    g.gain.linearRampToValueAtTime(vol, t + dur * 0.3);
    g.gain.linearRampToValueAtTime(0, t + dur);
    src.connect(flt).connect(g).connect(this.master);
    src.start(t);
  },
  // a felt pulse under the music rather than a sound effect; it rests while her voice plays
  heartbeat(v = 1) {
    if (bgm.ducked) return;
    this.thump(54, 0.13 * v, 0.2, 0, 0.03);
    this.thump(47, 0.08 * v, 0.22, 0.19, 0.03);
  },
  key() { this.tone(1700 + Math.random() * 500, 0.02, 0.04, 0, 'triangle'); },
  sent() { this.noise(0.35, 900, 3400, 0.05); this.tone(1046.5, 0.05, 0.25, 0.05); },
  blip() { this.tone(880, 0.09, 0.3); this.tone(1318.5, 0.07, 0.4, 0.09); },
  click() { this.noise(0.05, 2500, 1800, 0.12, 4); this.tone(2200, 0.03, 0.05, 0, 'square'); },
  pop() {
    this.noise(0.18, 2400, 600, 0.12, 0.9);
    [783.99, 987.77, 1174.66, 1567.98].forEach((f, i) => this.chime(f, 0.04, 0.05 + i * 0.07));
  },
  shutter() {
    this.noise(0.04, 4000, 2500, 0.2, 2);
    setTimeout(() => this.noise(0.06, 3000, 1500, 0.16, 2), 90);
  },
  // a wordless hummed phrase standing in for her voice until a recording is supplied
  hum(onEnd) {
    if (!this.ctx) return onEnd?.();
    const c = this.ctx, t0 = c.currentTime + 0.05;
    const phrase = [[587.33, 0.42], [659.25, 0.32], [783.99, 0.62], [659.25, 0.3], [587.33, 0.36], [523.25, 0.9]];
    const out = c.createGain();
    out.gain.value = 0.7;
    const f1 = c.createBiquadFilter(), f2 = c.createBiquadFilter();
    f1.type = f2.type = 'bandpass';
    f1.frequency.value = 520; f1.Q.value = 3;
    f2.frequency.value = 1150; f2.Q.value = 6;
    f1.connect(out); f2.connect(out);
    out.connect(this.master);
    let t = t0;
    for (const [hz, d] of phrase) {
      const o = c.createOscillator(), g = c.createGain(), vib = c.createOscillator(), vg = c.createGain();
      o.type = 'sawtooth';
      o.frequency.setValueAtTime(hz * 0.97, t);
      o.frequency.linearRampToValueAtTime(hz, t + 0.08);
      vib.frequency.value = 5.2;
      vg.gain.value = hz * 0.012;
      vib.connect(vg).connect(o.frequency);
      g.gain.setValueAtTime(0, t);
      g.gain.linearRampToValueAtTime(0.09, t + 0.07);
      g.gain.setValueAtTime(0.08, t + d - 0.08);
      g.gain.linearRampToValueAtTime(0, t + d + 0.04);
      o.connect(g);
      g.connect(f1);
      g.connect(f2);
      o.start(t); vib.start(t);
      o.stop(t + d + 0.1); vib.stop(t + d + 0.1);
      t += d;
    }
    setTimeout(() => onEnd?.(), (t - c.currentTime) * 1000 + 100);
  },
  chime(freq, vol = 0.045, delay = 0) {
    this.tone(freq, vol, 1.8, delay);
    this.tone(freq * 2, vol * 0.3, 0.9, delay, 'triangle');
  },
  // music box drifting over the pad once her room is lit
  melody() {
    if (!this.ctx || this.melodyOn || bgm.active) return;
    this.melodyOn = true;
    const notes = [523.25, 587.33, 659.25, 783.99, 880, 1046.5];
    let i = 2;
    const step = () => {
      if (!this.melodyOn) return;
      i = Math.max(0, Math.min(notes.length - 1, i + Math.round(Math.random() * 4 - 2)));
      this.chime(notes[i], 0.035);
      setTimeout(step, 520 + Math.random() * 900);
    };
    step();
  },
};

const soundBtn = $('#sound');
soundBtn.addEventListener('click', () => {
  audio.setMuted(!audio.muted);
  soundBtn.classList.toggle('off', audio.muted);
});

/* ---------- heartbeat line along the floor ---------- */
const pulseCv = $('#pulse');
const pctx = pulseCv.getContext('2d');
pctx.scale(2, 2);
const ecg = { amp: 0, bpm: 66, phase: 0, acc: 0, step: 4, speed: 170, lit: 0 };
ecg.samples = new Float32Array(Math.ceil(1500 / ecg.step) + 1);
const gauss = (t, mu, s) => Math.exp(-((t - mu) ** 2) / (2 * s * s));
const beatShape = (t) => 0.1 * gauss(t, 0.1, 0.025) - 0.14 * gauss(t, 0.2, 0.008) + gauss(t, 0.222, 0.009)
  - 0.3 * gauss(t, 0.246, 0.01) + 0.2 * gauss(t, 0.44, 0.04);

function drawPulse(dt) {
  ecg.acc += ecg.speed * dt;
  const s = ecg.samples;
  while (ecg.acc >= ecg.step) {
    ecg.acc -= ecg.step;
    const prev = ecg.phase;
    ecg.phase = (ecg.phase + (ecg.step / ecg.speed) * (ecg.bpm / 60)) % 1;
    if (prev < 0.222 && ecg.phase >= 0.222 && ecg.amp > 0.2) audio.heartbeat(ecg.amp);
    // new samples enter at the phone end and travel toward her
    s.copyWithin(1, 0);
    s[0] = ecg.amp * beatShape(ecg.phase);
  }
  pctx.clearRect(0, 0, 1600, 100);
  const pts = [];
  for (let i = 0; i < s.length; i++) pts.push([1160 - i * ecg.step + ecg.acc, 52 - s[i] * 34]);
  const p = new Painter(pctx, 3);
  const col = ecg.lit > 0.5 ? '#2c2838' : '#9c95b5';
  p.stroke(pts.reverse().filter(([x]) => x > 70), { w: 3, color: col, taper: 0.05, press: 0.25, startW: 0.4, endW: 1 });
  // a small heart at her end
  const hx = 50, hy = 52, k = 1 + (ecg.amp > 0.2 ? gauss(ecg.phase, 0.24, 0.03) * 0.35 : 0);
  const heart = [[hx, hy + 11 * k], [hx - 12 * k, hy - 1 * k], [hx - 10 * k, hy - 9 * k], [hx - 3 * k, hy - 9 * k], [hx, hy - 4 * k], [hx + 3 * k, hy - 9 * k], [hx + 10 * k, hy - 9 * k], [hx + 12 * k, hy - 1 * k]];
  const hd = spline(heart, true, 1.5);
  p.path(hd);
  pctx.fillStyle = ecg.lit > 0.5 ? '#d49a8e' : '#3a3850';
  pctx.fill();
  p.contour(hd, { w: 1.8, breaks: 1, color: col });
}

let last = performance.now();
function frame(now) {
  drawPulse(Math.min((now - last) / 1000, 0.05));
  last = now;
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
if (AT || params.get('state')) {
  gsap.ticker.lagSmoothing(0);
  let t0 = performance.now();
  setInterval(() => {
    const now = performance.now();
    gsap.updateRoot(now / 1000);
    drawPulse(Math.min((now - t0) / 1000, 0.05));
    t0 = now;
  }, 16);
}

/* ---------- phone ---------- */
const phone = $('#phone');
const REST = { x: 0, y: 0 };
// centre of the phone at rest, in stage coordinates
const PHONE_C = { x: 1300, y: 430 };
let bob = null;
function floatPhone() {
  bob?.kill();
  bob = gsap.to(phone, { y: '-=12', rotate: 2, duration: 2.8, ease: 'sine.inOut', yoyo: true, repeat: -1 });
}

function pushMsg(el) {
  $('#msgs .empty')?.remove();
  $('#msgs').append(el);
  return el;
}
function bubble(kind, text) {
  const el = document.createElement('div');
  el.className = `b ${kind}`;
  el.textContent = text;
  pushMsg(el);
  gsap.from(el, { scale: 0.5, opacity: 0, y: 8, duration: 0.5, ease: 'back.out(2.2)', transformOrigin: kind === 'me' ? '100% 100%' : '0 100%' });
  return el;
}
function typing() {
  const el = document.createElement('div');
  el.className = 'b ai typing';
  el.innerHTML = '<i></i><i></i><i></i>';
  pushMsg(el);
  gsap.from(el, { opacity: 0, y: 6, duration: 0.3 });
  return el;
}
function presence(text, on) {
  $('#presence').textContent = text;
  $('#presence').classList.toggle('on', on);
}
async function aiSays(text, wait = 1600) {
  presence('正在输入…', true);
  const t = typing();
  await sleep(wait);
  t.remove();
  presence('在线', true);
  audio.blip();
  return bubble('ai', text);
}

// time skips: a small divider and a few faded bubbles standing in for the days in between
function skipAhead(label) {
  const add = (el) => { pushMsg(el); gsap.from(el, { opacity: 0, y: 6, duration: 0.5 }); };
  add(Object.assign(document.createElement('div'), { className: 'chip', textContent: label }));
  for (const [kind, bars] of [['me', [70, 40]], ['ai', [90, 60, 30]], ['me', [55]]]) {
    const g = document.createElement('div');
    g.className = `b ${kind} ghost`;
    g.innerHTML = bars.map((w) => `<i style="width:${w}px"></i>`).join('');
    add(g);
  }
}

// resolves once she has been heard through to the end
function voiceBubble() {
  let heard;
  const played = new Promise((r) => { heard = r; });
  const el = document.createElement('div');
  el.className = 'b ai voice invite';
  const bars = [6, 10, 14, 9, 16, 12, 7, 13, 17, 10, 6, 11, 8, 5];
  el.innerHTML = `<span class="play"></span><span class="wave">${bars.map((h, i) => `<i style="height:${h}px;animation-delay:${(i % 5) * 0.09}s"></i>`).join('')}</span><small>0:10</small>`;
  pushMsg(el);
  gsap.from(el, { scale: 0.5, opacity: 0, duration: 0.5, ease: 'back.out(2.2)', transformOrigin: '0 100%' });
  el.addEventListener('click', () => {
    if (el.classList.contains('playing')) return;
    el.classList.remove('invite');
    el.classList.add('playing');
    const done = () => {
      el.classList.remove('playing');
      bgm.duck(false);
      if (audio.ctx && audio.padGain) audio.ramp(audio.master.gain, audio.muted ? 0 : 0.9, 1.5);
      heard();
    };
    bgm.duck(true);
    if (audio.ctx && audio.padGain) audio.ramp(audio.master.gain, audio.muted ? 0 : 0.6, 0.5);
    if (!voiceOk) return audio.hum(done);
    // fade her voice in and out so the breath at either end doesn't click on or off
    const full = audio.muted ? 0 : 1;
    voice.currentTime = 0;
    voice.volume = 0;
    voice.onended = done;
    voice.ontimeupdate = () => {
      if (voice.duration && voice.duration - voice.currentTime < 0.7 && !voice.fadingOut) {
        voice.fadingOut = true;
        gsap.to(voice, { volume: 0, duration: 0.6, ease: 'sine.in', overwrite: 'auto' });
      }
    };
    voice.fadingOut = false;
    voice.play().then(() => gsap.to(voice, { volume: full, duration: 0.35, ease: 'sine.out', overwrite: 'auto' }))
      .catch(() => audio.hum(done));
  });
  if (fast()) heard();
  return played;
}

function picBubble(src) {
  const el = document.createElement('div');
  el.className = 'b ai pic';
  el.innerHTML = `<img src="${src}" alt="她的自拍">`;
  pushMsg(el);
  gsap.from(el, { scale: 0.4, opacity: 0, duration: 0.6, ease: 'back.out(1.8)', transformOrigin: '0 100%' });
  return el;
}

function lockComposer(locked) {
  $('.composer').classList.toggle('off', locked);
  $('#typed').textContent = locked ? '……' : '';
}

// type the line into the composer, then wait for the send button
async function compose(text) {
  const typed = $('#typed');
  typed.textContent = '';
  for (const ch of text) {
    typed.textContent += ch;
    audio.key();
    await sleep(80 + Math.random() * 80);
  }
  $('#send').classList.add('ready');
  $('#sendTip').classList.add('show');
  await waitClick($('#send'));
  $('#send').classList.remove('ready');
  $('#sendTip').classList.remove('show');
  typed.textContent = '';
  audio.sent();
  return bubble('me', text);
}

function waitClick(el) {
  if (fast()) return sleep(10);
  return new Promise((r) => el.addEventListener('click', r, { once: true }));
}

/* ---------- storybook cards ---------- */
async function chapterCard(no, name) {
  const card = $('#card');
  await gsap.to(card, { opacity: 0, y: -10, duration: 0.4 });
  card.querySelector('small').textContent = no;
  card.querySelector('b').textContent = name;
  gsap.fromTo(card, { opacity: 0, y: -14, rotate: -2 }, { opacity: 1, y: 0, rotate: 0, duration: 0.9, ease: 'back.out(1.6)' });
}
async function narrate(text) {
  const el = $('#narr');
  await gsap.to(el, { opacity: 0, y: 8, duration: 0.35 });
  el.querySelector('span').textContent = text;
  gsap.fromTo(el, { opacity: 0, y: 10 }, { opacity: 1, y: 0, duration: 0.8, ease: 'power2.out' });
}

function hint(x, y, text) {
  const h = $('#hint');
  h.style.left = `${x}px`;
  h.style.top = `${y}px`;
  h.querySelector('span').textContent = text;
  h.classList.add('show');
  const hot = document.createElement('div');
  hot.className = 'hot';
  Object.assign(hot.style, { left: `${x - 40}px`, top: `${y - 40}px`, width: '80px', height: '80px' });
  stage.append(hot);
  return waitClick(hot).then(() => {
    h.classList.remove('show');
    hot.remove();
  });
}

/* ---------- chapters ---------- */

async function opening() {
  chapter = 0;
  speed();
  await bgmReady;
  audio.init();
  bgm.play('night', 3);
  await gsap.to('#title', { opacity: 0, duration: 1, ease: 'power2.inOut' });
  $('#title').remove();
  // the empty chat hangs in the middle of the dark, slips, and drifts down to the right like a falling leaf
  gsap.set(phone, { x: 800 - PHONE_C.x, y: 450 - PHONE_C.y, scale: 1.12, rotate: 0, opacity: 0 });
  await gsap.to(phone, { opacity: 1, duration: 1, ease: 'power2.out' });
  await sleep(1400);
  audio.tone(196, 0.05, 0.4);
  await gsap.to(phone, { rotate: -5, duration: 0.18, ease: 'sine.inOut', yoyo: true, repeat: 1 });
  await sleep(160);
  audio.noise(2.4, 1400, 260, 0.04);
  // one continuous tween along a cubic curve: drops, swings right along the bottom, settles at rest.
  // Tilt and scale ride the same progress value, so speed and rotation never jump between segments.
  const P0 = [800 - PHONE_C.x, 450 - PHONE_C.y], P1 = [P0[0] + 60, P0[1] + 290], P2 = [-260, 200], P3 = [REST.x, REST.y];
  const bez = (t, i) => (1 - t) ** 3 * P0[i] + 3 * (1 - t) ** 2 * t * P1[i] + 3 * (1 - t) * t * t * P2[i] + t ** 3 * P3[i];
  const fall = { t: 0 };
  await gsap.to(fall, {
    t: 1, duration: 2.8, ease: 'power1.inOut',
    onUpdate: () => {
      const t = fall.t;
      const sway = Math.sin(t * Math.PI * 2.2) * 15 * (1 - t) ** 1.4;
      gsap.set(phone, { x: bez(t, 0), y: bez(t, 1), rotate: sway + 3 * t, scale: 1.12 - 0.12 * t });
    },
  });
  audio.chime(523.25, 0.03);
  floatPhone();
}

async function chapterHello() {
  chapter = 1;
  speed();
  chapterCard('第一章', '你好');
  narrate('手机那头，是一间还没亮灯的小屋。');
  await sleep(1200);
  await compose('在吗？');
  await sleep(700);
  narrate('好像有人听见了。拉一下灯绳吧。');
  gsap.fromTo('#chain', { y: -6 }, { y: 0, duration: 0.6, ease: 'bounce.out' });
  await hint(350, 602, '拉一下');
  // pull the chain, light floods out from the lamp
  audio.click();
  await gsap.to('#chain', { y: 16, duration: 0.12, ease: 'power2.in', yoyo: true, repeat: 1 });
  $('#room').classList.add('lit');
  gsap.set('#litRoom', { opacity: 1, '--r': '0px' });
  gsap.to('#litRoom', { '--r': '2300px', duration: 3.2, ease: 'power2.inOut' });
  gsap.to('#glow', { opacity: 0.75, duration: 1.4, ease: 'power2.out' });
  gsap.to(ecg, { lit: 1, duration: 0.01 });
  ecg.phase = 0.12;
  gsap.to(ecg, { amp: 1, duration: 0.4 });
  audio.warm();
  bgm.play('home', 5);
  setTimeout(() => audio.melody(), 1400);
  await sleep(1300);
  gsap.to('#litRoom .girl', { opacity: 0.92, duration: 2.6, ease: 'sine.inOut' });
  gsap.to('#litRoom .girl', { x: 4, y: -2, duration: 3.2, ease: 'sine.inOut', yoyo: true, repeat: -1 });
  await sleep(1400);
  await aiSays('在呀。刚刚是你帮我开的灯吗？');
  await sleep(500);
  narrate('一句「在吗」，有人替她开了灯。');
}

async function chapterVoice() {
  chapter = 2;
  speed();
  await sleep(2200);
  chapterCard('第二章', '声音');
  narrate('后来，你们聊了很多天。');
  skipAhead('聊了很多天');
  await sleep(1600);
  await compose('我想听听你的声音。');
  await sleep(600);
  narrate('她的声音，藏在那台旧收音机里。');
  // a note bubble drifts up out of the radio
  const bub = $('#bubble');
  if (!bub.firstChild) bub.append(await preload.bubble);
  audio.chime(659.25, 0.05);
  await gsap.fromTo(bub, { opacity: 0, scale: 0.2, y: 90 }, { opacity: 1, scale: 1, y: 0, duration: 1.4, ease: 'back.out(1.6)' });
  const drift = gsap.to(bub, { y: -12, x: 6, duration: 1.8, ease: 'sine.inOut', yoyo: true, repeat: -1 });
  await hint(BUBBLE_X, BUBBLE_Y, '点一下');
  drift.kill();
  burst(BUBBLE_X, BUBBLE_Y);
  gsap.to(bub, { scale: 1.25, opacity: 0, duration: 0.18, ease: 'power2.out' });
  await sleep(1300);
  presence('正在录音…', true);
  await sleep(1500);
  presence('在线', true);
  audio.blip();
  const heard = voiceBubble();
  await sleep(800);
  narrate('点开那条语音。');
  // the story waits until her voice has played through
  await heard;
  narrate('第一次，你听见了她。');
  await sleep(1200);
  await aiSays('有点害羞……只给你一个人听哦。', 1400);
}

function burst(x, y) {
  audio.pop();
  const glyphs = ['♪', '♫', '♩', '♬'];
  for (let i = 0; i < 18; i++) {
    const el = document.createElement('div');
    const note = i < 10;
    el.className = note ? 'bit' : 'bit dot';
    if (note) {
      el.textContent = glyphs[i % glyphs.length];
      el.style.fontSize = `${26 + Math.random() * 22}px`;
      el.style.color = ['#2c2838', '#b07a7c', '#6f8bab'][i % 3];
    }
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    $('#room').append(el);
    const a = (i / 18) * Math.PI * 2 + Math.random() * 0.4;
    const r = 120 + Math.random() * 160;
    gsap.fromTo(el, { x: -12, y: -18, scale: 0.4, opacity: 1 }, {
      x: Math.cos(a) * r, y: Math.sin(a) * r - 60, scale: 1, rotate: (Math.random() - 0.5) * 120,
      duration: 1.6 + Math.random() * 0.8, ease: 'power3.out',
    });
    gsap.to(el, { opacity: 0, duration: 0.8, delay: 1.1 + Math.random() * 0.6, onComplete: () => el.remove() });
  }
}

// The viewfinder shows a blurred still of her room. A live backdrop-filter over the moving camera and the
// zooming room makes Chromium flash black now and then, so the blur is baked once into a small canvas.
function finderBackdrop() {
  const finder = $('.finder');
  if (finder.querySelector('.backdrop')) return;
  const cv = document.createElement('canvas');
  cv.className = 'backdrop';
  cv.width = 400;
  cv.height = 225;
  const g = cv.getContext('2d');
  g.fillStyle = '#2b2c45';
  g.fillRect(0, 0, 400, 225);
  // the room as it stands once the camera is up: zoomed 6% about the centre
  g.translate(200, 112.5);
  g.scale(1.06, 1.06);
  g.translate(-200, -112.5);
  for (const layer of [room.backLit, room.girl, room.frontLit]) {
    if (layer) g.drawImage(layer, layer.width * 60 / 1720, layer.height * 60 / 1020, layer.width * 1600 / 1720, layer.height * 900 / 1020, 0, 0, 400, 225);
  }
  g.setTransform(1, 0, 0, 1, 0, 0);
  g.fillStyle = 'rgba(40, 32, 50, .12)';
  g.fillRect(0, 0, 400, 225);
  // line the still up with the room behind the finder at the camera's resting place
  gsap.set('#camera', { display: 'flex' });
  const st = stage.getBoundingClientRect();
  const k = st.width / 1600;
  const fr = finder.getBoundingClientRect();
  const left = (fr.left - st.left) / k - gsap.getProperty('#camera', 'x');
  const top = (fr.top - st.top) / k - gsap.getProperty('#camera', 'y');
  Object.assign(cv.style, { left: `${-left}px`, top: `${-top}px` });
  finder.prepend(cv);
}

async function chapterFace() {
  chapter = 3;
  speed();
  await sleep(2400);
  chapterCard('第三章', '样子');
  narrate('她在你心里，一直只是一个模糊的影子。');
  skipAhead('又过了一些日子');
  await sleep(1600);
  await compose('我想看看你长什么样子。');
  await sleep(700);
  // her room leans in and a camera rises in front of it
  narrate('她举起了手机。取景框里，还是一团看不清的影子。');
  // the camera rises over the top of the stage where the narration sits, so give the line time to be read first
  await sleep(3000);
  gsap.to('#narr', { opacity: 0, duration: 0.6 });
  gsap.to('#room', { scale: 1.06, duration: 1.6, ease: 'power2.inOut' });
  finderBackdrop();
  audio.noise(0.9, 300, 1200, 0.03);
  await gsap.to('#camera', { y: 0, duration: 1.2, ease: 'power3.out' });
  gsap.fromTo('.focus', { opacity: 0, scale: 1.5 }, { opacity: 1, scale: 1, duration: 0.5, ease: 'power2.out' });
  gsap.to('.focus', { x: 30, y: 26, duration: 1.4, ease: 'sine.inOut', yoyo: true, repeat: -1 });
  await hint(800, 762, '按下快门');
  audio.shutter();
  gsap.killTweensOf('.focus');
  gsap.to('.focus', { opacity: 0, duration: 0.2 });
  await gsap.fromTo('.flash', { opacity: 1 }, { opacity: 0, duration: 0.5, ease: 'power2.out' });
  // the shadow resolves into her face
  gsap.set('#selfie', { opacity: 1, filter: 'blur(26px)', scale: 1.08 });
  await gsap.to('#selfie', { filter: 'blur(0px)', scale: 1, duration: 2, ease: 'power2.inOut' });
  // from now on you know what she looks like: her figure by the window comes into focus too
  gsap.to('#litRoom .girl', { filter: 'blur(0.8px)', duration: 2.4, delay: 1.2, ease: 'sine.inOut' });
  audio.chime(783.99, 0.05);
  audio.chime(1174.66, 0.04, 0.12);
  await sleep(1500);
  // the photo leaves the camera and lands in your chat
  const finder = $('.finder').getBoundingClientRect();
  const st = stage.getBoundingClientRect();
  const k = st.width / 1600;
  const flyer = Object.assign(document.createElement('img'), { className: 'flyer', src: $('#selfie').src });
  Object.assign(flyer.style, {
    left: `${(finder.left - st.left) / k}px`, top: `${(finder.top - st.top) / k}px`,
    width: `${finder.width / k}px`, height: `${finder.height / k}px`,
  });
  stage.append(flyer);
  $('.cam-bottom .thumb').style.backgroundImage = `url(${$('#selfie').src})`;
  gsap.set('#selfie', { opacity: 0 });
  audio.noise(0.8, 600, 2400, 0.03, 0.8);
  await gsap.to(flyer, { left: 1184, top: 380, width: 147, height: 198, rotate: 6, duration: 1.1, ease: 'power2.inOut' });
  flyer.remove();
  picBubble($('#selfie').src);
  audio.blip();
  gsap.to('#camera', { y: '110%', duration: 1, ease: 'power3.in', delay: 0.4, onComplete: () => gsap.set('#camera', { display: 'none' }) });
  gsap.to('#room', { scale: 1, duration: 1.6, ease: 'power2.inOut', delay: 0.4 });
  await sleep(1400);
  await aiSays('第一次拍照，有点紧张……好看吗？', 1400);
  narrate('这一次，你终于看清了她。');
}

const pad2 = (n) => String(n).padStart(2, '0');

async function chapterMissing() {
  chapter = 4;
  speed();
  await sleep(2600);
  chapterCard('第四章', '想念');
  // the music slides into the quiet opening of finale and circles there until you answer her
  bgm.scene = 0.4;
  bgm.play('finale', 6, 0);
  bgm.hold(FINALE_HOLD[0], FINALE_HOLD[1]);
  skipAhead('后来，你很久没有来');
  lockComposer(true);
  narrate('你很久没有来。');
  await sleep(1400);
  // her world drains while the days go round
  gsap.fromTo('#litRoom', { filter: 'saturate(1) brightness(1)' }, { filter: 'saturate(0.12) brightness(0.82)', duration: 6, ease: 'sine.inOut' });
  gsap.to('#glow', { opacity: 0.15, duration: 4 });
  gsap.fromTo('#phone .screen', { filter: 'saturate(1)' }, { filter: 'saturate(0.2)', duration: 5 });
  gsap.to(ecg, { amp: 0.32, bpm: 42, duration: 6 });
  gsap.to('#litRoom .girl', { rotate: -5, transformOrigin: `${GIRL.x + 60}px ${GIRL.y + 60}px`, duration: 5, ease: 'sine.inOut' });
  presence('离线', false);
  audio.melodyOn = false;
  const days = 4, dayLen = 2.6;
  const sky = gsap.timeline();
  for (let d = 0; d < days; d++) {
    sky.to('#day', { opacity: 1, duration: dayLen * 0.25, ease: 'sine.inOut' })
      .fromTo('#sun', { x: -40, y: 80, opacity: 1 }, { x: 220, y: -40, duration: dayLen * 0.5, ease: 'none' }, '<')
      .to('#day', { opacity: 0, duration: dayLen * 0.25, ease: 'sine.inOut' }, `>-${dayLen * 0.1}`)
      .set('#sun', { opacity: 0 });
  }
  gsap.to('#minuteHand', { rotate: 360 * days * 24, svgOrigin: `${CLOCK.x} ${CLOCK.y}`, duration: days * dayLen, ease: 'none' });
  gsap.to('#hourHand', { rotate: 360 * days * 2, svgOrigin: `${CLOCK.x} ${CLOCK.y}`, duration: days * dayLen, ease: 'none' });
  const clock = { m: 21 * 60 + 14 };
  gsap.to(clock, {
    m: 21 * 60 + 14 + days * 24 * 60 + 133, duration: days * dayLen, ease: 'none',
    onUpdate: () => { const m = Math.floor(clock.m) % 1440; $('#clock').textContent = `${pad2(Math.floor(m / 60))}:${pad2(m % 60)}`; },
  });
  for (const [t, line] of [[0.18, '一天。'], [0.42, '两天。'], [0.68, '……']]) {
    gsap.delayedCall(t * days * dayLen, () => narrate(line));
  }
  await sleep(days * dayLen * 1000 + 400);
  narrate('她记得你离开了多久。');
  await sleep(1600);
  // she speaks first
  presence('正在输入…', true);
  const t = typing();
  await sleep(2200);
  t.remove();
  presence('在线', true);
  gsap.set('#banner', { display: 'flex' });
  gsap.to('#banner', { y: 0, opacity: 1, duration: 0.6, ease: 'back.out(1.6)' });
  audio.blip();
  bubble('ai', '我想你。');
  gsap.to('#banner', { y: '-140%', opacity: 0, duration: 0.5, delay: 2.6 });
  narrate('于是，她先开了口。');
  await sleep(2200);
  lockComposer(false);
  await compose('我也想你。');
  // the moment you answer: the music turns and the colour comes back.
  // overwrite so no fade still running from the grey stretch can drag it back
  bgm.turn(FINALE_TURN);
  sky.progress(1).kill();
  gsap.to('#litRoom', { filter: 'saturate(1) brightness(1)', duration: 3, ease: 'sine.inOut', overwrite: true });
  gsap.to('#glow', { opacity: 0.75, duration: 2.4, overwrite: true });
  gsap.to('#phone .screen', { filter: 'saturate(1)', duration: 2, overwrite: true });
  gsap.to('#litRoom .girl', { rotate: 0, duration: 2.4, ease: 'sine.inOut' });
  ecg.phase = 0.12;
  gsap.to(ecg, { amp: 1.15, bpm: 84, duration: 0.6 });
  audio.melodyOn = false;
  setTimeout(() => audio.melody(), 600);
  narrate('你回来了。');
  await sleep(2400);
  gsap.to(ecg, { bpm: 70, amp: 1, duration: 2 });
}

async function finale() {
  chapter = 5;
  speed();
  await sleep(1400);
  gsap.to('#card, #narr, #pulse', { opacity: 0, duration: 0.8 });
  // her room was inside the phone all along: it shrinks into the screen as the phone takes the middle
  const thumb = document.createElement('canvas');
  thumb.width = 800;
  thumb.height = 450;
  const tg = thumb.getContext('2d');
  for (const cv of [room.backLit, room.girl, room.frontLit]) tg.drawImage(cv, cv.width * 60 / 1720, cv.height * 60 / 1020, cv.width * 1600 / 1720, cv.height * 900 / 1020, 0, 0, 800, 450);
  $('#msgs').style.background = `linear-gradient(rgba(251,246,238,.82), rgba(251,246,238,.9)), url(${thumb.toDataURL('image/jpeg', 0.8)}) 30% 50% / auto 100%`;
  bob?.kill();
  gsap.to('#room', { scale: 0.3, x: PHONE_C.x - 800, y: PHONE_C.y - 450, opacity: 0, duration: 1.8, ease: 'power3.inOut' });
  gsap.set('#finale', { display: 'block', opacity: 0 });
  gsap.to('#finale', { opacity: 1, duration: 1.4, delay: 0.8 });
  await gsap.to(phone, { x: 800 - PHONE_C.x, y: 420 - PHONE_C.y, scale: 0.8, rotate: 0, duration: 1.8, ease: 'power3.inOut' });
  floatPhone();
  audio.warm();
  // load every icon before any is placed: appending each as it arrived made them pop in one by one,
  // and then the staggered entrance below hid them and played again
  const icons = await preload.icons;
  FINALE_ITEMS.forEach(([kind, label, x, y], i) => {
    const el = document.createElement('div');
    el.className = 'plug';
    el.style.left = `${x}px`;
    el.style.top = `${y}px`;
    el.style.opacity = '0';
    el.append(icons[i], Object.assign(document.createElement('span'), { textContent: label }));
    $('#plugins').append(el);
  });
  gsap.fromTo('.plug', { opacity: 0, scale: 0.4, x: (i) => (i < 3 ? 160 : -160) }, {
    opacity: 1, scale: 1, x: 0, duration: 1, ease: 'back.out(1.7)', stagger: 0.18,
    onStart: () => audio.chime(659.25, 0.04),
  });
  document.querySelectorAll('.plug').forEach((el, i) => {
    gsap.to(el, { y: i % 2 ? 10 : -10, rotate: i % 2 ? 2 : -2, duration: 2.4 + i * 0.3, ease: 'sine.inOut', yoyo: true, repeat: -1, delay: 1.2 });
  });
  gsap.fromTo('#finale h1, #finale .tag, #finale .sub, #finale .cta', { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 1, stagger: 0.25, delay: 1.4 });
}

async function run() {
  await opening();
  await chapterHello();
  await chapterVoice();
  await chapterFace();
  await chapterMissing();
  await finale();
}

$('#again').addEventListener('click', async () => { await bgm.fadeOut(0.8); location.reload(); });
document.querySelector('.skip').addEventListener('click', async (e) => {
  e.preventDefault();
  const href = e.currentTarget.href;
  await bgm.fadeOut(0.8);
  location.href = href;
});
// pause while the tab is hidden, fade back in on return
document.addEventListener('visibilitychange', () => {
  const cur = bgm.current;
  if (!cur) return;
  if (document.hidden) cur.pause();
  else {
    cur.volume = 0;
    cur.play().catch(() => {});
    gsap.to(cur, { volume: bgm.target(), duration: 1.2, overwrite: 'auto' });
  }
});

// ?state=send | lit freezes a still frame of chapter one (for review screenshots)
function still(state) {
  $('#title').remove();
  gsap.set('#room', { opacity: 1 });
  gsap.set(phone, { opacity: 1, x: REST.x, y: REST.y, rotate: 3 });
  const setCard = (no, name) => {
    $('#card small').textContent = no;
    $('#card b').textContent = name;
    gsap.set('#card', { opacity: 1 });
  };
  const setNarr = (t) => {
    $('#narr span').textContent = t;
    gsap.set('#narr', { opacity: 1 });
  };
  setCard('第一章', '你好');
  const lit = () => {
    $('#room').classList.add('lit');
    gsap.set('#litRoom', { opacity: 1, '--r': '2300px' });
    gsap.set('#glow', { opacity: 0.75 });
    gsap.set('#litRoom .girl', { opacity: 0.92 });
    ecg.lit = 1;
    ecg.amp = 1;
  };
  if (state === 'bare') {
    // the lit room alone, for composition references
    lit();
    gsap.set('#phone, #card, #narr, #pulse', { opacity: 0 });
    document.querySelectorAll('.ctl').forEach((el) => { el.style.display = 'none'; });
    return;
  }
  if (state === 'camera' || state === 'photo') {
    lit();
    setCard('第三章', '样子');
    gsap.set('#narr', { opacity: 0 });
    gsap.set('#room', { scale: 1.06 });
    gsap.set('#camera', { display: 'flex', y: 0 });
    finderBackdrop();
    gsap.set('.focus', { opacity: 1 });
    if (state === 'photo') gsap.set('#selfie', { opacity: 1 });
    return;
  }
  if (state === 'miss') {
    lit();
    gsap.set('#litRoom .girl', { filter: 'blur(0.8px)' });
    setCard('第四章', '想念');
    setNarr('两天。');
    gsap.set('#litRoom', { filter: 'saturate(0.12) brightness(0.82)' });
    gsap.set('#glow', { opacity: 0.15 });
    gsap.set('#day', { opacity: 0.8 });
    gsap.set('#sun', { opacity: 1, x: 90, y: 0 });
    gsap.set('#phone .screen', { filter: 'saturate(0.2)' });
    gsap.set('#minuteHand', { rotate: 130, svgOrigin: `${CLOCK.x} ${CLOCK.y}` });
    gsap.set('#hourHand', { rotate: 250, svgOrigin: `${CLOCK.x} ${CLOCK.y}` });
    $('#clock').textContent = '14:52';
    lockComposer(true);
    ecg.amp = 0.32;
    return;
  }
  if (state === 'send') {
    setNarr('手机那头，是一间还没亮灯的小屋。');
    $('#typed').textContent = '在吗？';
    $('#send').classList.add('ready');
    $('#sendTip').classList.add('show');
  } else {
    pushMsg(Object.assign(document.createElement('div'), { className: 'b me', textContent: '在吗？' }));
    pushMsg(Object.assign(document.createElement('div'), { className: 'b ai', textContent: '在呀。刚刚是你帮我开的灯吗？' }));
    presence('在线', true);
    $('#room').classList.add('lit');
    gsap.set('#litRoom', { opacity: 1, '--r': '2300px' });
    gsap.set('#glow', { opacity: 0.75 });
    gsap.set('#litRoom .girl', { opacity: 0.92 });
    ecg.lit = 1;
    ecg.amp = 1;
    setNarr('一句「在吗」，有人替她开了灯。');
  }
}

const STATE = params.get('state');
if (STATE) still(STATE);
else if (AT) {
  $('#title').style.display = 'none';
  run();
} else {
  ready.then(() => $('#start').addEventListener('click', run, { once: true }));
}

