// Original score for the WinMux intro, synthesized from cues/beats.json (tempo, chords, sections,
// accents) and cues/narration.json (the motif stays out from under the voice).
// Output: $PROMO_BUILD_DIR/music-score.wav (48 kHz, 24-bit stereo) and music-events.json beside it.
// Deterministic: a fixed seed, no samples, no network.
import fs from 'node:fs';
import path from 'node:path';
import { SR, rng, mtof, clamp, Bus, Biquad, polyBlep, Freeverb, pingPong, panGains, writeWav24 } from './dsp.mjs';
import { ROOT as root, BUILD } from '../paths.mjs';
const beats = JSON.parse(fs.readFileSync(path.join(root, 'cues/beats.json'), 'utf8'));
const narration = JSON.parse(fs.readFileSync(path.join(root, 'cues/narration.json'), 'utf8'));
const SPB = 60 / beats.bpm;             // seconds per beat
const T = (bar, beat = 0) => (bar * 4 + beat) * SPB;
const DUR = beats.durationSec;
const rand = rng(0x57a11);
const noise = () => rand() * 2 - 1;

const buses = {
  drums: new Bus(DUR), bass: new Bus(DUR), pad: new Bus(DUR), keys: new Bus(DUR),
  bell: new Bus(DUR), fx: new Bus(DUR), verbSend: new Bus(DUR), delaySend: new Bus(DUR),
};
const events = [];
const log = (t, kind, detail) => events.push({ t: +t.toFixed(4), kind, ...detail });

// ---------- harmony ----------
const VOICINGS = {
  'Bm(add9)': [54, 59, 62, 66, 73], 'G': [55, 59, 62, 67], 'Em7': [55, 59, 62, 64], 'F#sus4': [54, 59, 61, 66],
  'F#': [54, 58, 61, 66], 'D': [54, 57, 62, 66], 'A/C#': [52, 57, 61, 64], 'Bm7': [57, 59, 62, 66],
  'Gmaj7': [55, 59, 62, 66], 'A': [52, 57, 61, 64], 'Asus4': [52, 57, 62, 64], 'F#m7': [54, 57, 61, 64],
  'D/F#': [54, 57, 62, 66], 'A7sus4': [55, 57, 62, 64], 'D(add9)': [57, 62, 64, 66, 69], 'G/D': [55, 59, 62, 67],
};
const BASS = {
  'Bm(add9)': 35, 'G': 43, 'Em7': 40, 'F#sus4': 42, 'F#': 42, 'D': 38, 'A/C#': 37, 'Bm7': 35, 'Gmaj7': 43,
  'A': 33, 'Asus4': 33, 'F#m7': 42, 'D/F#': 42, 'A7sus4': 33, 'D(add9)': 38, 'G/D': 38,
};
const chords = [...beats.chords].sort((a, b) => a.bar - b.bar);
function chordAt(barPos) {
  let c = chords[0];
  for (const x of chords) if (x.bar <= barPos + 1e-9) c = x;
  if (!VOICINGS[c.chord]) throw new Error('no voicing for ' + c.chord);
  return c.chord;
}
const barPosOf = (t) => t / (4 * SPB);
const sectionAt = (t) => beats.sections.find((s) => barPosOf(t) >= s.startBar && barPosOf(t) < s.endBar)?.id ?? 'endcard';
const voWindows = narration.lines.map((l) => [l.start, l.maxEnd]);
const underVO = (t, pad = 0.1) => voWindows.some(([a, b]) => t >= a - pad && t <= b + pad);

