import React from 'react';
import { Img } from 'remotion';
import type { Rect, UIState } from '../lib/ui';

export const FONT = "'Inter Variable', Inter, system-ui, sans-serif";

/** Draws the region `s` of a render (in the render's point space) into rect `d` (world units). */
export const Crop: React.FC<{
  state?: UIState; src?: string; iw?: number; ih?: number; s: Rect; d: Rect; opacity?: number; style?: React.CSSProperties;
}> = ({ state, src, iw, ih, s, d, opacity = 1, style }) => {
  const img = src ?? state!.src;
  const W = iw ?? state!.width, H = ih ?? state!.height;
  const kx = d.w / s.w, ky = d.h / s.h;
  if (opacity <= 0.001) return null;
  return (
    <div style={{ position: 'absolute', left: d.x, top: d.y, width: d.w, height: d.h, overflow: 'hidden', opacity, ...style }}>
      <Img src={img} style={{ position: 'absolute', left: -s.x * kx, top: -s.y * ky, width: W * kx, height: H * ky, maxWidth: 'none' }} />
    </div>
  );
};

/** A whole render at a position (world units). */
export const Full: React.FC<{ state: UIState; x?: number; y?: number; opacity?: number; style?: React.CSSProperties }> = ({ state, x = 0, y = 0, opacity = 1, style }) =>
  opacity <= 0.001 ? null : (
    <Img src={state.src} style={{ position: 'absolute', left: x, top: y, width: state.width, height: state.height, opacity, maxWidth: 'none', ...style }} />
  );

// ---------- original wallpapers (CSS gradients; no third-party imagery) ----------
export const WALLPAPERS: Record<string, string> = {
  A: [
    'radial-gradient(70% 60% at 18% 12%, rgba(76,201,240,0.55) 0%, rgba(76,201,240,0) 70%)',
    'radial-gradient(60% 70% at 88% 85%, rgba(114,9,183,0.55) 0%, rgba(114,9,183,0) 70%)',
    'radial-gradient(50% 50% at 60% 40%, rgba(67,97,238,0.45) 0%, rgba(67,97,238,0) 75%)',
    'linear-gradient(155deg, #0c1a3d 0%, #121a4a 45%, #1d1242 100%)',
  ].join(','),
  B: [
    'radial-gradient(65% 60% at 80% 15%, rgba(128,237,153,0.35) 0%, rgba(128,237,153,0) 70%)',
    'radial-gradient(70% 70% at 15% 90%, rgba(76,201,240,0.5) 0%, rgba(76,201,240,0) 70%)',
    'linear-gradient(160deg, #06282e 0%, #0b3140 50%, #0c1f33 100%)',
  ].join(','),
  C: [
    'radial-gradient(60% 60% at 25% 20%, rgba(255,183,3,0.4) 0%, rgba(255,183,3,0) 70%)',
    'radial-gradient(70% 70% at 85% 85%, rgba(240,76,160,0.45) 0%, rgba(240,76,160,0) 70%)',
    'linear-gradient(160deg, #2a1024 0%, #2c1238 50%, #1a1030 100%)',
  ].join(','),
};

/** A display: bezel, glow, wallpaper and a clipped screen. Children use screen-local coordinates. */
export const DisplayFrame: React.FC<{
  x: number; y: number; w: number; h: number; wallpaper: string; power?: number; glow?: string; fade?: number; children?: React.ReactNode;
}> = ({ x, y, w, h, wallpaper, power = 1, glow = 'rgba(80,120,255,0.35)', fade = 1, children }) => {
  const bezel = 16;
  if (fade <= 0.001) return null;
  return (
    <div style={{ position: 'absolute', left: x - bezel, top: y - bezel, width: w + bezel * 2, height: h + bezel * 2, opacity: fade }}>
      {/* glow on the "desk" */}
      <div style={{ position: 'absolute', left: -60, top: -40, right: -60, bottom: -80, borderRadius: 60, background: glow,
        filter: 'blur(70px)', opacity: 0.55 * power }} />
      {/* bezel */}
      <div style={{ position: 'absolute', inset: 0, borderRadius: 26,
        background: 'linear-gradient(180deg, #2a2d35 0%, #15171c 60%, #101216 100%)',
        boxShadow: '0 40px 90px rgba(0,0,0,0.6), inset 0 1px 0 rgba(255,255,255,0.12)' }} />
      {/* screen */}
      <div style={{ position: 'absolute', left: bezel, top: bezel, width: w, height: h, borderRadius: 12, overflow: 'hidden', background: '#000' }}>
        <div style={{ position: 'absolute', inset: 0, background: WALLPAPERS[wallpaper], opacity: power }} />
        <div style={{ position: 'absolute', inset: 0, opacity: Math.min(1, power * 1.2) }}>{children}</div>
        {/* glass: a restrained diagonal sheen */}
        <div style={{ position: 'absolute', inset: 0, pointerEvents: 'none',
          background: 'linear-gradient(115deg, rgba(255,255,255,0.07) 0%, rgba(255,255,255,0) 32%, rgba(255,255,255,0) 70%, rgba(255,255,255,0.03) 100%)' }} />
      </div>
    </div>
  );
};

/** Original arrow pointer drawing (generic arrow, not a system cursor asset). */
export const Pointer: React.FC<{ x: number; y: number; scale?: number; pressed?: number; opacity?: number }> = ({ x, y, scale = 1, pressed = 0, opacity = 1 }) =>
  opacity <= 0.001 ? null : (
    <svg width={28} height={40} viewBox="-2 -2 28 40"
      style={{ position: 'absolute', left: x - 2, top: y - 2, transform: `scale(${scale * (1 - 0.1 * pressed)})`, transformOrigin: '2px 2px',
        opacity, filter: 'drop-shadow(0 3px 5px rgba(0,0,0,0.45))', overflow: 'visible' }}>
      <path d="M0 0 L0 27 L6.6 20.6 L11 31 L15.4 29.2 L11.1 19 L20 19 Z" fill="#fff" stroke="#111" strokeWidth={1.6} strokeLinejoin="round" />
    </svg>
  );

export const lerpRect = (a: Rect, b: Rect, p: number): Rect => ({
  x: a.x + (b.x - a.x) * p, y: a.y + (b.y - a.y) * p, w: a.w + (b.w - a.w) * p, h: a.h + (b.h - a.h) * p,
});
