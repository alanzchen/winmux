// Beat/A-V sync spot check at the choreography accents, measured on the delivered MP4:
// - audio onset: largest rise in 5 ms log-energy within +/-80 ms of the accent (decoded from the MP4)
// - visual onset: first frame whose frame-to-frame change exceeds 35% of the local maximum, within
//   [accent - 0.25 s, accent + 0.35 s] (160x90 grayscale decode)
// Usage: node scripts/qc/sync.mjs <film.mp4> > sync.json
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { ROOT as root } from '../paths.mjs';
const mp4 = process.argv[2];
const beats = JSON.parse(fs.readFileSync(path.join(root, 'cues/beats.json'), 'utf8'));
const T = (bar, beat) => (bar * 4 + beat) * 60 / beats.bpm;
const accents = beats.accents.filter((a) => a.strength >= 0.5).map((a) => ({ id: a.id, t: T(a.bar, a.beat), strength: a.strength }));

// Audio: decode the whole track once to mono float at 48 kHz.
const pcm = execFileSync('ffmpeg', ['-v', 'error', '-i', mp4, '-map', '0:a:0', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'], { maxBuffer: 1 << 30 });
const x = new Float32Array(pcm.buffer, pcm.byteOffset, pcm.length / 4);
const hop = 240; // 5 ms
const env = [];
for (let i = 0; i + hop <= x.length; i += hop) { let s = 0; for (let k = 0; k < hop; k++) s += x[i + k] * x[i + k]; env.push(10 * Math.log10(s / hop + 1e-10)); }
function audioOnset(t) {
  const c = Math.round(t / 0.005), w = 16;
  let best = { d: -1e9, at: c };
  for (let f = c - w; f <= c + w; f++) { const d = env[f] - env[f - 2]; if (d > best.d) best = { d, at: f }; }
  return { offsetMs: Math.round((best.at * 0.005 - t) * 1000), riseDb: +best.d.toFixed(1) };
}

// Video: decode a short window per accent.
function visualOnset(t) {
  const t0 = Math.max(0, t - 0.25), dur = 0.6;
  const raw = execFileSync('ffmpeg', ['-v', 'error', '-ss', t0.toFixed(3), '-i', mp4, '-t', String(dur), '-vf', 'scale=160:90,format=gray', '-f', 'rawvideo', '-'], { maxBuffer: 1 << 28 });
  const n = Math.floor(raw.length / (160 * 90));
  const diffs = [];
  for (let f = 1; f < n; f++) {
    let s = 0; for (let i = 0; i < 160 * 90; i++) s += Math.abs(raw[f * 14400 + i] - raw[(f - 1) * 14400 + i]);
    diffs.push(s / 14400);
  }
  const max = Math.max(...diffs);
  const idx = diffs.findIndex((d) => d >= 0.35 * max);
  const onset = t0 + (idx + 1) / 60;
  return { offsetMs: Math.round((onset - t) * 1000), peakChange: +max.toFixed(2) };
}

const rows = accents.map((a) => ({ ...a, audio: audioOnset(a.t), video: visualOnset(a.t) }));
const within = (ms, lim) => Math.abs(ms) <= lim;
const summary = {
  accentsChecked: rows.length,
  audioWithin20ms: rows.filter((r) => within(r.audio.offsetMs, 20)).length,
  videoWithin100ms: rows.filter((r) => within(r.video.offsetMs, 100)).length,
};
console.log(JSON.stringify({ file: mp4, summary, rows }, null, 2));
