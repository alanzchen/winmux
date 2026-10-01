// Converge (76-78 s): two sidebars and three windows fly into the WinMux icon's five glass windows,
// which hand off to the exact SVG mark at 78.0 s. Then the end card.
import React from 'react';
import { AppWindow } from '../components/AppWindow';
import { LOGO_WINDOWS, LogoSvg, cssGradient, type LogoWindow } from '../components/Logo';
import { FONT, Full } from '../components/primitives';
import { A, clamp, easeInOutCubic, easeOutCubic, lerp, prog, spring } from '../lib/time';
import { UI, type Rect } from '../lib/ui';
import { DISPLAYS, TILE_AREA, camera, rectToScreen, type Cam } from './geometry';
import { CONVERGE, SPECS } from './windows';

const ICON = { size: 300, x: 960 - 150, y: 250 };
const k = ICON.size / 512;
const LAND = A['logo-land'];

type Flyer = { key: LogoWindow['key']; depart: number; world: Rect; radius: number; content: (w: number, h: number) => React.ReactNode };
const FLYERS: Flyer[] = [
  { key: 'E', depart: CONVERGE.sidebarA, world: { x: DISPLAYS.A.x, y: 0, w: 264, h: 884 }, radius: 14, content: () => <Full state={UI.A10} /> },
  { key: 'A', depart: CONVERGE.chatA, world: { ...TILE_AREA, x: DISPLAYS.A.x + TILE_AREA.x }, radius: 14,
    content: (w, h) => <AppWindow kind={SPECS.chat.kind} title={SPECS.chat.title} nw={w} nh={h} active seed={SPECS.chat.seed} /> },
  { key: 'D', depart: CONVERGE.sidebarB, world: { x: DISPLAYS.B.x, y: 0, w: 264, h: 884 }, radius: 14, content: () => <Full state={UI.B05} /> },
  { key: 'B', depart: CONVERGE.docsB, world: { ...TILE_AREA, x: DISPLAYS.B.x + TILE_AREA.x }, radius: 14,
    content: (w, h) => <AppWindow kind={SPECS.docs.kind} title={SPECS.docs.title} nw={w} nh={h} active={false} seed={SPECS.docs.seed} /> },
  { key: 'C', depart: CONVERGE.moodC, world: { ...TILE_AREA, x: DISPLAYS.C.x + TILE_AREA.x }, radius: 14,
    content: (w, h) => <AppWindow kind={SPECS.moodboard.kind} title={SPECS.moodboard.title} nw={w} nh={h} active={false} seed={SPECS.moodboard.seed} /> },
];

function FlyerView({ f, t }: { f: Flyer; t: number }) {
  if (t < f.depart || t >= LAND + 0.02) return null;
  const lw = LOGO_WINDOWS.find((w) => w.key === f.key)!;
  const start = rectToScreen(camera(f.depart), f.world);
  const end: Rect = { x: ICON.x + lw.x * k, y: ICON.y + lw.y * k, w: lw.w * k, h: lw.h * k };
  const p = easeInOutCubic(clamp((t - f.depart) / (LAND - f.depart)));
  const arc = Math.sin(Math.PI * p) * -60;
  const cx = lerp(start.x + start.w / 2, end.x + end.w / 2, p), cy = lerp(start.y + start.h / 2, end.y + end.h / 2, p) + arc;
  const w = lerp(start.w, end.w, p), h = lerp(start.h, end.h, p);
  const glass = clamp((p - 0.3) / 0.6);
  const contentO = 1 - clamp((p - 0.25) / 0.55);
  const radius = lerp(f.radius * (start.w / f.world.w), lw.rx * k, p);
  const cover = Math.max(w / f.world.w, h / f.world.h);
  return (
    <div style={{ position: 'absolute', left: cx - w / 2, top: cy - h / 2, width: w, height: h, borderRadius: radius, overflow: 'hidden',
      transform: `rotate(${lw.rot * p}deg)`, boxShadow: `0 ${18 * k}px ${36 * k}px rgba(0,0,0,${0.35 + 0.2 * p})` }}>
      {/* Uniform "cover" scaling: the content keeps its aspect and the morphing rounded rect clips it. */}
      <div style={{ position: 'absolute', left: (w - f.world.w * cover) / 2, top: (h - f.world.h * cover) / 2, width: f.world.w, height: f.world.h,
        transformOrigin: '0 0', transform: `scale(${cover})`, opacity: contentO }}>
        {f.content(f.world.w, f.world.h)}
      </div>
      <div style={{ position: 'absolute', inset: 0, background: '#050507', opacity: glass * 0.85 }} />
      <div style={{ position: 'absolute', inset: 0, background: cssGradient(lw), opacity: glass }} />
      <div style={{ position: 'absolute', inset: 0, borderRadius: radius, boxShadow: `inset 0 0 0 ${lw.strokeWidth * k * 1.2}px ${lw.stroke}`, opacity: glass * lw.strokeOpacity * 1.6 }} />
    </div>
  );
}

