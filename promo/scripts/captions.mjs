// English captions (SRT + WebVTT) from the placed narration: cue times are the measured speech
// windows in vo/<kind>/manifest.json (never the planned targets). Usage: node scripts/captions.mjs final|temp
import fs from 'node:fs';
import path from 'node:path';

import { BUILD, OUT } from './paths.mjs';
const kind = process.argv[2] ?? 'final';
const manifest = JSON.parse(fs.readFileSync(path.join(BUILD, kind === 'final' ? 'vo/manifest.json' : 'vo-temp/manifest.json'), 'utf8'));
const outDir = kind === 'final' ? path.join(OUT, 'captions') : path.join(BUILD, 'captions-temp');
fs.mkdirSync(outDir, { recursive: true });

const MAX = 42;
function wrap(text) {
  if (text.length <= MAX) return [text];
  // Break at the space closest to the middle that keeps both lines <= MAX; prefer after punctuation.
  const words = text.split(' ');
  let best = null;
  for (let i = 1; i < words.length; i++) {
    const a = words.slice(0, i).join(' '), b = words.slice(i).join(' ');
    if (a.length > MAX || b.length > MAX) continue;
    const punct = /[.,;:?!]$/.test(a) ? -6 : 0;
    const score = Math.abs(a.length - b.length) + punct;
    if (!best || score < best.score) best = { a, b, score };
  }
  return best ? [best.a, best.b] : [text];
}
const fmt = (s, sep) => {
  const ms = Math.round(s * 1000);
  const h = Math.floor(ms / 3600000), m = Math.floor((ms % 3600000) / 60000), sec = Math.floor((ms % 60000) / 1000), r = ms % 1000;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(sec).padStart(2, '0')}${sep}${String(r).padStart(3, '0')}`;
};

const cues = manifest.lines.map((l, i, all) => {
  const start = Math.max(0, l.speechStart - 0.05);
  const next = all[i + 1] ? all[i + 1].speechStart - 0.1 : Infinity;
  const end = Math.min(Math.max(l.speechEnd + 0.25, start + 1.2), next);
  return { i: i + 1, id: l.id, start, end, lines: wrap(l.text) };
});
const srt = cues.map((c) => `${c.i}\n${fmt(c.start, ',')} --> ${fmt(c.end, ',')}\n${c.lines.join('\n')}\n`).join('\n');
const vtt = 'WEBVTT\n\n' + cues.map((c) => `${c.id}\n${fmt(c.start, '.')} --> ${fmt(c.end, '.')}\n${c.lines.join('\n')}\n`).join('\n');
const suffix = kind === 'final' ? '' : '_TEMP-VO';
fs.writeFileSync(path.join(outDir, `winmux-intro.en${suffix}.srt`), srt);
fs.writeFileSync(path.join(outDir, `winmux-intro.en${suffix}.vtt`), vtt);
// Sanity: ordered, non-overlapping, within the film, <= 2 lines of <= 42 chars.
const problems = [];
cues.forEach((c, i) => {
  if (c.end <= c.start) problems.push(`${c.id}: empty cue`);
  if (i && c.start < cues[i - 1].end) problems.push(`${c.id}: overlaps previous`);
  if (c.end > 86) problems.push(`${c.id}: past the end`);
  if (c.lines.length > 2 || c.lines.some((x) => x.length > MAX)) problems.push(`${c.id}: line too long`);
});
console.log(`${cues.length} cues -> ${path.join(outDir, `winmux-intro.en${suffix}`)}.{srt,vtt}; problems: ${problems.length ? problems.join('; ') : 'none'}`);
if (problems.length) process.exit(1);