// ---------- instruments ----------
function kick(t, vel = 0.8) {
  const n = Math.round(0.55 * SR), i0 = Math.round(t * SR);
  let ph = 0;
  const hp = new Biquad('hp', 2500);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const f = 43 + 115 * Math.exp(-tt / 0.042);
    ph += 2 * Math.PI * f / SR;
    const body = Math.sin(ph) * Math.exp(-tt / 0.30) * (tt < 0.002 ? tt / 0.002 : 1);
    const click = hp.process(noise()) * Math.exp(-tt / 0.0035) * 0.35;
    const x = Math.tanh(1.6 * (body + click)) * vel * 0.85;
    buses.drums.add(i0 + i, x, x);
  }
  log(t, 'kick', { vel });
}
function clap(t, vel = 0.5, pan = 0) {
  const n = Math.round(0.35 * SR), i0 = Math.round(t * SR);
  const bp = new Biquad('bp', 1350, 0.9), hp = new Biquad('hp', 650);
  const [gl, gr] = panGains(pan);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    let e = 0;
    for (const o of [0, 0.0095, 0.019]) if (tt >= o) e = Math.max(e, Math.exp(-(tt - o) / 0.0045));
    if (tt >= 0.019) e = Math.max(e, 0.55 * Math.exp(-(tt - 0.019) / 0.13));
    const x = hp.process(bp.process(noise())) * e * vel * 1.6;
    buses.drums.add(i0 + i, x * gl, x * gr);
    buses.verbSend.add(i0 + i, x * 0.35, x * 0.35);
  }
}
function snare(t, vel = 0.5) {
  const n = Math.round(0.25 * SR), i0 = Math.round(t * SR);
  const bp = new Biquad('bp', 1900, 0.7);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    ph += 2 * Math.PI * 188 / SR;
    const x = (bp.process(noise()) * Math.exp(-tt / 0.11) * 1.3 + Math.sin(ph) * Math.exp(-tt / 0.05) * 0.5) * vel;
    buses.drums.add(i0 + i, x, x);
    buses.verbSend.add(i0 + i, x * 0.2, x * 0.2);
  }
}
function hat(t, vel = 0.12, open = false, pan = 0.15) {
  const len = open ? 0.32 : 0.06, n = Math.round(len * SR), i0 = Math.round(t * SR);
  const hp = new Biquad('hp', 7800, 0.7), pk = new Biquad('peak', 10500, 1.2, 4);
  const [gl, gr] = panGains(pan);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const x = pk.process(hp.process(noise())) * Math.exp(-tt / (open ? 0.1 : 0.022)) * vel;
    buses.drums.add(i0 + i, x * gl, x * gr);
  }
}
function shaker(t, vel = 0.05, pan = -0.3) {
  const n = Math.round(0.09 * SR), i0 = Math.round(t * SR);
  const hp = new Biquad('hp', 5200), bp = new Biquad('bp', 8200, 1.1);
  const [gl, gr] = panGains(pan);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const env = Math.min(1, tt / 0.012) * Math.exp(-tt / 0.03);
    const x = bp.process(hp.process(noise())) * env * vel * 2;
    buses.drums.add(i0 + i, x * gl, x * gr);
  }
}
function tom(t, f0 = 110, vel = 0.5, pan = 0) {
  const n = Math.round(0.4 * SR), i0 = Math.round(t * SR);
  let ph = 0;
  const [gl, gr] = panGains(pan);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    ph += 2 * Math.PI * (f0 + f0 * 0.7 * Math.exp(-tt / 0.03)) / SR;
    const x = Math.tanh(Math.sin(ph) * Math.exp(-tt / 0.22) * 1.4) * vel * 0.7;
    buses.drums.add(i0 + i, x * gl, x * gr);
    buses.verbSend.add(i0 + i, x * 0.15 * gl, x * 0.15 * gr);
  }
}
function crashBuffer(len, vel) {
  const n = Math.round(len * SR);
  const L = new Float32Array(n), R = new Float32Array(n);
  const hl = new Biquad('hp', 4200), hr = new Biquad('hp', 4200);
  const partials = [3170, 4230, 5390, 6710, 7990, 9420].map((f) => ({ f, ph: rand() * 6.28 }));
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const env = Math.exp(-tt / (len / 4.2)) * Math.min(1, tt / 0.002);
    let metal = 0;
    for (const p of partials) { p.ph += 2 * Math.PI * p.f / SR; metal += Math.sin(p.ph); }
    L[i] = (hl.process(noise()) * 0.9 + metal * 0.025) * env * vel;
    R[i] = (hr.process(noise()) * 0.9 + metal * 0.025) * env * vel;
  }
  return [L, R];
}
function crash(t, vel = 0.35, len = 2.4) {
  const [L, R] = crashBuffer(len, vel), i0 = Math.round(t * SR);
  for (let i = 0; i < L.length; i++) { buses.drums.add(i0 + i, L[i], R[i]); buses.verbSend.add(i0 + i, L[i] * 0.3, R[i] * 0.3); }
  log(t, 'crash', { vel });
}
function reverseCrash(tEnd, len = 1.5, vel = 0.3) {
  const [L, R] = crashBuffer(len, vel), n = L.length, i0 = Math.round(tEnd * SR) - n;
  for (let i = 0; i < n; i++) { const k = n - 1 - i; buses.fx.add(i0 + i, L[k], R[k]); }
}
function boom(t, vel = 0.7, len = 1.6) {
  const n = Math.round(len * SR), i0 = Math.round(t * SR);
  let ph = 0;
  const lp = new Biquad('lp', 900);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    ph += 2 * Math.PI * (30 + 34 * Math.exp(-tt / 0.35)) / SR;
    const sub = Math.sin(ph) * Math.exp(-tt / (len * 0.55)) * Math.min(1, tt / 0.004);
    const burst = lp.process(noise()) * Math.exp(-tt / 0.09) * 0.6;
    const x = Math.tanh((sub + burst) * 1.2) * vel * 0.8;
    buses.fx.add(i0 + i, x, x);
    buses.verbSend.add(i0 + i, burst * vel * 0.4, burst * vel * 0.4);
  }
  log(t, 'boom', { vel });
}
function whoosh(t0, dur, vel = 0.25, dir = 1, panFrom = -0.5, panTo = 0.5) {
  const n = Math.round(dur * SR), i0 = Math.round(t0 * SR);
  const bp = new Biquad('bp', 500, 1.3), bp2 = new Biquad('bp', 500, 1.3);
  for (let i = 0; i < n; i++) {
    const x = i / n;
    if (i % 32 === 0) {
      const f = dir > 0 ? 350 * Math.pow(16, x) : 5600 * Math.pow(1 / 16, x);
      bp.set(f, 1.3); bp2.set(f * 1.5, 1.6);
    }
    const env = Math.pow(Math.sin(Math.PI * x), 1.6);
    const s = (bp.process(noise()) + 0.6 * bp2.process(noise())) * env * vel * 1.4;
    const [gl, gr] = panGains(panFrom + (panTo - panFrom) * x);
    buses.fx.add(i0 + i, s * gl, s * gr);
    buses.verbSend.add(i0 + i, s * 0.25, s * 0.25);
  }
}
function riser(t0, t1, vel = 0.3, fromMidi = 42, toMidi = 66) {
  const n = Math.round((t1 - t0) * SR), i0 = Math.round(t0 * SR);
  const bp = new Biquad('bp', 300, 1.0), lp = new Biquad('lp', 800, 0.9);
  let ph = 0;
  for (let i = 0; i < n; i++) {
    const x = i / n;
    if (i % 32 === 0) { bp.set(300 * Math.pow(24, x), 1.0); lp.set(700 + 5000 * x * x, 0.9); }
    const f = mtof(fromMidi + (toMidi - fromMidi) * x);
    ph += f / SR; if (ph >= 1) ph -= 1;
    const saw = 2 * ph - 1 - polyBlep(ph, f / SR);
    const env = Math.pow(x, 2.2);
    const s = (bp.process(noise()) * 1.2 + lp.process(saw) * 0.35) * env * vel;
    buses.fx.add(i0 + i, s, s);
    buses.verbSend.add(i0 + i, s * 0.3, s * 0.3);
  }
}
// Warm detuned-saw pad. cutoff: number or (t) => Hz.
function padChord(t0, t1, notes, { vel = 1, cutoff = 2600, attack = 0.45, release = 1.2, spread = 0.7 } = {}) {
  const i0 = Math.round(t0 * SR), n = Math.round((t1 - t0 + release) * SR);
  const hold = (t1 - t0);
  notes.forEach((m, k) => {
    const f = mtof(m);
    const detunes = [-11, -5, 0, 6, 12];
    const voices = detunes.map((c, j) => ({ inc: f * Math.pow(2, c / 1200) / SR, ph: rand(), pan: (j / (detunes.length - 1) * 2 - 1) * spread }));
    const lpL = new Biquad('lp', 2000, 0.6), lpR = new Biquad('lp', 2000, 0.6);
    let subPh = rand();
    const amp = 0.028 * vel;
    for (let i = 0; i < n; i++) {
      const tt = i / SR, abs = t0 + tt;
      if (i % 64 === 0) {
        const c = typeof cutoff === 'function' ? cutoff(abs) : cutoff;
        const wob = 1 + 0.08 * Math.sin(2 * Math.PI * 0.13 * abs + k);
        lpL.set(c * wob, 0.6); lpR.set(c * wob * 1.03, 0.6);
      }
      const env = tt < attack ? Math.sin(0.5 * Math.PI * tt / attack) : tt < hold ? 1 : Math.exp(-(tt - hold) / (release / 3.5));
      let l = 0, r = 0;
      for (const v of voices) {
        v.ph += v.inc; if (v.ph >= 1) v.ph -= 1;
        const s = 2 * v.ph - 1 - polyBlep(v.ph, v.inc);
        const [gl, gr] = panGains(v.pan);
        l += s * gl; r += s * gr;
      }
      subPh += f / 2 / SR; if (subPh >= 1) subPh -= 1;
      const sub = k === 0 ? Math.sin(2 * Math.PI * subPh) * 0.12 : 0;
      const L = (lpL.process(l) + sub) * env * amp, R = (lpR.process(r) + sub) * env * amp;
      buses.pad.add(i0 + i, L, R);
      buses.verbSend.add(i0 + i, L * 0.35, R * 0.35);
    }
  });
}
function bassNote(t, dur, m, vel = 0.6, { cutoff = 700, pluck = true } = {}) {
  const f = mtof(m), i0 = Math.round(t * SR), rel = 0.06, n = Math.round((dur + rel) * SR);
  const lp = new Biquad('lp', cutoff, 0.8);
  let ph = rand(), sph = rand();
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    if (i % 32 === 0) lp.set(pluck ? cutoff + 1300 * Math.exp(-tt / 0.07) : cutoff, 0.8);
    ph += f / SR; if (ph >= 1) ph -= 1;
    sph += f / SR; if (sph >= 1) sph -= 1;
    const saw = 2 * ph - 1 - polyBlep(ph, f / SR);
    const env = Math.min(1, tt / 0.006) * (tt < dur ? (pluck ? 0.65 + 0.35 * Math.exp(-tt / 0.12) : 1) : Math.exp(-(tt - dur) / 0.02));
    const x = Math.tanh((lp.process(saw) * 0.6 + Math.sin(2 * Math.PI * sph) * 0.55) * 1.3) * env * vel * 0.42;
    buses.bass.add(i0 + i, x, x);
  }
}
// Tuned additive "glass pluck".
function pluck(t, m, vel = 0.2, pan = 0, decay = 0.5, bus = 'keys', send = 0.25, delay = 0) {
  const f = mtof(m), i0 = Math.round(t * SR), n = Math.round(decay * 5 * SR);
  const parts = [[1, 1, 1], [2, 0.42, 0.55], [3, 0.2, 0.35], [4, 0.1, 0.25], [5.02, 0.05, 0.18]];
  const phs = parts.map(() => rand() * 6.28);
  const [gl, gr] = panGains(pan);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    let s = 0;
    parts.forEach(([h, a, d], k) => { s += Math.sin(phs[k] + 2 * Math.PI * f * h * tt) * a * Math.exp(-tt / (decay * d)); });
    s *= Math.min(1, tt / 0.002) * vel * 0.5;
    buses[bus].add(i0 + i, s * gl, s * gr);
    if (send) buses.verbSend.add(i0 + i, s * send * gl, s * send * gr);
    if (delay) buses.delaySend.add(i0 + i, s * delay, s * delay);
  }
}
// FM glass bell (carrier:modulator 1:2 with a 1:3.5 shimmer partial).
function bell(t, m, vel = 0.25, pan = 0, dur = 2.2, delay = 0.25) {
  const f = mtof(m), i0 = Math.round(t * SR), n = Math.round(dur * SR);
  const [gl, gr] = panGains(pan);
  let pc = rand() * 6.28, pm = 0, ps = 0;
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const idx = 2.6 * Math.exp(-tt / 0.35) + 0.25;
    pm += 2 * Math.PI * f * 2 / SR;
    ps += 2 * Math.PI * f * 3.5 / SR;
    pc += 2 * Math.PI * f / SR;
    const s = (Math.sin(pc + idx * Math.sin(pm)) + 0.12 * Math.sin(ps) * Math.exp(-tt / 0.25))
      * Math.min(1, tt / 0.003) * Math.exp(-tt / (dur / 4.5)) * vel * 0.45;
    buses.bell.add(i0 + i, s * gl, s * gr);
    buses.verbSend.add(i0 + i, s * 0.45 * gl, s * 0.45 * gr);
    if (delay) buses.delaySend.add(i0 + i, s * delay, s * delay);
  }
  log(t, 'bell', { midi: m });
}
function uiClick(t, vel = 0.25) {
  const n = Math.round(0.03 * SR), i0 = Math.round(t * SR);
  const hp = new Biquad('hp', 3000);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const s = (Math.sin(2 * Math.PI * 2400 * tt) * Math.exp(-tt / 0.006) * 0.6 + hp.process(noise()) * Math.exp(-tt / 0.0012)) * vel;
    buses.fx.add(i0 + i, s, s);
  }
}
function sparkle(t, dur = 0.8, vel = 0.08) {
  const n = Math.round(dur * SR), i0 = Math.round(t * SR);
  const hl = new Biquad('hp', 6500), hr = new Biquad('hp', 6500);
  for (let i = 0; i < n; i++) {
    const tt = i / SR;
    const grain = rand() < 0.004 ? 1 : 0;
    const env = Math.exp(-tt / (dur / 3));
    buses.fx.add(i0 + i, hl.process(noise() * (0.15 + grain * 3)) * env * vel, hr.process(noise() * (0.15 + grain * 3)) * env * vel);
  }
}