export function Finale({ t }: { t: number; cam: Cam }) {
  if (t < CONVERGE.sidebarA) return null;
  const bgIn = prog(t, LAND - 0.55, LAND, easeOutCubic);
  const locked = t >= LAND;
  const bounce = locked ? 1 + 0.035 * Math.sin(Math.PI * clamp((t - LAND) / 0.35)) * Math.exp(-(t - LAND) * 3) : 1;
  const sweep = locked ? (t - LAND - 0.12) / 0.9 : -1;
  const fadeAll = 1 - prog(t, A['fade-out'], A['fade-out'] + 1.0, easeInOutCubic);
  const word = spring(t, LAND + 0.35, { freq: 1.6, damping: 0.85 });
  const tag = spring(t, LAND + 1.45, { freq: 1.6, damping: 0.85 });
  const det = spring(t, A['final-chord'], { freq: 1.4, damping: 0.9 });
  // A slow push and drifting light keep the end card alive without drawing attention.
  const push = 1 + 0.035 * prog(t, LAND, A['fade-out'] + 1, (p) => p);
  return (
    <div style={{ position: 'absolute', inset: 0, opacity: fadeAll, transform: `scale(${push})`, transformOrigin: '960px 560px' }}>
      {/* soft light behind the mark */}
      <div style={{ position: 'absolute', left: 960 - 420 + Math.sin(t * 0.6) * 40, top: ICON.y + 150 - 330 + Math.cos(t * 0.5) * 18, width: 840, height: 660, borderRadius: '50%',
        background: 'radial-gradient(closest-side, rgba(76,201,240,0.22), rgba(114,9,183,0.12) 55%, rgba(0,0,0,0) 100%)', opacity: bgIn, filter: 'blur(10px)' }} />
      <div style={{ position: 'absolute', left: 0, top: 0, width: 1920, height: 1080, transformOrigin: `${960}px ${ICON.y + 150}px`, transform: `scale(${bounce})` }}>
        {bgIn > 0 && <LogoSvg size={ICON.size} x={ICON.x} y={ICON.y} bg={bgIn} windows={locked ? 1 : 0} shine={1} sweep={sweep} />}
        {FLYERS.map((f) => <FlyerView key={f.key} f={f} t={t} />)}
      </div>
      {/* end card type */}
      <div style={{ position: 'absolute', left: 0, width: 1920, top: 598, textAlign: 'center', fontFamily: FONT, fontWeight: 700, fontSize: 92,
        letterSpacing: lerp(6, -2, clamp(word)), color: '#f4f7ff', opacity: clamp(word), transform: `translateY(${(1 - clamp(word)) * 24}px)` }}>
        WinMux
      </div>
      <div style={{ position: 'absolute', left: 0, width: 1920, top: 718, textAlign: 'center', fontFamily: FONT, fontWeight: 450, fontSize: 34,
        color: 'rgba(214,224,245,0.9)', opacity: clamp(tag), transform: `translateY(${(1 - clamp(tag)) * 16}px)` }}>
        Your windows, in flow.
      </div>
      <div style={{ position: 'absolute', left: 0, width: 1920, top: 808, textAlign: 'center', fontFamily: FONT, fontWeight: 500, fontSize: 21,
        letterSpacing: 0.4, color: 'rgba(170,182,210,0.9)', opacity: clamp(det), transform: `translateY(${(1 - clamp(det)) * 10}px)`, lineHeight: 1.7 }}>
        A tiling window manager for macOS · Preview v0.6.379 · Apple silicon, macOS 13 or later
        <br />
        <span style={{ color: 'rgba(200,214,240,0.95)', fontWeight: 600 }}>github.com/alanzchen/winmux</span>
      </div>
    </div>
  );
}

/** How much the displays have powered down during the converge (0 = on, 1 = off). */
export const convergeDim = (t: number) => prog(t, A.converge + 0.4, LAND - 0.3, easeInOutCubic);
