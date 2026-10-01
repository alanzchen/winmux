// Prepare narration lines for the mix, never time-stretching them:
// native master -> 48 kHz (ffmpeg swr, 128-tap) -> trim (<=0.08 s head, <=0.25 s tail at -42 dBFS) ->
// short fades -> one shared loudness gain (median line to -18 LUFS; outliers pulled within 1 LU) ->
// a lookahead peak limiter at -2 dBFS (a safety net for rare transients; the mix sets final loudness) ->
// 24-bit mono delivery copy + a manifest with placements for the mix and captions.
// Usage: node scripts/vo/prepare.mjs final   (approved 24 kHz masters in vo/ -> $PROMO_BUILD_DIR/vo/*.wav)
//        node scripts/vo/prepare.mjs temp    (optional macOS `say` takes -> $PROMO_BUILD_DIR/vo-temp/*.wav)
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { readWav, writeWav24, limit } from '../music/dsp.mjs';
import { ROOT as root, BUILD } from '../paths.mjs';
const which = process.argv[2] ?? 'final';
const narration = JSON.parse(fs.readFileSync(path.join(root, 'cues/narration.json'), 'utf8'));
const srcDir = which === 'final' ? path.join(root, 'vo') : path.join(BUILD, 'vo-temp-raw');
const outDir = which === 'final' ? path.join(BUILD, 'vo') : path.join(BUILD, 'vo-temp');
const tmp = path.join(BUILD, 'vo-prep');
fs.mkdirSync(tmp, { recursive: true });
fs.mkdirSync(outDir, { recursive: true });
const HEAD = 0.08, TAIL = 0.25, THRESH_DB = -42, TARGET = -18, CEILING_DB = -2;

// ffmpeg prints the ebur128 summary on stderr.
function measure(file) {
  const text = spawnSync('ffmpeg', ['-hide_banner', '-nostats', '-i', file, '-af', 'ebur128=peak=true', '-f', 'null', '-'], { encoding: 'utf8' }).stderr;
  const summary = text.slice(text.lastIndexOf('Summary:'));
  return { I: Number(/I:\s+(-?[\d.]+) LUFS/.exec(summary)?.[1]), TP: Number(/Peak:\s+(-?[\d.]+) dBFS/.exec(summary)?.[1]) };
}

const lines = [];
for (const l of narration.lines) {
  const src = path.join(srcDir, which === 'final' ? `${l.id}.wav` : `${l.id}.aiff`);
  if (!fs.existsSync(src)) { console.error(`missing ${src}`); process.exit(2); }
  const up = path.join(tmp, `${which}-${l.id}-48k.wav`);
  // High-quality swr resampling to 48 kHz (this ffmpeg build has no libsoxr), 32-bit float, mono.
  execFileSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', '-i', src, '-af', 'aresample=48000:resampler=swr:filter_size=128:phase_shift=12:cutoff=0.98', '-ac', '1', '-c:a', 'pcm_f32le', up]);
  const { channels } = readWav(fs.readFileSync(up));
  const x = channels[0];
  const win = 480; // 10 ms
  let first = -1, last = -1;
  for (let i = 0; i + win <= x.length; i += win) {
    let s = 0; for (let k = 0; k < win; k++) s += x[i + k] * x[i + k];
    if (10 * Math.log10(s / win + 1e-12) > THRESH_DB) { if (first < 0) first = i; last = i + win; }
  }
  const a = Math.max(0, first - Math.round(HEAD * 48000)), b = Math.min(x.length, last + Math.round(TAIL * 48000));
  const y = x.slice(a, b);
  const fi = Math.round(0.005 * 48000), fo = Math.round(0.03 * 48000);
  for (let i = 0; i < fi; i++) y[i] *= i / fi;
  for (let i = 0; i < fo; i++) y[y.length - 1 - i] *= i / fo;
  const trimmed = path.join(tmp, `${which}-${l.id}-trim.wav`);
  await writeWav24(trimmed, y, null, 48000);
  const m = measure(trimmed);
  lines.push({ ...l, y, trimmed, headSec: (first - a) / 48000, speechSec: (last - first) / 48000, I: m.I, TP: m.TP });
}
const sorted = lines.map((l) => l.I).sort((p, q) => p - q);
const median = sorted[Math.floor(sorted.length / 2)];
const common = TARGET - median;
const manifest = { kind: which, target: TARGET, commonGainDb: +common.toFixed(2), lines: [] };
for (const l of lines) {
  // Pull outliers to within 1 LU of the target, keep everything else at the shared gain.
  const dev = l.I + common - TARGET;
  const extra = Math.abs(dev) > 1 ? -(dev - Math.sign(dev) * 1) : 0;
  const g = Math.pow(10, (common + extra) / 20);
  const y = l.y.map((v) => v * g);
  const limitedDb = limit([y], Math.pow(10, CEILING_DB / 20));
  let peak = 0; for (const v of y) peak = Math.max(peak, Math.abs(v));
  const out = path.join(outDir, `${l.id}.wav`);
  await writeWav24(out, y, null, 48000);
  const m = measure(out);
  manifest.lines.push({
    id: l.id, text: l.text, file: path.relative(BUILD, out), source: which === 'final' ? `vo/${l.id}.wav` : `say:${l.id}`,
    start: l.start, maxEnd: l.maxEnd, duration: +(y.length / 48000).toFixed(3),
    speechStart: +(l.start + l.headSec).toFixed(3), speechEnd: +(l.start + l.headSec + l.speechSec).toFixed(3),
    fitsWindow: l.start + l.headSec + l.speechSec <= l.maxEnd + 1e-6,
    gainDb: +(common + extra).toFixed(2), limiterMaxReductionDb: +limitedDb.toFixed(2), lufs: m.I, truePeakDb: m.TP, samplePeakDb: +(20 * Math.log10(peak)).toFixed(2),
  });
}
fs.writeFileSync(path.join(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2));
for (const l of manifest.lines) console.log(`${l.id} start ${l.start} speech ${l.speechStart}-${l.speechEnd} (window ends ${l.maxEnd}) ${l.fitsWindow ? 'OK' : 'OVER'} ${l.lufs} LUFS TP ${l.truePeakDb} lim ${l.limiterMaxReductionDb} dB`);
console.log(`common gain ${manifest.commonGainDb} dB (median line ${median} LUFS)`);
// The release narration must fit its windows; the TEMP comparison voice only warns.
const over = manifest.lines.filter((l) => !l.fitsWindow).map((l) => l.id);
if (over.length) {
  console.error(`${which === 'final' ? 'error' : 'warning'}: speech overruns its window in ${over.join(', ')}`);
  if (which === 'final') process.exit(1);
}
