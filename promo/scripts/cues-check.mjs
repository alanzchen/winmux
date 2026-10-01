// Validates the editable cue files before any render: grid, sections, chords, accents, narration windows.
import fs from 'node:fs';
import path from 'node:path';

import { ROOT as root } from './paths.mjs';
const beats = JSON.parse(fs.readFileSync(path.join(root, 'cues/beats.json'), 'utf8'));
const narration = JSON.parse(fs.readFileSync(path.join(root, 'cues/narration.json'), 'utf8'));
const errors = [];
const SPB = 60 / beats.bpm, BAR = 4 * SPB;
if (Math.abs(beats.bars * BAR - beats.durationSec) > 1e-9) errors.push(`bars x bar length != durationSec`);
if (Math.abs(beats.fps * SPB - beats.framesPerBeat) > 1e-9) errors.push(`framesPerBeat != fps * seconds per beat`);
beats.sections.forEach((s, i) => {
  if (i === 0 && s.startBar !== 0) errors.push('first section must start at bar 0');
  if (i > 0 && s.startBar !== beats.sections[i - 1].endBar) errors.push(`section ${s.id} not contiguous`);
});
if (beats.sections.at(-1).endBar !== beats.bars) errors.push('sections must end at the last bar');
const known = ['Bm(add9)', 'G', 'Em7', 'F#sus4', 'F#', 'D', 'A/C#', 'Bm7', 'Gmaj7', 'A', 'Asus4', 'F#m7', 'D/F#', 'A7sus4', 'D(add9)', 'G/D'];
beats.chords.forEach((c) => { if (!known.includes(c.chord)) errors.push(`unknown chord ${c.chord} (add a voicing in synth.mjs)`); });
const ids = new Set();
beats.accents.forEach((a) => {
  if (ids.has(a.id)) errors.push(`duplicate accent ${a.id}`); ids.add(a.id);
  const t = (a.bar * 4 + a.beat) * SPB;
  if (t < 0 || t > beats.durationSec) errors.push(`accent ${a.id} outside the film`);
});
narration.lines.forEach((l, i) => {
  if (l.maxEnd <= l.start) errors.push(`${l.id}: empty window`);
  if (i > 0 && l.start < narration.lines[i - 1].maxEnd) errors.push(`${l.id}: window overlaps ${narration.lines[i - 1].id}`);
  if (l.maxEnd > beats.durationSec) errors.push(`${l.id}: window past the end`);
  if (/vmax/i.test(l.text)) errors.push(`${l.id}: the product is WinMux`);
});
console.log(errors.length ? `cue errors:\n- ${errors.join('\n- ')}` : `cues ok: ${beats.bars} bars @ ${beats.bpm} BPM, ${beats.accents.length} accents, ${narration.lines.length} narration lines`);
process.exit(errors.length ? 1 : 0);