// ---------- arrangement ----------
const barsTotal = beats.bars;
const kicks = [];
const K = (t, v) => { kick(t, v); kicks.push(t); };
const hum = (amt = 0.06) => 1 + (rand() * 2 - 1) * amt;

// Pads: one chord per chord-change, section-shaped filter and level.
for (let k = 0; k < chords.length; k++) {
  const c = chords[k], next = chords[k + 1];
  const t0 = T(c.bar), t1 = next ? T(next.bar) : DUR - 0.2;
  const sec = sectionAt(t0 + 0.01);
  let vel = 1, cutoff = 2800, attack = 0.45;
  if (sec === 'clutter') { vel = 0.75; cutoff = (t) => 380 + 1900 * Math.pow(clamp(t / T(6), 0, 1), 1.6); attack = t0 === 0 ? 1.4 : 0.3; }
  if (sec === 'calm') { vel = 1.0; cutoff = 2500; attack = c.bar === 6 ? 0.05 : 0.5; }
  if (sec === 'sidebar') { vel = 0.85; cutoff = 3000; }
  if (sec === 'reveal') { vel = 0.9; cutoff = (t) => 1400 + 5200 * clamp((t - T(22)) / (T(24) - T(22)), 0, 1) ** 2; }
  if (sec === 'displays') { vel = 0.9; cutoff = 4200; attack = 0.25; }
  if (sec === 'converge') { vel = 0.95; cutoff = (t) => 2600 + 4000 * clamp((t - T(38)) / (T(39) - T(38)), 0, 1); }
  if (sec === 'endcard') { vel = 1.05; cutoff = 3600; attack = c.bar === 39 ? 0.02 : 0.6; }
  // The bar before the snap breathes: stop the clutter pad a 16th early.
  const end = c.bar === 5.5 ? T(6) - 0.125 : t1;
  padChord(t0, end, VOICINGS[c.chord], { vel, cutoff, attack, release: sec === 'endcard' ? 3.5 : 1.1 });
}

