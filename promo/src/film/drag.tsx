// Pointer, drag ghosts, the display rails and Studio Display's list (world coordinates; A is at 0,0).
import React from 'react';
import { Crop, FONT, Pointer } from '../components/primitives';
import { A, clamp, easeInOutCubic, easeOutCubic, keys, lerp, prog, spring } from '../lib/time';
import { LIST, RAILS, UI, type Rect } from '../lib/ui';
import { DISPLAYS, LIST_X, NAMES, RAILS_X } from './geometry';
import { CLUTTER, RAISES } from './windows';

const H = 884;
type P = { x: number; y: number; o: number; down: number };

/** Pointer path. Keyframes: [t, x, y]; `down` windows mark presses. */
function pointerAt(t: number): P {
  // Act 1: hunting through the pile, clicking title bars as windows are raised.
  if (t < A.snap + 0.4) {
    const pts: Array<[number, number, number]> = [[7.4, 1340, 860]];
    for (const [rt, id] of RAISES) {
      const c = CLUTTER.find((x) => x.id === id)!;
      pts.push([rt, c.r.x + c.r.w * 0.5, c.r.y + 14]);
    }
    pts.push([A.snap - 0.1, pts[pts.length - 1][1], pts[pts.length - 1][2]]);
    const x = keys(t, pts.map(([tt, px]) => [tt, px] as [number, number]));
    const y = keys(t, pts.map(([tt, , py]) => [tt, py] as [number, number]));
    const o = prog(t, 7.3, 7.6) * (1 - prog(t, A.snap, A.snap + 0.3));
    const down = RAISES.some(([rt]) => t >= rt - 0.04 && t < rt + 0.08) ? 1 : 0;
    return { x, y, o, down };
  }
  // Act 3 (display A).
  if (t < 46) {
    const k: Array<[number, number, number]> = [
      [26.8, 420, 470], [28.35, 150, 312], [28.9, 160, 318], [31.3, 170, 330], [32.85, 127, 820], [33.4, 127, 820],
      [34.7, 90, 812], [35.4, 36, 821], [35.9, 40, 800], [37.0, 120, 460], [37.85, 29, 395], [38.4, 40, 400],
      [39.9, 110, 330], [40.4, 64, 312], [41.85, 214, 106], [42.4, 220, 112],
    ];
    const x = keys(t, k.map(([tt, px]) => [tt, px] as [number, number]));
    const y = keys(t, k.map(([tt, , py]) => [tt, py] as [number, number]));
    const o = prog(t, 26.7, 27.0) * (1 - prog(t, 42.3, 42.7));
    const presses = [A['row-click'], A['project-switch'], A['project-back'], A['group-collapse']];
    const down = presses.some((p) => t >= p - 0.05 && t < p + 0.1) || (t >= A['pin-land'] - 1.5 && t < A['pin-land']) ? 1 : 0;
    return { x, y, o, down };
  }
  // Act 4: the cross-display drag.
  const k: Array<[number, number, number]> = [
    [52.3, 200, 560], [52.9, 60, 274], [53.0, 60, 274], [54.0, 250, 300], [56.9, 286, 430], [57.4, 287, 432], [58.0, 287, 431],
    [59.0, 468, 184], [59.5, 470, 185],
  ];
  const x = keys(t, k.map(([tt, px]) => [tt, px] as [number, number]));
  const y = keys(t, k.map(([tt, , py]) => [tt, py] as [number, number]));
  const o = prog(t, 52.2, 52.5) * (1 - prog(t, 59.6, 59.9));
  const down = t >= A['drag-grab'] && t < A.drop ? 1 : 0;
  return { x, y, o, down };
}

const rr = (x: number, y: number, w: number, h: number): Rect => ({ x, y, w, h });
/** Largest uniformly scaled copy of `src` that fits a w x h box, centred. */
const fitUniform = (src: Rect, w: number, h: number): Rect => {
  const k = Math.min(w / src.w, h / src.h);
  return rr((w - src.w * k) / 2, (h - src.h * k) / 2, src.w * k, src.h * k);
};

/** Rails and the destination list, beside A's sidebar during the drag. */
export function RailsAndList({ t }: { t: number }) {
  if (t < A['rails-in'] - 0.05 || t > A.drop + 0.5) return null;
  const exit = prog(t, A.drop + 0.05, A.drop + 0.35, easeInOutCubic);
  const rail = (i: number) => {
    const p = spring(t, A['rails-in'] + i * 0.125, { freq: 2.6, damping: 0.72 });
    const src = i === 0 ? (t >= A['list-open'] ? RAILS.openB : t >= A['rail-hover'] ? RAILS.hoverB : RAILS.idle) : RAILS.idle;
    const x = RAILS_X + i * 32 - (1 - p) * 40 - exit * 30;
    return <Crop key={i} src={src} iw={RAILS.width} ih={H} s={rr(i * 32, 0, 30, H)} d={rr(x, 0, 30, H)} opacity={clamp(p * 1.4) * (1 - exit)} />;
  };
  const open = spring(t, A['list-open'], { freq: 2.4, damping: 0.8 });
  const listW = LIST.width * clamp(open);
  return (
    <>
      {rail(0)}{rail(1)}
      {t >= A['list-open'] && listW > 1 && (
        <div style={{ position: 'absolute', left: LIST_X - exit * 20, top: 0, width: listW, height: H, overflow: 'hidden', opacity: 1 - exit,
          borderRadius: 14, boxShadow: '0 20px 50px rgba(0,0,0,0.35)' }}>
          <Crop src={t >= 59.0 ? LIST.gap : LIST.plain} iw={LIST.width} ih={H} s={rr(0, 0, LIST.width, H)} d={rr(0, 0, LIST.width, H)} />
        </div>
      )}
    </>
  );
}

