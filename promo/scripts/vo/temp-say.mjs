// TEMP timing narration with macOS `say` (Samantha), kept only for comparison with the final
// Gemini narration. NEVER the final voice. "WinMux" is respelled "Win-mux" for pronunciation.
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { ROOT as root, BUILD } from '../paths.mjs';
const narration = JSON.parse(fs.readFileSync(path.join(root, 'cues/narration.json'), 'utf8'));
const out = path.join(BUILD, 'vo-temp-raw');
fs.mkdirSync(out, { recursive: true });
for (const l of narration.lines) {
  const text = l.text.replace(/WinMux/g, 'Win-mux');
  execFileSync('say', ['-v', 'Samantha', '-o', path.join(out, `${l.id}.aiff`), text]);
}
console.log(`TEMP say lines -> ${out} (${narration.lines.length})`);