// Clutter (bars 0-5): heartbeat kick, bass pulse, ticking hats, glass pops, riser into the snap.
for (let bar = 1; bar < 6; bar++) {
  for (let e = 0; e < 8; e++) {
    const t = T(bar, e / 2);
    if (t >= T(6) - 0.13) continue;
    const ch = chordAt(bar + e / 8);
    bassNote(t, 0.16, BASS[ch], (0.38 + 0.05 * bar) * hum(), { cutoff: 420 + 90 * bar });
  }
}
for (let bar = 2; bar < 6; bar++) {
  K(T(bar, 0), 0.5 + 0.05 * bar);
  if (bar >= 4) K(T(bar, 2), 0.55);
  for (let s = 0; s < 16; s++) {
    const t = T(bar, s / 4);
    if (t >= T(6) - 0.13) continue;
    hat(t, (s % 2 === 0 ? 0.1 : 0.06) * (0.8 + 0.1 * (bar - 2)) * hum(0.15), false, 0.2);
  }
}
{
  // Each window pop gets a glass pluck on a chord tone, climbing through the section.
  let k = 0;
  for (const p of beats.clutterPops) {
    const t = T(p.bar, p.beat), ch = chordAt(p.bar + p.beat / 4), v = VOICINGS[ch];
    const m = v[k % v.length] + 12 + (k >= 12 ? 12 : 0);
    pluck(t, m, 0.16 + 0.004 * k, (rand() * 2 - 1) * 0.7, 0.35, 'keys', 0.3, 0.15);
    k++;
  }
}
riser(T(5), T(6) - 0.02, 0.32, 42, 66);
reverseCrash(T(6), 1.2, 0.28);

