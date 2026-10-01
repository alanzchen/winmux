// Render stills at given timestamps (seconds) with one bundle: node scripts/stills.mjs <dir> 1.5 12.2 24 ...
import path from 'node:path';
import fs from 'node:fs';
import { bundle } from '@remotion/bundler';
import { renderStill, selectComposition } from '@remotion/renderer';

import { ROOT as root } from './paths.mjs';
const [outDir, ...times] = process.argv.slice(2);
fs.mkdirSync(outDir, { recursive: true });
const serveUrl = await bundle({ entryPoint: path.join(root, 'src/index.ts'), publicDir: path.join(root, 'public') });
const composition = await selectComposition({ serveUrl, id: 'WinMuxIntro', chromiumOptions: { gl: 'angle' } });
for (const s of times) {
  const frame = Math.min(composition.durationInFrames - 1, Math.round(Number(s) * composition.fps));
  const output = path.join(outDir, `t${String(s).replace('.', '_')}.png`);
  await renderStill({ serveUrl, composition, frame, output, chromiumOptions: { gl: 'angle' }, imageFormat: 'png' });
  console.log('still', s, '->', output);
}
