// Shared locations. Build intermediates go to PROMO_BUILD_DIR and deliverables to PROMO_OUT_DIR
// (both default inside promo/, which ignores them); inputs always come from this folder.
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const BUILD = path.resolve(process.env.PROMO_BUILD_DIR || path.join(ROOT, 'build'));
export const OUT = path.resolve(process.env.PROMO_OUT_DIR || path.join(ROOT, 'out'));