// SNAP (bar 6)
K(T(6), 0.95); boom(T(6), 0.85, 1.8); crash(T(6), 0.34, 2.6);
[62, 66, 69, 76].forEach((m, i) => bell(T(6) + i * 0.018, m, 0.2, (i - 1.5) * 0.3, 2.8, 0.15));
// The WinMux motif (A4 D5 E5 A5) blooms after the hit, before "Meet WinMux".
[[0.5, 69], [0.75, 74], [1.0, 76], [1.25, 81]].forEach(([b, m], i) => bell(T(6, 1) + (b - 0.5) * 2 * SPB, m, 0.22 - (i === 3 ? 0 : 0.03), 0.1 * (i - 1.5), i === 3 ? 3.2 : 1.6, 0.3));

// Calm (bars 7-11): half-time kit, sustained bass, 8th arp from bar 8.
for (let bar = 7; bar < 12; bar++) {
  K(T(bar, 0), 0.6 * hum());
  if (bar !== 11) K(T(bar, 2.5), 0.34 * hum());
  clap(T(bar, 2), 0.36 * hum(), 0.05);
  for (let e = 0; e < 8; e++) hat(T(bar, e / 2) + (e % 2 ? 0.028 : 0), (e % 2 ? 0.055 : 0.085) * hum(0.2), false, 0.25);
  bassNote(T(bar), 1.85, BASS[chordAt(bar)], 0.5, { cutoff: 420, pluck: false });
  if (bar >= 8) {
    const v = VOICINGS[chordAt(bar)].map((m) => m + 12);
    const order = [0, 1, 2, 3, 2, 1, 2, 3];
    for (let e = 0; e < 8; e++) pluck(T(bar, e / 2), v[order[e] % v.length], 0.14 * hum(0.1), e % 2 ? 0.35 : -0.35, 0.4, 'keys', 0.25, 0.22);
  }
}
// Focus hops (bar 11 beats 0,1,2).
[[0, 90], [1, 93], [2, 86]].forEach(([b, m]) => bell(T(11, b), m, 0.09, 0.2, 0.8, 0.1));
reverseCrash(T(12), 0.9, 0.16);

