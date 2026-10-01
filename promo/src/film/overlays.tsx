// Screen-space loupes over A's and B's pin grids (shared pins, click-to-bring-here, badge, reorder).
import React from 'react';
import { staticFile } from 'remotion';
import { Crop, FONT, Pointer, lerpRect } from '../components/primitives';
import { A, clamp, easeInOutCubic, keys, lerp, prog, spring } from '../lib/time';
import type { Rect } from '../lib/ui';
import { DISPLAYS, NAMES, rectToScreen, type Cam } from './geometry';
import { DRAG_END, SidebarAContent, SidebarBContent } from './sidebars';

const PINS: Rect = { x: 0, y: 74, w: 264, h: 144 };
const LOUPE = { w: 540, h: 295 };
const IN = 62.6, OUT = 75.2;
const BADGE = { x: 22.3, y: 185.5 }; // Team chat tile's display badge (bottom-leading corner) on Studio Display, measured in the render
const B04_HI = staticFile('ui-hi/B04-after-click@8x.png'); // 8x render of the same state for the close-up

function Loupe({ t, cam, which, box }: { t: number; cam: Cam; which: 'A' | 'B'; box: Rect }) {
  const src = rectToScreen(cam, { ...PINS, x: PINS.x + DISPLAYS[which].x, y: PINS.y + DISPLAYS[which].y });
  const grow = spring(t, IN + (which === 'B' ? 0.08 : 0), { freq: 1.8, damping: 0.8 });
  const shrink = prog(t, OUT, OUT + 0.5, easeInOutCubic);
  const p = clamp(grow) * (1 - shrink);
  if (p <= 0.001) return null;
  const r = lerpRect(src, box, p);
  // Viewport inside the sidebar (points). B zooms onto the badge.
  let view = PINS;
  if (which === 'B') {
    const z = prog(t, 68.9, 69.7, easeInOutCubic) * (1 - prog(t, 71.4, 72.2, easeInOutCubic));
    const vw = lerp(PINS.w, 62, z), vh = vw * (LOUPE.h / LOUPE.w);
    view = { x: lerp(PINS.x, BADGE.x - vw * 0.28, z), y: lerp(PINS.y, BADGE.y - vh * 0.5, z), w: vw, h: vh };
  }
  const k = r.w / view.w;
  const Content = which === 'A' ? SidebarAContent : SidebarBContent;
  const labelO = prog(t, IN + 0.35, IN + 0.7) * (1 - shrink);
  return (
    <>
      {/* tether + source outline */}
      <svg width={1920} height={1080} style={{ position: 'absolute', left: 0, top: 0, opacity: p * 0.9 }}>
        <rect x={src.x - 3} y={src.y - 3} width={src.w + 6} height={src.h + 6} rx={8} fill="none" stroke="rgba(170,210,255,0.8)" strokeWidth={1.5} />
        <line x1={src.x + src.w / 2} y1={src.y + src.h + 3} x2={r.x + r.w * 0.2} y2={r.y} stroke="rgba(170,210,255,0.55)" strokeWidth={1.2} />
      </svg>
      <div style={{ position: 'absolute', left: r.x, top: r.y, width: r.w, height: r.h, borderRadius: 22 * p, overflow: 'hidden',
        boxShadow: '0 30px 70px rgba(0,0,0,0.55), 0 0 0 1.5px rgba(255,255,255,0.35)', background: '#c8e8f0' }}>
        <div style={{ position: 'absolute', left: 0, top: 0, width: 264, height: 884, transformOrigin: '0 0',
          transform: `scale(${k}) translate(${-view.x}px, ${-view.y}px)` }}>
          <Content t={t} />
          {/* During the badge close-up, draw the same state from its 8x render so the badge stays sharp. */}
          {which === 'B' && t > 68.85 && t < 72.25 && (
            <Crop src={B04_HI} iw={264} ih={884} s={{ x: 0, y: 0, w: 264, h: 884 }} d={{ x: 0, y: 0, w: 264, h: 884 }} />
          )}
        </div>
        {which === 'B' && <BadgeCallout t={t} k={k} view={view} />}
        {which === 'A' && <LoupePointer t={t} k={k} view={view} />}
      </div>
      <div style={{ position: 'absolute', left: r.x + 14, top: r.y + r.h - 44, fontFamily: FONT, fontSize: 17, fontWeight: 600, letterSpacing: 0.2,
        color: 'rgba(240,245,255,0.96)', opacity: labelO, display: 'flex', alignItems: 'center', gap: 8, padding: '6px 12px 6px 10px',
        borderRadius: 10, background: 'rgba(10,14,26,0.78)' }}>
        <svg width={20} height={16} viewBox="0 0 20 16"><rect x={1} y={1} width={18} height={11} rx={2} fill="none" stroke="currentColor" strokeWidth={1.6} /><rect x={7} y={13} width={6} height={2} rx={1} fill="currentColor" /></svg>
        {NAMES[which]}
      </div>
    </>
  );
}

