// Objective checks on narration takes (nobody can listen here): speech span, head/tail silence,
// peak, pauses (silent gaps) and a syllable-nucleus count for the first word group.
// Usage: node scripts/vo/analyze.mjs vo/L16.wav [...]
import fs from 'node:fs';
import { fileURLToPath } from 'node:url';
import { readWav } from '../music/dsp.mjs';

export function analyze(file, { threshDb = -42, gapMin = 0.12 } = {}) {
  const { fs: rate, channels } = readWav(fs.readFileSync(file));
  const x = channels[0];
  const win = Math.round(0.01 * rate); // 10 ms RMS frames
  const frames = [];
  for (let i = 0; i + win <= x.length; i += win) {
    let s = 0; for (let k = 0; k < win; k++) s += x[i + k] * x[i + k];
    frames.push(10 * Math.log10(s / win + 1e-12));
  }
  let peak = 0; for (const v of x) peak = Math.max(peak, Math.abs(v));
  const on = frames.map((d) => d > threshDb);
  const first = on.indexOf(true), last = on.lastIndexOf(true);
  // Silent gaps inside the speech span.
  const gaps = [];
  let runStart = -1;
  for (let f = first; f <= last; f++) {
    if (!on[f] && runStart < 0) runStart = f;
    if (on[f] && runStart >= 0) { const len = (f - runStart) * 0.01; if (len >= gapMin) gaps.push({ at: +(runStart * 0.01).toFixed(2), len: +len.toFixed(2) }); runStart = -1; }
  }
  // Syllable nuclei: peaks of a smoothed envelope in the first word group (before the first gap).
  const groupEnd = gaps.length ? Math.round(gaps[0].at / 0.01) : last;
  const env = frames.map((_, i) => { let s = 0, n = 0; for (let k = -3; k <= 3; k++) { const v = frames[i + k]; if (v !== undefined) { s += v; n++; } } return s / n; });
  let nuclei = 0;
  for (let f = first + 1; f < groupEnd - 1; f++) if (env[f] > env[f - 1] && env[f] >= env[f + 1] && env[f] > threshDb + 12) {
    // require a dip of 3 dB since the previous nucleus
    nuclei++;
    let g = f + 1; while (g < groupEnd && env[g] > env[f] - 3) g++; f = g;
  }
  return {
    file, rate, seconds: +(x.length / rate).toFixed(3),
    head: +(first * 0.01).toFixed(2), tail: +((frames.length - 1 - last) * 0.01).toFixed(2),
    speech: +((last - first + 1) * 0.01).toFixed(2), peakDb: +(20 * Math.log10(peak)).toFixed(1),
    gaps, firstGroupSec: +((groupEnd - first) * 0.01).toFixed(2), firstGroupNuclei: nuclei,
  };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  for (const f of process.argv.slice(2)) console.log(JSON.stringify(analyze(f)));
}