// Sidebar groove (bars 12-21) and displays chorus (bars 24-37).
const grooveBars = [];
for (let bar = 12; bar < 22; bar++) grooveBars.push([bar, 'sidebar']);
for (let bar = 24; bar < 38; bar++) grooveBars.push([bar, 'displays']);
for (const [bar, sec] of grooveBars) {
  const full = sec === 'displays';
  K(T(bar, 0), 0.8 * hum(0.04)); K(T(bar, 1.5), 0.48 * hum()); K(T(bar, 2), 0.72 * hum(0.04));
  if (bar % 2 === 1) K(T(bar, 3.5), 0.3 * hum());
  clap(T(bar, 1), 0.46 * hum(0.08), -0.05); clap(T(bar, 3), 0.5 * hum(0.08), 0.05);
  if (full) { snare(T(bar, 1), 0.18); snare(T(bar, 3), 0.2); }
  const hatDiv = full ? 16 : 8;
  for (let s = 0; s < hatDiv; s++) {
    const b = s * 4 / hatDiv;
    const off = (s % 2 === 1) ? 0.02 : 0;
    hat(T(bar, b) + off, ((s % (hatDiv / 4)) === 0 ? 0.11 : 0.065) * hum(0.2), false, 0.22);
  }
  if (bar % 2 === 0 || full) hat(T(bar, 3.5), 0.07, true, -0.2);
  for (let s = 0; s < 16; s++) shaker(T(bar, s / 4) + (s % 2 ? 0.015 : 0), (s % 4 === 2 ? 0.05 : 0.03) * hum(0.2));
  // Bass
  const ch = chordAt(bar), r = BASS[ch];
  const pattern = full
    ? [[0, 0, 0.3], [0.5, 12, 0.18], [1, 0, 0.2], [1.5, 0, 0.3], [2, 0, 0.3], [2.5, 12, 0.18], [3, 7, 0.2], [3.5, 0, 0.3]]
    : [[0, 0, 0.35], [0.75, 0, 0.2], [1.5, 12, 0.25], [2, 0, 0.35], [2.75, 0, 0.2], [3.5, 7, 0.25]];
  for (const [b, iv, d] of pattern) bassNote(T(bar, b), d, r + iv, (b === 0 || b === 2 ? 0.68 : 0.52) * hum(0.05), { cutoff: full ? 820 : 700 });
  // 16th arp, gentle
  const v = VOICINGS[ch].map((m) => m + 12);
  const order = [0, 1, 2, 3, 1, 2, 3, 2];
  for (let s = 0; s < 16; s++) {
    const m = v[order[s % 8] % v.length] + (s >= 8 && full ? 12 : 0);
    pluck(T(bar, s / 4), m, (full ? 0.1 : 0.085) * (s % 4 === 0 ? 1.25 : 1) * hum(0.12), s % 2 ? 0.45 : -0.45, 0.22, 'keys', 0.2, 0.18);
  }
}

// Reveal build (bars 22-23): drums drop to a quarter/8th kick, snare roll, tom fill, riser, reverse crash.
for (let b = 0; b < 4; b++) K(T(22, b), 0.42 + 0.05 * b);
for (let e = 0; e < 7; e++) K(T(23, e / 2), 0.5 + 0.03 * e);
for (let s = 0; s < 8; s++) snare(T(23, s / 4), 0.1 + 0.02 * s);
for (let s = 0; s < 12; s++) snare(T(23, 2 + s / 8), 0.18 + 0.03 * s);
[[3.5, 150], [3.625, 125], [3.75, 105], [3.875, 88]].forEach(([b, f], i) => tom(T(23, b), f, 0.5 + 0.05 * i, 0.4 - 0.25 * i));
bassNote(T(22), 1.9, BASS['Gmaj7'], 0.5, { cutoff: 380, pluck: false });
riser(T(22), T(24) - 0.01, 0.34, 45, 69);
reverseCrash(T(24), 1.6, 0.3);
// Motif pickup landing on the drop.
[[3, 69], [3.25, 74], [3.5, 76]].forEach(([b, m]) => bell(T(23, b), m, 0.2, 0.1, 1.4, 0.25));
bell(T(24), 81, 0.24, 0, 3.0, 0.3);

// Chorus downbeat and section crashes.
K(T(24), 0.95); boom(T(24), 0.7, 1.4); crash(T(24), 0.36, 2.8);
crash(T(32), 0.2, 2.0); crash(T(36), 0.2, 2.0);

// Converge (bar 38): roll + riser into the logo.
K(T(38), 0.7);
for (let s = 0; s < 16; s++) snare(T(38, s / 4), 0.08 + 0.025 * s);
riser(T(38), T(39) - 0.01, 0.36, 45, 69);
reverseCrash(T(39), 1.5, 0.32);
bassNote(T(38), 1.9, 33, 0.5, { cutoff: 420, pluck: false });
[[3, 69], [3.25, 74], [3.5, 76]].forEach(([b, m]) => bell(T(38, b), m, 0.2, 0.1, 1.2, 0.25));