function BadgeCallout({ t, k, view }: { t: number; k: number; view: Rect }) {
  const o = prog(t, 69.6, 70.0) * (1 - prog(t, 71.3, 71.6));
  if (o <= 0) return null;
  const bx = (BADGE.x - view.x) * k, by = (BADGE.y - view.y) * k;
  const ring = spring(t, 69.6, { freq: 2, damping: 0.6 });
  return (
    <>
      <div style={{ position: 'absolute', left: bx - 34, top: by - 34, width: 68, height: 68, borderRadius: 34, opacity: o,
        boxShadow: '0 0 0 2px rgba(47,128,255,0.85), 0 0 24px rgba(47,128,255,0.55)', transform: `scale(${0.7 + 0.3 * ring})` }} />
      <div style={{ position: 'absolute', left: bx + 58, top: by - 22, padding: '9px 16px', borderRadius: 12, background: 'rgba(12,16,28,0.86)',
        color: '#eef3ff', fontFamily: FONT, fontSize: 21, fontWeight: 600, whiteSpace: 'nowrap', opacity: o,
        transform: `translateX(${(1 - o) * -10}px)` }}>
        On {NAMES.A}
      </div>
      <div style={{ position: 'absolute', left: bx + 36, top: by - 1, width: 22, height: 2, background: 'rgba(47,128,255,0.85)', opacity: o }} />
    </>
  );
}

/** The pointer inside A's loupe: clicks Team chat (65.0), later drags it to the front (reorder at 74.0). */
function LoupePointer({ t, k, view }: { t: number; k: number; view: Rect }) {
  const chat = { x: 52, y: 176 }; // Team chat tile centre (second row) in points
  const front = { x: chat.x - DRAG_END.dx, y: chat.y - DRAG_END.dy }; // Mail's leading edge (see DRAG_END)
  let pt = { x: 150, y: 250 }, o = 0, down = 0;
  if (t >= 64.3 && t < 66.2) {
    pt = { x: keys(t, [[64.3, 170], [64.95, chat.x]]), y: keys(t, [[64.3, 240], [64.95, chat.y]]) };
    o = prog(t, 64.3, 64.5) * (1 - prog(t, 65.8, 66.2));
    down = t >= A['pin-click'] - 0.04 && t < A['pin-click'] + 0.1 ? 1 : 0;
  }
  if (t >= 72.3 && t < 74.7) {
    pt = { x: keys(t, [[72.3, 160], [72.85, chat.x], [73.9, front.x]]), y: keys(t, [[72.3, 250], [72.85, chat.y], [73.9, front.y]]) };
    o = prog(t, 72.3, 72.5) * (1 - prog(t, 74.3, 74.7));
    down = t >= 72.9 && t < A.reorder ? 1 : 0;
  }
  if (o <= 0) return null;
  return <Pointer x={(pt.x - view.x) * k} y={(pt.y - view.y) * k} opacity={o} pressed={down} scale={1.35} />;
}

/** The two loupes and the link between them. */
export function Loupes({ t, cam }: { t: number; cam: Cam }) {
  if (t < IN - 0.05 || t > OUT + 0.6) return null;
  const boxA: Rect = { x: 330, y: 480, w: LOUPE.w, h: LOUPE.h };
  const boxB: Rect = { x: 1310, y: 480, w: LOUPE.w, h: LOUPE.h };
  // A thin link that draws on as pins become shared.
  const link = prog(t, A['share-on'] - 0.1, A['share-on'] + 0.5, easeInOutCubic) * (1 - prog(t, OUT, OUT + 0.3));
  const dot = prog(t, A['share-on'], A['share-on'] + 0.7);
  const y = boxA.y + LOUPE.h / 2;
  return (
    <div style={{ position: 'absolute', inset: 0 }}>
      <svg width={1920} height={1080} style={{ position: 'absolute', left: 0, top: 0 }}>
        <defs>
          <linearGradient id="lnk" x1="0" x2="1"><stop offset="0" stopColor="#4CC9F0" stopOpacity="0.1" /><stop offset="0.5" stopColor="#9fd8ff" stopOpacity="0.9" /><stop offset="1" stopColor="#4CC9F0" stopOpacity="0.1" /></linearGradient>
        </defs>
        {link > 0 && <line x1={boxA.x + boxA.w} y1={y} x2={boxA.x + boxA.w + (boxB.x - boxA.x - boxA.w) * link} y2={y} stroke="url(#lnk)" strokeWidth={2} />}
        {dot > 0 && dot < 1 && <circle cx={lerp(boxA.x + boxA.w, boxB.x, dot)} cy={y} r={5} fill="#cfeaff" opacity={Math.sin(Math.PI * dot)} />}
        {dot > 0 && dot < 1 && <circle cx={lerp(boxB.x, boxA.x + boxA.w, dot)} cy={y} r={5} fill="#cfeaff" opacity={Math.sin(Math.PI * dot)} />}
      </svg>
      <Loupe t={t} cam={cam} which="A" box={boxA} />
      <Loupe t={t} cam={cam} which="B" box={boxB} />
    </div>
  );
}
