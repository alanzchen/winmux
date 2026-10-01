// Small deterministic DSP toolkit for the WinMux intro score. No samples, no dependencies.
export const SR = 48000;

// Seeded PRNG (mulberry32) so every render is bit-identical.
export function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a |= 0; a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const mtof = (m) => 440 * Math.pow(2, (m - 69) / 12);
export const dbToGain = (db) => Math.pow(10, db / 20);
export const clamp = (x, lo, hi) => (x < lo ? lo : x > hi ? hi : x);

export class Bus {
  constructor(seconds) {
    this.n = Math.ceil(seconds * SR);
    this.L = new Float32Array(this.n);
    this.R = new Float32Array(this.n);
  }
  add(i, l, r) { if (i >= 0 && i < this.n) { this.L[i] += l; this.R[i] += r; } }
  mixInto(dst, gain = 1) {
    for (let i = 0; i < this.n; i++) { dst.L[i] += this.L[i] * gain; dst.R[i] += this.R[i] * gain; }
  }
}

// Equal-power pan: p in [-1, 1].
export function panGains(p) {
  const a = (clamp(p, -1, 1) + 1) * Math.PI / 4;
  return [Math.cos(a), Math.sin(a)];
}

// RBJ biquad. Coefficients can be retuned per block for sweeps.
export class Biquad {
  constructor(type, freq, q = 0.707, gainDb = 0) { this.type = type; this.z1 = 0; this.z2 = 0; this.set(freq, q, gainDb); }
  set(freq, q = this.q, gainDb = this.gainDb) {
    this.q = q; this.gainDb = gainDb;
    const f = clamp(freq, 10, SR * 0.45);
    const w = 2 * Math.PI * f / SR, cw = Math.cos(w), sw = Math.sin(w);
    const alpha = sw / (2 * q), A = Math.pow(10, gainDb / 40);
    let b0, b1, b2, a0, a1, a2;
    switch (this.type) {
      case 'lp': b0 = (1 - cw) / 2; b1 = 1 - cw; b2 = (1 - cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
      case 'hp': b0 = (1 + cw) / 2; b1 = -(1 + cw); b2 = (1 + cw) / 2; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
      case 'bp': b0 = alpha; b1 = 0; b2 = -alpha; a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha; break;
      case 'peak': b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A; a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A; break;
      case 'lowshelf': {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * ((A + 1) - (A - 1) * cw + s); b1 = 2 * A * ((A - 1) - (A + 1) * cw); b2 = A * ((A + 1) - (A - 1) * cw - s);
        a0 = (A + 1) + (A - 1) * cw + s; a1 = -2 * ((A - 1) + (A + 1) * cw); a2 = (A + 1) + (A - 1) * cw - s; break;
      }
      case 'highshelf': {
        const s = 2 * Math.sqrt(A) * alpha;
        b0 = A * ((A + 1) + (A - 1) * cw + s); b1 = -2 * A * ((A - 1) + (A + 1) * cw); b2 = A * ((A + 1) + (A - 1) * cw - s);
        a0 = (A + 1) - (A - 1) * cw + s; a1 = 2 * ((A - 1) - (A + 1) * cw); a2 = (A + 1) - (A - 1) * cw - s; break;
      }
      default: throw new Error('biquad type ' + this.type);
    }
    this.b0 = b0 / a0; this.b1 = b1 / a0; this.b2 = b2 / a0; this.a1 = a1 / a0; this.a2 = a2 / a0;
  }
  // Transposed direct form II.
  process(x) {
    const y = this.b0 * x + this.z1;
    this.z1 = this.b1 * x - this.a1 * y + this.z2;
    this.z2 = this.b2 * x - this.a2 * y;
    return y;
  }
}

// PolyBLEP band-limited saw.
export function polyBlep(t, dt) {
  if (t < dt) { t /= dt; return t + t - t * t - 1; }
  if (t > 1 - dt) { t = (t - 1) / dt; return t * t + t + t + 1; }
  return 0;
}

export class Freeverb {
  // Classic Jezar Freeverb tunings at 44.1k, scaled to 48k.
  constructor({ room = 0.84, damp = 0.25, spread = 23 } = {}) {
    const scale = SR / 44100;
    const combs = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
    const aps = [556, 441, 341, 225];
    const mk = (len) => ({ buf: new Float32Array(Math.round(len * scale)), i: 0, store: 0 });
    this.cl = combs.map(mk); this.cr = combs.map((l) => mk(l + spread));
    this.al = aps.map(mk); this.ar = aps.map((l) => mk(l + spread));
    this.feedback = room; this.damp = damp;
  }
  comb(c, x) {
    const out = c.buf[c.i];
    c.store = out * (1 - this.damp) + c.store * this.damp;
    c.buf[c.i] = x + c.store * this.feedback;
    if (++c.i >= c.buf.length) c.i = 0;
    return out;
  }
  allpass(a, x) {
    const b = a.buf[a.i];
    const out = -x + b;
    a.buf[a.i] = x + b * 0.5;
    if (++a.i >= a.buf.length) a.i = 0;
    return out;
  }
  // Process a send bus into a return bus (wet only).
  run(src, dst, wet = 1) {
    const g = 0.015;
    for (let i = 0; i < src.n; i++) {
      const x = (src.L[i] + src.R[i]) * g;
      let l = 0, r = 0;
      for (let k = 0; k < 8; k++) { l += this.comb(this.cl[k], x); r += this.comb(this.cr[k], x); }
      for (let k = 0; k < 4; k++) { l = this.allpass(this.al[k], l); r = this.allpass(this.ar[k], r); }
      dst.L[i] += l * wet; dst.R[i] += r * wet;
    }
  }
}

// Stereo ping-pong delay with a low-pass in the loop.
export function pingPong(src, dst, { time = 0.375, feedback = 0.35, wet = 0.5, lp = 4500 } = {}) {
  const d = Math.round(time * SR);
  const bl = new Float32Array(d), br = new Float32Array(d);
  const fl = new Biquad('lp', lp), fr = new Biquad('lp', lp);
  let idx = 0;
  for (let i = 0; i < src.n; i++) {
    const outL = bl[idx], outR = br[idx];
    const inMono = (src.L[i] + src.R[i]) * 0.5;
    bl[idx] = fl.process(inMono + outR * feedback);
    br[idx] = fr.process(outL * feedback);
    if (++idx >= d) idx = 0;
    dst.L[i] += outL * wet; dst.R[i] += outR * wet;
  }
}

export function writeWav24(path, L, R, fs) {
  const n = L.length, ch = R ? 2 : 1;
  const data = Buffer.alloc(n * ch * 3);
  let o = 0;
  const put = (v) => {
    let s = Math.round(clamp(v, -1, 1) * 8388607);
    if (s < 0) s += 16777216;
    data[o++] = s & 255; data[o++] = (s >> 8) & 255; data[o++] = (s >> 16) & 255;
  };
  for (let i = 0; i < n; i++) { put(L[i]); if (R) put(R[i]); }
  const h = Buffer.alloc(44);
  h.write('RIFF', 0); h.writeUInt32LE(36 + data.length, 4); h.write('WAVE', 8);
  h.write('fmt ', 12); h.writeUInt32LE(16, 16); h.writeUInt16LE(1, 20); h.writeUInt16LE(ch, 22);
  h.writeUInt32LE(fs, 24); h.writeUInt32LE(fs * ch * 3, 28); h.writeUInt16LE(ch * 3, 32); h.writeUInt16LE(24, 34);
  h.write('data', 36); h.writeUInt32LE(data.length, 40);
  return import('node:fs').then((fsm) => fsm.writeFileSync(path, Buffer.concat([h, data])));
}

// Minimal WAV reader: PCM 16/24/32-bit int or 32-bit float, any channel count. Returns float channels.
export function readWav(buf) {
  if (buf.toString('ascii', 0, 4) !== 'RIFF' || buf.toString('ascii', 8, 12) !== 'WAVE') throw new Error('not a WAV');
  let p = 12, fmt = null, data = null;
  while (p + 8 <= buf.length) {
    const id = buf.toString('ascii', p, p + 4), len = buf.readUInt32LE(p + 4);
    if (id === 'fmt ') {
      fmt = { format: buf.readUInt16LE(p + 8), ch: buf.readUInt16LE(p + 10), fs: buf.readUInt32LE(p + 12), bits: buf.readUInt16LE(p + 22) };
      // WAVE_FORMAT_EXTENSIBLE: the real format is the first two bytes of the SubFormat GUID.
      if (fmt.format === 0xfffe && len >= 40) fmt.format = buf.readUInt16LE(p + 8 + 24);
    }
    if (id === 'data') { data = buf.subarray(p + 8, p + 8 + len); break; }
    p += 8 + len + (len & 1);
  }
  if (!fmt || !data) throw new Error('bad WAV');
  const format = fmt.format;
  const bps = fmt.bits / 8, frames = Math.floor(data.length / (bps * fmt.ch));
  const chans = Array.from({ length: fmt.ch }, () => new Float32Array(frames));
  for (let i = 0; i < frames; i++) {
    for (let c = 0; c < fmt.ch; c++) {
      const o = (i * fmt.ch + c) * bps;
      let v;
      if (format === 3 && bps === 4) v = data.readFloatLE(o);
      else if (bps === 2) v = data.readInt16LE(o) / 32768;
      else if (bps === 3) { let s = data[o] | (data[o + 1] << 8) | (data[o + 2] << 16); if (s & 0x800000) s -= 0x1000000; v = s / 8388608; }
      else if (bps === 4) v = data.readInt32LE(o) / 2147483648;
      else throw new Error('unsupported bits ' + fmt.bits);
      chans[c][i] = v;
    }
  }
  return { fs: fmt.fs, channels: chans, frames };
}

// Lookahead brickwall limiter (O(n)), no signal delay. mn[i] = min(req[i..i+la]) anticipates peaks;
// the gain is the moving average of mn over [i-la+1, i]. Every term of that window covers sample i
// (k <= i <= k+la), so gain[i] <= req[i] and |out| <= ceiling, with a smooth la-sample attack.
// chans: array of Float32Array (1 or 2 channels), processed in place. Returns the max reduction in dB.
export function limit(chans, ceiling, { lookahead = 0.005, release = 0.08 } = {}) {
  const n = chans[0].length, la = Math.max(1, Math.round(lookahead * SR));
  const req = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    let p = 0; for (const c of chans) p = Math.max(p, Math.abs(c[i]));
    req[i] = p > ceiling ? ceiling / p : 1;
  }
  const mn = new Float32Array(n), dq = new Int32Array(n + 1);
  let head = 0, tail = 0;
  for (let j = 0; j < n + la; j++) {
    if (j < n) { while (tail > head && req[dq[tail - 1]] >= req[j]) tail--; dq[tail++] = j; }
    const i = j - la;
    if (i >= 0) { while (dq[head] < i) head++; mn[i] = req[dq[head]]; }
  }
  // Release: the gain may only rise slowly; it can always drop to mn (which keeps g <= mn).
  const rel = Math.exp(-1 / (release * SR));
  let g = 1;
  for (let i = 0; i < n; i++) { const up = g * rel + (1 - rel); g = Math.min(mn[i], up); mn[i] = g; }
  let sum = 0, minRed = 1;
  const gs = new Float32Array(n);
  for (let i = 0; i < n; i++) {
    sum += mn[i]; if (i >= la) sum -= mn[i - la];
    // Before la samples exist, average what there is padded with 1s (unity gain history).
    gs[i] = i >= la - 1 ? sum / la : (sum + (la - 1 - i)) / la;
    if (gs[i] < minRed) minRed = gs[i];
  }
  for (const c of chans) for (let i = 0; i < n; i++) c[i] *= gs[i];
  return 20 * Math.log10(minRed);
}