// LOGO LAND (bar 39) and end card.
K(T(39), 1.0); boom(T(39), 0.95, 2.4); crash(T(39), 0.4, 3.4);
[62, 66, 69, 76, 78].forEach((m, i) => bell(T(39) + i * 0.022, m, 0.2, (i - 2) * 0.3, 4.2, 0.2));
bell(T(39), 78, 0.26, 0, 4.2, 0.3); // motif resolves up to F#5... voiced an octave above for air
bassNote(T(39), 3.6, 26 + 12, 0.62, { cutoff: 380, pluck: false });
{
  const arp = [69, 74, 76, 78, 81, 78, 76, 74];
  for (let e = 0; e < 16; e++) pluck(T(39, 1) + e * SPB / 2, arp[e % 8] + (e >= 8 ? -12 : 0), 0.1 * Math.pow(0.9, e), e % 2 ? 0.4 : -0.4, 0.5, 'keys', 0.35, 0.25);
}
bassNote(T(41), 3.2, 38, 0.5, { cutoff: 360, pluck: false });
[62, 66, 69, 74, 76].forEach((m, i) => bell(T(41) + i * 0.03, m + 12 * (i >= 3 ? 0 : 0), 0.18, (i - 2) * 0.35, 4.5, 0.25));
boom(T(41), 0.4, 2.2);

// ---------- accent FX (from beats.json) ----------
const A = Object.fromEntries(beats.accents.map((a) => [a.id, T(a.bar, a.beat)]));
bell(A['first-window'], 74, 0.12, -0.2, 1.0, 0.2);
bell(A['push-in-land'], 81, 0.12, 0.15, 1.6, 0.25); boom(A['push-in-land'], 0.35, 1.0);
uiClick(A['row-click'], 0.22); bell(A['row-click'], 81, 0.11, 0.2, 0.9, 0.2); bell(A['row-click'] + 0.125, 86, 0.1, 0.25, 1.2, 0.2);
whoosh(A['project-switch'] - 0.28, 0.6, 0.22, 1, -0.6, 0.6);
[74, 78, 81].forEach((m, i) => bell(A['project-switch'] + i * 0.125, m, 0.12, 0.2 * i, 1.2, 0.25));
whoosh(A['project-back'] - 0.28, 0.6, 0.18, -1, 0.6, -0.6);
[81, 78, 74].forEach((m, i) => bell(A['project-back'] + i * 0.125, m, 0.1, -0.2 * i, 1.0, 0.2));
[81, 78, 74].forEach((m, i) => pluck(A['group-collapse'] + i * 0.08, m, 0.16, 0.3 - 0.3 * i, 0.4, 'keys', 0.3, 0.2));
tom(A['group-collapse'], 92, 0.35, 0);
[74, 81, 86, 90].forEach((m, i) => bell(A['pin-land'] + i * 0.025, m, 0.14, (i - 1.5) * 0.25, 2.0, 0.3));
tom(A['pin-land'], 80, 0.32, 0); sparkle(A['pin-land'], 0.9, 0.06);
pluck(A['drag-grab'], 74, 0.12, -0.3, 0.2); pluck(A['drag-grab'] + 0.06, 81, 0.1, -0.3, 0.25);
whoosh(A['rails-in'] - 0.16, 0.34, 0.2, 1, -0.4, 0.1); whoosh(A['rails-in'] - 0.04, 0.34, 0.18, 1, -0.2, 0.3);
bell(A['rails-in'], 76, 0.12, -0.1, 1.4, 0.25); bell(A['rails-in'] + 0.125, 81, 0.12, 0.1, 1.6, 0.25); tom(A['rails-in'], 85, 0.3);
bell(A['rail-hover'], 95, 0.05, 0.1, 0.6, 0.1);
whoosh(A['list-open'] - 0.12, 0.3, 0.14, 1, 0, 0.4); bell(A['list-open'], 81, 0.12, 0.2, 1.4, 0.25); bell(A['list-open'] + 0.06, 88, 0.08, 0.3, 1.2, 0.2);
tom(A['drop'], 72, 0.42, 0.2); boom(A['drop'], 0.3, 0.9); whoosh(A['drop'] - 0.1, 0.25, 0.14, -1, 0, 0.4); bell(A['drop'], 74, 0.12, 0.3, 1.4, 0.25);
bell(A['land-b'], 86, 0.09, 0.5, 1.2, 0.2);
[74, 78, 81, 86, 90].forEach((m, i) => bell(A['share-on'] + i * SPB / 4, m, 0.08 + 0.01 * i, -0.5 + 0.25 * i, 1.4, 0.25));
sparkle(A['share-on'], 1.1, 0.05);
uiClick(A['pin-click'], 0.22);
whoosh(A['pin-click'] + 0.05, A['pin-arrives'] - A['pin-click'] + 0.1, 0.2, 1, 0.65, -0.65);
tom(A['pin-arrives'], 78, 0.38, -0.3); bell(A['pin-arrives'], 78, 0.12, -0.3, 1.6, 0.25);
bell(A['badge-focus'], 100, 0.035, 0.3, 0.7, 0.1);
pluck(A['reorder'], 81, 0.14, -0.2, 0.3); pluck(A['reorder'] + 0.125, 86, 0.13, 0.2, 0.35); tom(A['reorder'], 90, 0.25);

