// World layout (units = points) and the one continuous camera.
import { A, T, keys, easeCamera, easeInOutCubic, easeOutCubic, easeInOutQuint, noise1, spring } from '../lib/time';
import type { Rect } from '../lib/ui';

export const DW = 1440, DH = 900, GAP = 120;
export const DISPLAYS = { A: { x: 0, y: 0 }, B: { x: DW + GAP, y: 0 }, C: { x: 2 * (DW + GAP), y: 0 } };
export const NAMES = { A: 'Built-in Retina Display', B: 'Studio Display', C: 'LG UltraFine' };

// Inside a display: the Tabs panel is flush left/top; tiles use outer gaps of 8.
export const TILE_AREA: Rect = { x: 272, y: 8, w: 1160, h: 876 };
export const DESIGN_TILES: Record<string, Rect> = {
  prototype: { x: 272, y: 8, w: 576, h: 876 },
  mockups: { x: 856, y: 8, w: 576, h: 434 },
  specs: { x: 856, y: 450, w: 576, h: 434 },
};
// The drag's temporary UI beside A's sidebar (from the display-rails layout: rails 6 pt from the edge, 30 wide, 2 apart; list 6 pt after).
export const RAILS_X = 270, LIST_X = 338;

export type Cam = { x: number; y: number; z: number };
export const SCREEN = { w: 1920, h: 1080 };

const E = easeCamera;
export function camera(t: number): Cam {
  const x = keys(t, [
    [0, 720], [12, 720], [23, 728], [24, 338, E], [33.1, 338], [33.9, 440, E], [35.6, 425, (p) => p], [37.1, 338, E], [44, 338], [45.6, 720, E], [48, 2280, easeInOutQuint], [51, 2280],
    [52.6, 560, E], [59.45, 480, easeInOutCubic], [60.35, DISPLAYS.B.x + 470, easeInOutQuint], [61.4, DISPLAYS.B.x + 470],
    [62.6, 1500, E], [75.4, 1500], [76.8, 2280, E],
  ]);
  const y = keys(t, [
    [0, 450], [23, 450], [24, 272, E], [29.6, 280], [32.4, 616, E], [33.1, 616], [33.9, 436, E], [35.6, 436], [37.1, 432, E], [39.3, 432],
    [40.3, 262, E], [42.2, 262], [44, 236, (p) => p], [45.6, 450, E], [51, 450], [52.6, 442, E], [61.4, 442], [62.6, 468, E], [75.4, 468], [76.8, 450, E],
  ]);
  let z = keys(t, [
    [0, 0.98], [12, 1.08, (p) => p], [23, 1.1], [24, 2.0, E], [29.6, 2.07, (p) => p], [32.4, 2.0, E], [33.1, 2.0], [33.9, 1.3, E], [35.6, 1.28, (p) => p], [37.1, 2.0, E], [38.6, 2.04, (p) => p], [40.3, 2.0, E], [42.2, 2.02], [44, 2.13, (p) => p], [45.6, 1.1, E], [48, 0.4, easeInOutQuint], [51, 0.415],
    [52.6, 1.22, E], [59.45, 1.3, easeInOutCubic], [60.35, 1.3], [61.4, 1.3], [62.6, 0.62, E], [75.4, 0.64], [76.8, 0.42, E],
  ]);
  // The snap lands with a small push; the displays reveal breathes out.
  z *= 1 + 0.018 * Math.sin(Math.PI * Math.min(1, Math.max(0, (t - A.snap) / 0.5))) * (t > A.snap ? 1 : 0);
  // Gentle handheld drift, strongest in wide shots, none during precise UI moves.
  const drift = t < 12 ? 1 : t > 45.6 && t < 51 ? 0.8 : t > 62.6 && t < 75.4 ? 0.5 : 0.3;
  return {
    x: x + noise1(t * 0.35, 1) * 6 * drift,
    y: y + noise1(t * 0.31, 2) * 4 * drift,
    z,
  };
}

export const worldToScreen = (c: Cam, px: number, py: number) => ({ x: (px - c.x) * c.z + SCREEN.w / 2, y: (py - c.y) * c.z + SCREEN.h / 2 });
export const rectToScreen = (c: Cam, r: Rect): Rect => {
  const p = worldToScreen(c, r.x, r.y);
  return { x: p.x, y: p.y, w: r.w * c.z, h: r.h * c.z };
};
export const onDisplay = (d: keyof typeof DISPLAYS, r: Rect): Rect => ({ x: r.x + DISPLAYS[d].x, y: r.y + DISPLAYS[d].y, w: r.w, h: r.h });

/** Screen-space speed of the camera (px per frame), used for a touch of motion blur on whips. */
export function cameraSpeed(t: number, fps = 60) {
  const a = camera(t - 1 / fps), b = camera(t);
  const dx = (b.x - a.x) * b.z, dy = (b.y - a.y) * b.z, dz = Math.abs(b.z - a.z) * 900;
  return Math.hypot(dx, dy) + dz;
}

export { T, spring, easeOutCubic };
