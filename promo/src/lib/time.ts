// Time helpers: everything in the film is placed on the beat grid in cues/beats.json.
import beats from '../../cues/beats.json';
import narration from '../../cues/narration.json';

export const FPS = beats.fps;
export const SPB = 60 / beats.bpm; // seconds per beat
export const DURATION = beats.durationSec;
export const T = (bar: number, beat = 0) => (bar * 4 + beat) * SPB;
export const A: Record<string, number> = Object.fromEntries(beats.accents.map((a) => [a.id, T(a.bar, a.beat)]));
export const POPS: number[] = beats.clutterPops.map((p) => T(p.bar, p.beat));
export const LINES = narration.lines;

export const clamp = (x: number, lo = 0, hi = 1) => (x < lo ? lo : x > hi ? hi : x);
export const lerp = (a: number, b: number, p: number) => a + (b - a) * p;

// Easings (p in 0..1).
export const easeInOutCubic = (p: number) => (p < 0.5 ? 4 * p * p * p : 1 - Math.pow(-2 * p + 2, 3) / 2);
export const easeOutCubic = (p: number) => 1 - Math.pow(1 - p, 3);
export const easeInCubic = (p: number) => p * p * p;
export const easeOutQuart = (p: number) => 1 - Math.pow(1 - p, 4);
export const easeInOutQuint = (p: number) => (p < 0.5 ? 16 * p ** 5 : 1 - Math.pow(-2 * p + 2, 5) / 2);
export const easeOutExpo = (p: number) => (p >= 1 ? 1 : 1 - Math.pow(2, -10 * p));
export const easeInOutSine = (p: number) => -(Math.cos(Math.PI * p) - 1) / 2;
// A camera-grade ease: slow out, decisive middle, long settle.
export const easeCamera = (p: number) => {
  const q = clamp(p);
  return q < 0.5 ? 8 * q ** 4 : 1 - Math.pow(-2 * q + 2, 4) / 2;
};

/** Progress of t through [t0, t1], eased. */
export const prog = (t: number, t0: number, t1: number, ease: (p: number) => number = easeInOutCubic) =>
  ease(clamp((t - t0) / (t1 - t0)));

/** Damped spring response (0 -> 1) started at t0. Critically/under-damped; deterministic. */
export function spring(t: number, t0: number, { freq = 2.2, damping = 0.72 }: { freq?: number; damping?: number } = {}) {
  const x = t - t0;
  if (x <= 0) return 0;
  const w = 2 * Math.PI * freq;
  const z = damping;
  if (z >= 1) return 1 - Math.exp(-w * x) * (1 + w * x);
  const wd = w * Math.sqrt(1 - z * z);
  return 1 - Math.exp(-z * w * x) * (Math.cos(wd * x) + (z * w / wd) * Math.sin(wd * x));
}

/** Piecewise keyframes: [[t, value], ...] with an ease per segment (defaults to easeInOutCubic). */
export function keys(t: number, frames: Array<[number, number, ((p: number) => number)?]>) {
  if (t <= frames[0][0]) return frames[0][1];
  for (let i = 0; i < frames.length - 1; i++) {
    const [t0, v0] = frames[i];
    const [t1, v1, e] = frames[i + 1];
    if (t <= t1) return lerp(v0, v1, (e ?? easeInOutCubic)(clamp((t - t0) / (t1 - t0))));
  }
  return frames[frames.length - 1][1];
}

/** A short pulse (0 -> 1 -> 0) centred after t0, for accent glints. */
export const pulse = (t: number, t0: number, len = 0.5) => {
  const x = (t - t0) / len;
  return x <= 0 || x >= 1 ? 0 : Math.sin(Math.PI * x) ** 2;
};

// Deterministic hash noise for gentle drift (no Math.random in renders).
export function noise1(x: number, seed = 0) {
  const h = (n: number) => {
    const s = Math.sin(n * 127.1 + seed * 311.7) * 43758.5453;
    return s - Math.floor(s);
  };
  const i = Math.floor(x), f = x - i;
  const u = f * f * (3 - 2 * f);
  return lerp(h(i), h(i + 1), u) * 2 - 1;
}