// ---------- mix ----------
// Sidechain from the kicks onto pads and bass (and a touch on keys).
const sc = new Float32Array(buses.pad.n).fill(1);
{
  const ks = [...kicks].sort((a, b) => a - b);
  let k = 0;
  for (let i = 0; i < sc.length; i++) {
    const t = i / SR;
    while (k + 1 < ks.length && ks[k + 1] <= t) k++;
    const dt = t - ks[k];
    if (dt >= 0 && dt < 0.5) sc[i] = 1 - 0.5 * (dt < 0.004 ? dt / 0.004 : Math.exp(-(dt - 0.004) / 0.13));
  }
}
const applySC = (bus, depth) => { for (let i = 0; i < bus.n; i++) { const g = 1 - depth * (1 - sc[i]); bus.L[i] *= g; bus.R[i] *= g; } };
applySC(buses.pad, 0.9); applySC(buses.bass, 0.8); applySC(buses.keys, 0.35);
// Pads leave the low end to the bass and kick.
{
  const hl = new Biquad('hp', 150, 0.7), hr = new Biquad('hp', 150, 0.7);
  for (let i = 0; i < buses.pad.n; i++) { buses.pad.L[i] = hl.process(buses.pad.L[i]); buses.pad.R[i] = hr.process(buses.pad.R[i]); }
}

const master = new Bus(DUR);
const gains = { drums: 0.9, bass: 0.95, pad: 0.8, keys: 0.75, bell: 0.7, fx: 0.8 };
for (const [name, g] of Object.entries(gains)) buses[name].mixInto(master, g);
const ret = new Bus(DUR);
new Freeverb({ room: 0.86, damp: 0.28 }).run(buses.verbSend, ret, 1.0);
pingPong(buses.delaySend, ret, { time: 3 * SPB / 4, feedback: 0.33, wet: 0.35, lp: 4200 });
ret.mixInto(master, 0.5);

// Gentle tone shaping: high-pass rumble, tame harshness.
{
  const hpL = new Biquad('hp', 28, 0.7), hpR = new Biquad('hp', 28, 0.7);
  const hsL = new Biquad('highshelf', 9000, 0.7, -2), hsR = new Biquad('highshelf', 9000, 0.7, -2);
  for (let i = 0; i < master.n; i++) { master.L[i] = hsL.process(hpL.process(master.L[i])); master.R[i] = hsR.process(hpR.process(master.R[i])); }
}
// Glue compressor (RMS, 2:1 above -16 dBFS).
{
  let env = 0;
  const att = Math.exp(-1 / (0.01 * SR)), rel = Math.exp(-1 / (0.15 * SR)), thr = Math.pow(10, -16 / 20);
  for (let i = 0; i < master.n; i++) {
    const x = Math.max(Math.abs(master.L[i]), Math.abs(master.R[i]));
    env = x > env ? att * env + (1 - att) * x : rel * env + (1 - rel) * x;
    const g = env > thr ? Math.pow(env / thr, -0.5) : 1;
    master.L[i] *= g; master.R[i] *= g;
  }
}
// Section automation after the glue compressor: shape the energy arc.
{
  const lvl = (t) => {
    const b = barPosOf(t);
    if (b < 6) return 0.72 + 0.28 * clamp(b / 6, 0, 1);
    if (b < 12) return 0.8;
    if (b < 22) return 0.9;
    if (b < 24) return 0.9 + 0.12 * clamp((b - 22) / 2, 0, 1);
    if (b < 39) return 1.06;
    return 1.08;
  };
  let g = lvl(0);
  const a = 1 - Math.exp(-1 / (0.08 * SR));
  for (let i = 0; i < master.n; i++) { g += (lvl(i / SR) - g) * a; master.L[i] *= g; master.R[i] *= g; }
}
// Final fade 85.0 -> 86.0 s (cosine) and a 5 ms fade-in.
for (let i = 0; i < master.n; i++) {
  const t = i / SR;
  let g = 1;
  if (t < 0.005) g = t / 0.005;
  if (t > A['fade-out']) g = 0.5 * (1 + Math.cos(Math.PI * clamp((t - A['fade-out']) / (DUR - A['fade-out']), 0, 1)));
  master.L[i] *= g; master.R[i] *= g;
}
// Peak-normalize to -3 dBFS (loudness is set later by the mix).
let peak = 0;
for (let i = 0; i < master.n; i++) peak = Math.max(peak, Math.abs(master.L[i]), Math.abs(master.R[i]));
const norm = Math.pow(10, -3 / 20) / peak;
for (let i = 0; i < master.n; i++) { master.L[i] *= norm; master.R[i] *= norm; }

fs.mkdirSync(BUILD, { recursive: true });
await writeWav24(path.join(BUILD, 'music-score.wav'), master.L, master.R, SR);
fs.writeFileSync(path.join(BUILD, 'music-events.json'), JSON.stringify({ kicks: kicks.length, peakBeforeNorm: peak, events: events.slice(0, 2000) }, null, 1));
console.log(`music-score.wav written: ${DUR}s, peak before norm ${peak.toFixed(3)}, kicks ${kicks.length}`);
