// Timing sheet (markdown) from the beat grid and the measured narration placement.
// Usage: node scripts/timing-sheet.mjs  ->  $PROMO_OUT_DIR/timing-sheet.md
import fs from 'node:fs';
import path from 'node:path';

import { BUILD, OUT, ROOT as root } from './paths.mjs';
const beats = JSON.parse(fs.readFileSync(path.join(root, 'cues/beats.json'), 'utf8'));
const vo = JSON.parse(fs.readFileSync(path.join(BUILD, 'vo/manifest.json'), 'utf8'));
const T = (bar, beat = 0) => (bar * 4 + beat) * 60 / beats.bpm;
const mmss = (s) => `${Math.floor(s / 60)}:${(s % 60).toFixed(2).padStart(5, '0')}`;
const pos = (s) => { const b = s / (240 / beats.bpm); const bar = Math.floor(b + 1e-9); const beat = +(((b - bar) * 4) + 1).toFixed(2); return `bar ${bar + 1}, beat ${beat}`; };

let md = `# WinMux intro: timing sheet\n\n`;
md += `- **Film:** ${beats.durationSec} s, ${beats.fps} fps, 1920×1080.\n`;
md += `- **Music:** ${beats.bpm} BPM in ${beats.timeSignature.join('/')}. A beat is ${60 / beats.bpm} s (${beats.framesPerBeat} frames) and a bar is ${240 / beats.bpm} s.\n`;
md += `- **Positions:** bars and beats count from 1, so bar 1 beat 1 is 0:00.\n`;
md += `- **Narration:** Google Gemini TTS (gemini-3.1-flash-tts-preview, voice Kore). Each line is placed un-stretched; the times are measured speech onsets and ends.\n\n`;
md += `## Narration\n\n| Line | File starts | Speech | Window ends | Margin | Text |\n|---|---|---|---|---|---|\n`;
for (const l of vo.lines) {
  md += `| ${l.id} | ${mmss(l.start)} (${pos(l.start)}) | ${mmss(l.speechStart)} – ${mmss(l.speechEnd)} | ${mmss(l.maxEnd)} | ${(l.maxEnd - l.speechEnd).toFixed(2)} s | ${l.text} |\n`;
}
md += `\n## Sections\n\n| Section | Time | Bars | Mood |\n|---|---|---|---|\n`;
for (const s of beats.sections) md += `| ${s.id} | ${mmss(T(s.startBar))} – ${mmss(T(s.endBar))} | ${s.startBar + 1}–${s.endBar} | ${s.mood} |\n`;
md += `\n## Accents (picture and music hit together)\n\n| Time | Position | Accent | Strength | What happens |\n|---|---|---|---|---|\n`;
for (const a of beats.accents) md += `| ${mmss(T(a.bar, a.beat))} | ${pos(T(a.bar, a.beat))} | ${a.id} | ${a.strength} | ${a.visual} |\n`;
md += `\n## Music-only moments\n\n`;
const gaps = [];
let last = 0;
for (const l of vo.lines) { if (l.speechStart - last > 1.4) gaps.push([last, l.speechStart]); last = l.speechEnd; }
if (beats.durationSec - last > 1.4) gaps.push([last, beats.durationSec]);
md += gaps.map(([a, b]) => `- ${mmss(a)} – ${mmss(b)} (${(b - a).toFixed(1)} s)`).join('\n') + '\n';
fs.mkdirSync(OUT, { recursive: true });
fs.writeFileSync(path.join(OUT, 'timing-sheet.md'), md);
console.log(`${path.join(OUT, 'timing-sheet.md')} written`);
