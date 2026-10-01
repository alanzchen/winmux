// Mix: music score + narration lines placed UN-stretched at their cue times, music ducked under the
// voice, master limiter, loudness to -16 LUFS integrated with true peak <= -1.5 dBTP.
// Usage: node scripts/mix.mjs final|temp
// Output (final): $PROMO_OUT_DIR/audio/winmux-intro_{mix,vo-stem,music-bed}.wav, music-score_unducked.wav and
// mix-report.json. The optional temp mix goes to $PROMO_BUILD_DIR/audio-temp/.
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { SR, readWav, writeWav24, limit } from './music/dsp.mjs';
import { BUILD, OUT, ROOT as root } from './paths.mjs';
const kind = process.argv[2] ?? 'final';
const beats = JSON.parse(fs.readFileSync(path.join(root, 'cues/beats.json'), 'utf8'));
const manifest = JSON.parse(fs.readFileSync(path.join(BUILD, kind === 'final' ? 'vo/manifest.json' : 'vo-temp/manifest.json'), 'utf8'));
const outDir = kind === 'final' ? path.join(OUT, 'audio') : path.join(BUILD, 'audio-temp');
const suffix = kind === 'final' ? '' : '_temp';
fs.mkdirSync(outDir, { recursive: true });

const TARGET_LUFS = -16, TP_MAX = -1.5;
const DUCK_DB = -9, ATTACK = 0.12, RELEASE = 0.35;
const VO_GAIN_DB = 2.0, MUSIC_GAIN_DB = 0; // relative balance before the loudness pass

function measure(file) {
  const text = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
  const s = text.slice(text.lastIndexOf('Summary:'));
  return { I: Number(/I:\s+(-?[\d.]+) LUFS/.exec(s)?.[1]), LRA: Number(/LRA:\s+(-?[\d.]+) LU/.exec(s)?.[1]), TP: Number(/Peak:\s+(-?[\d.]+) dBFS/.exec(s)?.[1]) };
}

const music = readWav(fs.readFileSync(path.join(BUILD, 'music-score.wav')));
if (music.fs !== SR) throw new Error('music must be 48 kHz');
const N = Math.round(beats.durationSec * SR);
const mL = new Float32Array(N), mR = new Float32Array(N);
mL.set(music.channels[0].subarray(0, N)); mR.set((music.channels[1] ?? music.channels[0]).subarray(0, N));

// Narration: place every line at its start, never stretched.
const vo = new Float32Array(N);
const placed = [];
for (const l of manifest.lines) {
  const w = readWav(fs.readFileSync(path.join(BUILD, l.file)));
  if (w.fs !== SR) throw new Error(`${l.id} not 48 kHz`);
  const x = w.channels[0], i0 = Math.round(l.start * SR);
  for (let i = 0; i < x.length && i0 + i < N; i++) vo[i0 + i] += x[i];
  placed.push({ id: l.id, start: l.start, end: +(l.start + x.length / SR).toFixed(3), speechStart: l.speechStart, speechEnd: l.speechEnd, maxEnd: l.maxEnd });
}

// Ducking envelope from the speech windows (cosine ramps, no pumping).
const duck = new Float32Array(N).fill(1);
const floor = Math.pow(10, DUCK_DB / 20);
for (let i = 0; i < N; i++) {
  const t = i / SR;
  let depth = 0; // 0 = no duck, 1 = full duck
  for (const p of placed) {
    const a0 = p.speechStart - ATTACK, a1 = p.speechStart, r0 = p.speechEnd, r1 = p.speechEnd + RELEASE;
    let d = 0;
    if (t >= a1 && t <= r0) d = 1;
    else if (t > a0 && t < a1) d = 0.5 - 0.5 * Math.cos(Math.PI * (t - a0) / ATTACK);
    else if (t > r0 && t < r1) d = 0.5 + 0.5 * Math.cos(Math.PI * (t - r0) / RELEASE);
    if (d > depth) depth = d;
  }
  duck[i] = 1 - depth * (1 - floor);
}

const vg = Math.pow(10, VO_GAIN_DB / 20), mg = Math.pow(10, MUSIC_GAIN_DB / 20);
async function render(gainDb) {
  const g = Math.pow(10, gainDb / 20);
  const L = new Float32Array(N), R = new Float32Array(N);
  for (let i = 0; i < N; i++) {
    const v = vo[i] * vg * g;
    L[i] = mL[i] * mg * duck[i] * g + v;
    R[i] = mR[i] * mg * duck[i] * g + v;
  }
  const red = limit([L, R], Math.pow(10, -2.0 / 20), { lookahead: 0.005, release: 0.12 });
  const file = path.join(outDir, `winmux-intro_mix${suffix}.wav`);
  await writeWav24(file, L, R, SR);
  return { file, red, m: measure(file) };
}

// Iterate the master gain to hit the loudness target (the limiter makes it slightly non-linear).
let gain = 0, res = await render(gain);
for (let k = 0; k < 4 && Math.abs(res.m.I - TARGET_LUFS) > 0.1; k++) { gain += TARGET_LUFS - res.m.I; res = await render(gain); }

// Stems at the same gain as the mix (they sum to the pre-limiter mix).
const g = Math.pow(10, gain / 20);
const voStem = vo.map((v) => v * vg * g);
const bedL = mL.map((v, i) => v * mg * duck[i] * g), bedR = mR.map((v, i) => v * mg * duck[i] * g);
await writeWav24(path.join(outDir, `winmux-intro_vo-stem${suffix}.wav`), voStem, voStem, SR);
await writeWav24(path.join(outDir, `winmux-intro_music-bed${suffix}.wav`), bedL, bedR, SR);
if (kind === 'final') {
  await writeWav24(path.join(outDir, 'music-score_unducked.wav'), mL.map((v) => v * mg * g), mR.map((v) => v * mg * g), SR);
}
const report = {
  kind, target: { integratedLUFS: TARGET_LUFS, truePeakMaxDbTP: TP_MAX },
  measured: res.m, masterGainDb: +gain.toFixed(2), limiterMaxReductionDb: +res.red.toFixed(2),
  ducking: { depthDb: DUCK_DB, attackSec: ATTACK, releaseSec: RELEASE }, voGainDb: VO_GAIN_DB,
  lines: placed.map((p) => ({ ...p, endsBeforeWindow: p.speechEnd <= p.maxEnd + 1e-6 })),
};
report.pass = { loudness: Math.abs(res.m.I - TARGET_LUFS) <= 0.5, truePeak: res.m.TP <= TP_MAX, linesInWindows: report.lines.every((l) => l.endsBeforeWindow) };
fs.writeFileSync(path.join(outDir, `mix-report${suffix}.json`), JSON.stringify(report, null, 2));
console.log(JSON.stringify({ kind, measured: res.m, masterGainDb: report.masterGainDb, limiterMaxReductionDb: report.limiterMaxReductionDb, pass: report.pass }));
// The release mix must pass every check; the TEMP comparison mix only warns.
const failed = Object.keys(report.pass).filter((k) => !report.pass[k]);
if (failed.length) {
  console.error(`${kind === 'final' ? 'error' : 'warning'}: mix checks failed: ${failed.join(', ')}`);
  if (kind === 'final') process.exit(1);
}