/** Drag ghosts: Roadmap onto the pins (act 3); Release notes across displays (act 4). */
export function Ghosts({ t }: { t: number }) {
  const out: React.ReactNode[] = [];
  const p = pointerAt(t);
  // Roadmap -> pinned tiles.
  const grab1 = A['pin-land'] - 1.5, land1 = A['pin-land'];
  if (t >= grab1 && t < land1 + 0.3) {
    const lift = spring(t, grab1, { freq: 3, damping: 0.7 });
    const row = rr(10, 294, 244, 36), tile = rr(174, 78, 84, 62);
    const onTile = prog(t, land1 - 0.22, land1 + 0.05, easeInOutCubic);
    const gx = lerp(p.x - 54, tile.x, onTile), gy = lerp(p.y - 18, tile.y, onTile);
    const gw = lerp(244, 84, onTile), gh = lerp(36, 62, onTile);
    const fade = 1 - prog(t, land1 + 0.05, land1 + 0.3);
    out.push(
      <div key="g1" style={{ position: 'absolute', left: gx, top: gy, width: gw, height: gh, opacity: fade, borderRadius: 12 * onTile, overflow: 'visible',
        transform: `scale(${1 + 0.04 * lift * (1 - onTile)})`, filter: `drop-shadow(0 ${10 * lift}px 16px rgba(0,0,0,0.3))` }}>
        {/* Uniform scaling: each image keeps its own aspect, centred in the morphing box. */}
        <Crop state={UI.A04} s={row} d={fitUniform(row, gw, gh)} opacity={1 - onTile} />
        <Crop state={UI.A05} s={tile} d={fitUniform(tile, gw, gh)} opacity={onTile} />
      </div>,
    );
  }
  // Release notes: follows the pointer, drops into the list gap, then travels to Studio Display's sidebar.
  if (t >= A['drag-grab'] && t < A['land-b'] + 0.2) {
    const row = rr(10, 256, 244, 36);
    const lift = spring(t, A['drag-grab'], { freq: 3, damping: 0.7 });
    let x = p.x - 50, y = p.y - 18, w = 244, h = 36, o = 0.92;
    const gapSlot = { x: LIST_X + 10, y: 184 - 18 };
    if (t >= A.drop - 0.12) {
      const q = prog(t, A.drop - 0.12, A.drop + 0.08, easeOutCubic);
      x = lerp(x, gapSlot.x, q); y = lerp(y, gapSlot.y, q);
    }
    if (t >= A.drop + 0.1) {
      const q = prog(t, A.drop + 0.1, A['land-b'], easeInOutCubic);
      const to = { x: DISPLAYS.B.x + 10, y: 256 };
      x = lerp(gapSlot.x, to.x, q); y = lerp(gapSlot.y, to.y, q) - Math.sin(Math.PI * q) * 120;
      o = 0.92 + 0.08 * q;
    }
    o *= 1 - prog(t, A['land-b'] - 0.05, A['land-b'] + 0.15);
    out.push(
      <div key="g2" style={{ position: 'absolute', left: x, top: y, width: w, height: h, opacity: o,
        transform: `scale(${1 + 0.04 * lift})`, filter: 'drop-shadow(0 10px 18px rgba(0,0,0,0.35))' }}>
        <Crop state={UI.A05} s={row} d={rr(0, 0, w, h)} />
      </div>,
    );
  }
  return <>{out}</>;
}

export function PointerLayer({ t }: { t: number }) {
  const p = pointerAt(t);
  return <Pointer x={p.x} y={p.y} opacity={p.o} pressed={p.down} scale={t > 46 ? 1.1 : 1} />;
}

/** Fixture display names under each display during the reveal. */
export function DisplayLabels({ t }: { t: number }) {
  const o = prog(t, A['displays-reveal'] + 0.2, A['displays-reveal'] + 0.8) * (1 - prog(t, 51.0, 51.6));
  if (o <= 0) return null;
  return (
    <>
      {(['A', 'B', 'C'] as const).map((k, i) => (
        <div key={k} style={{ position: 'absolute', left: DISPLAYS[k].x, top: 900 + 64, width: 1440, textAlign: 'center', fontFamily: FONT,
          fontSize: 44, fontWeight: 500, letterSpacing: 0.5, color: 'rgba(220,228,245,0.85)', opacity: o,
          transform: `translateY(${(1 - o) * 12}px)` }}>
          {NAMES[k]}
        </div>
      ))}
    </>
  );
}

export { pointerAt };
