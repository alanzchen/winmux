// Composites the authentic sidebar renders over time. Rows and tiles move between states by slicing
// the renders at the harness's exported frames (FLIP), never by cross-dissolving whole panels.
import React from 'react';
import { Crop, Full, lerpRect } from '../components/primitives';
import { A, clamp, easeInOutCubic, easeOutCubic, lerp, prog, spring } from '../lib/time';
import { SIDEBAR, UI, rect, type Rect, type UIState } from '../lib/ui';
import { CLUTTER, landTime } from './windows';

type Item = { from: Rect; to: Rect; src?: 'before' | 'after'; fade?: 'in' | 'out'; t0?: number; t1?: number; radius?: number };
export const TILE_RADIUS = 12; // pinned tiles' corner radius in the renders (points)

/** Moves slices of `before` to their places in `after`; hands off to `after` at p = 1. */
export const Morph: React.FC<{ before: UIState; after: UIState; p: number; region: Rect; items: Item[]; patch?: Rect }> = ({
  before, after, p, region, items, patch = { x: 0, y: 640, w: 264, h: 60 },
}) => {
  if (p <= 0) return <Full state={before} />;
  if (p >= 1) return <Full state={after} />;
  return (
    <>
      <Full state={after} />
      <Crop state={after} s={patch} d={region} />
      {items.map((it, i) => {
        const q = clamp((p - (it.t0 ?? 0)) / ((it.t1 ?? 1) - (it.t0 ?? 0)));
        const e = easeInOutCubic(q);
        const r = lerpRect(it.from, it.to, e);
        const opacity = it.fade === 'out' ? 1 - e : it.fade === 'in' ? e : 1;
        const src = it.src === 'after' ? it.to : it.from;
        const style = it.radius ? { borderRadius: it.radius } : undefined;
        // Scale stays uniform: a slice whose height collapses is clipped at its native size, never squashed.
        if (Math.abs(r.w - src.w) > 0.01 || Math.abs(r.h - src.h) > 0.01) {
          return (
            <div key={i} style={{ position: 'absolute', left: r.x, top: r.y, width: r.w, height: r.h, overflow: 'hidden', opacity, ...style }}>
              <Crop state={it.src === 'after' ? after : before} s={src} d={{ x: 0, y: 0, w: src.w, h: src.h }} />
            </div>
          );
        }
        return <Crop key={i} state={it.src === 'after' ? after : before} s={src} d={r} opacity={opacity} style={style} />;
      })}
    </>
  );
};

const R = (x: number, y: number, w: number, h: number): Rect => ({ x, y, w, h });
const shift = (r: Rect, dy: number, dx = 0): Rect => ({ ...r, x: r.x + dx, y: r.y + dy });
// Full-width strips (rows include their hover/selection capsules).
const strip = (y: number, h = 38) => R(0, y - 1, 264, h);

// ---------- display A ----------
const EMPTY_SLOT = R(174, 78, 84, 62);     // A01's empty third pin slot
const EMPTY_BG = R(0, 600, 264, 36);       // plain panel background
const CARD_BG = R(196, 419, 48, 28);       // plain group-card background (right of "Changelog")

function RevealA({ t }: { t: number }) {
  // A01 with rows hidden until their windows land.
  const s = UI.A01f1;
  const covers: React.ReactNode[] = [];
  const reveal = (id: string) => clamp((t - (landTime(id) - 0.1)) / 0.16);
  const pins: Array<[string, string]> = [['inbox', 'pin-mail'], ['week', 'pin-cal']];
  for (const [id, name] of pins) {
    const r = rect(s, name), o = 1 - reveal(id);
    if (o > 0) covers.push(<Crop key={name} state={s} s={EMPTY_SLOT} d={r} opacity={o} />);
  }
  for (const [id, name] of [['release', 'release'], ['roadmap', 'roadmap'], ['build', 'build']]) {
    const r = strip(rect(s, name).y), o = 1 - reveal(id);
    if (o > 0) covers.push(<Crop key={name} state={s} s={EMPTY_BG} d={r} opacity={o} />);
  }
  // Group card: appears with its first member; later members fade in on the card.
  const cardO = 1 - reveal('changelog');
  for (const [id, name] of [['store', 'store'], ['press', 'press']]) {
    const r = rect(s, name), o = 1 - reveal(id);
    if (o > 0) covers.push(<Crop key={name} state={s} s={CARD_BG} d={R(r.x + 4, r.y + 2, r.w - 8, r.h - 4)} opacity={o} />);
  }
  if (cardO > 0) covers.push(<Crop key="card" state={s} s={EMPTY_BG} d={R(0, 368, 264, 172)} opacity={cardO} />);
  return <><Full state={s} />{covers}</>;
}

/** Display A's sidebar content at time t (sidebar-local coordinates). */
export function SidebarAContent({ t }: { t: number }) {
  if (t < A.snap + 1.4) return <RevealA t={t} />;
  // Focus hops: only the Design review row's segment highlight changes.
  if (t < A['row-click']) {
    const s = t >= A['focus-1'] && t < A['focus-2'] ? UI.A01f2 : t >= A['focus-2'] && t < A['focus-3'] ? UI.A01f3 : UI.A01f1;
    return <Full state={s} />;
  }
  // Click Roadmap: the selection moves (a quick state change, as in the app).
  if (t < A['project-switch']) {
    const p = prog(t, A['row-click'], A['row-click'] + 0.12);
    return <><Full state={UI.A01f1} /><Full state={UI.A02} opacity={p} /></>;
  }
  // Project switch: the panel pages to Writing and back.
  if (t < A['project-back'] + 0.6) {
    const out = prog(t, A['project-switch'], A['project-switch'] + 0.5, easeInOutCubic);
    const back = prog(t, A['project-back'], A['project-back'] + 0.5, easeInOutCubic);
    const p = out - back; // 0 = Launch, 1 = Writing
    return (
      <div style={{ position: 'absolute', inset: 0, overflow: 'hidden', borderRadius: '0 14px 14px 0' }}>
        <Full state={UI.A02} x={-SIDEBAR.w * p} />
        <Full state={UI.A03} x={SIDEBAR.w * (1 - p)} />
      </div>
    );
  }
  // Group collapse: member rows fold up under the header.
  if (t < A['pin-land'] - 1.5) {
    const p = prog(t, A['group-collapse'], A['group-collapse'] + 0.42, easeInOutCubic);
    if (p <= 0) return <Full state={UI.A02} />;
    if (p >= 1) return <Full state={UI.A04} />;
    const top = 369, be = 537, bc = 421; // card top, expanded bottom, collapsed bottom
    const h = lerp(be - top, bc - top, p);
    return (
      <>
        <Full state={UI.A04} />
        <Crop state={UI.A04} s={EMPTY_BG} d={R(0, top, 264, be - top + 4)} opacity={1} />
        <div style={{ position: 'absolute', left: 0, top, width: 264, height: h, overflow: 'hidden' }}>
          {/* member rows tuck up under the header (their own clip starts below it) */}
          <div style={{ position: 'absolute', left: 0, top: 46, width: 264, height: Math.max(0, h - 46 - 10), overflow: 'hidden' }}>
            <Crop state={UI.A02} s={R(0, top + 46, 264, be - top - 46)} d={R(0, -(be - bc) * p * 0.95, 264, be - top - 46)} opacity={1 - 0.8 * p} />
          </div>
          <Crop state={UI.A02} s={R(0, top, 264, 46)} d={R(0, 0, 264, 46)} />
          <Crop state={UI.A02} s={R(0, be - 12, 264, 12)} d={R(0, h - 12, 264, 12)} />
        </div>
        <Crop state={UI.A04} s={R(0, top, 264, 46)} d={R(0, top, 264, 46)} opacity={clamp((p - 0.45) / 0.55)} />
      </>
    );
  }
  // Pin: Roadmap is dragged onto the pinned tiles (source dims), then the list closes up.
  if (t < A['drag-grab']) {
    const grab = A['pin-land'] - 1.5, land = A['pin-land'];
    if (t < grab) return <Full state={UI.A04} />;
    if (t < land) return <Full state={UI.A04b} />;
    const p = prog(t, land, land + 0.38, easeOutCubic);
    return (
      <Morph before={UI.A04b} after={UI.A05} p={p} region={R(0, 292, 264, 250)} items={[
        { from: strip(294), to: R(0, 293, 264, 0.01), fade: 'out' },
        { from: strip(332), to: strip(294) },
        { from: R(0, 368, 264, 60), to: R(0, 330, 264, 60) },
      ]} />
    );
  }
  // Cross-display drag: the dragged tab's row dims; after the drop it leaves and the list closes up.
  if (t < A['share-on']) {
    if (t < A.drop) return <Full state={UI.A06} />;
    const p = prog(t, A.drop, A.drop + 0.36, easeOutCubic);
    return (
      <Morph before={UI.A06} after={UI.A07} p={p} region={R(0, 254, 264, 250)} items={[
        { from: strip(256), to: R(0, 255, 264, 0.01), fade: 'out' },
        { from: strip(294), to: strip(256) },
        { from: R(0, 330, 264, 60), to: R(0, 292, 264, 60) },
      ]} />
    );
  }
  return <SharedPinsA t={t} />;
}

const TILE = (x: number, y: number) => R(x, y, 84, 62);
/** Where the pointer carries Team chat before release: at Mail's leading edge, slightly raised. */
export const DRAG_END = { dx: 18, dy: 66 };
/** A's pins once sharing is on: Team chat joins from the other display, is clicked here, then reordered. */
function SharedPinsA({ t }: { t: number }) {
  const on = A['share-on'];
  if (t < on + 0.55) {
    const p = prog(t, on, on + 0.55, easeInOutCubic);
    return (
      <Morph before={UI.A07} after={UI.A08} p={p} region={R(0, 138, 264, 420)} items={[
        { from: R(0, 172, 264, 44), to: R(0, 234, 264, 44) },
        { from: strip(218), to: strip(280) },
        { from: strip(256), to: strip(318) },
        { from: R(0, 292, 264, 64), to: R(0, 354, 264, 64) },
        // Team chat's tile slides in from the side where its display is.
        { from: shift(TILE(6, 140), 0, 300), to: TILE(6, 140), src: 'after', t0: 0.15, t1: 1, radius: TILE_RADIUS },
      ]} patch={R(0, 640, 264, 60)} />
    );
  }
  if (t < A['pin-arrives']) return <Full state={UI.A08} />;
  if (t < A['pin-arrives'] + 0.14) {
    const p = prog(t, A['pin-arrives'], A['pin-arrives'] + 0.14);
    return <><Full state={UI.A08} /><Full state={UI.A09} opacity={p} /></>;
  }
  // The pointer drags Team chat to the front; the other tiles make room on release.
  if (t < A.reorder) {
    if (t < 72.9) return <Full state={UI.A09} />;
    const q = prog(t, 72.9, 73.85, easeInOutCubic), lift = prog(t, 72.9, 73.1);
    return (
      <>
        <Full state={UI.A09} />
        <Crop state={UI.A09} s={R(100, 150, 70, 40)} d={TILE(6, 140)} />
        <Crop state={UI.A09} s={TILE(6, 140)} d={{ ...TILE(6 - DRAG_END.dx * q, 140 - DRAG_END.dy * q), x: 6 - DRAG_END.dx * q + 4 * Math.sin(Math.PI * q) }}
          style={{ transform: `scale(${1 + 0.05 * lift})`, filter: `drop-shadow(0 ${8 * lift}px 12px rgba(0,0,0,0.28))`, zIndex: 3, borderRadius: TILE_RADIUS }} />
      </>
    );
  }
  const p = spring(t, A.reorder, { freq: 2.4, damping: 0.8 });
  return <TileReorder before={UI.A09} after={UI.A10} p={p} chatFrom={TILE(6 - DRAG_END.dx, 140 - DRAG_END.dy)} />;
}

/** The four shared tiles move to their new places together. */
export const TileReorder: React.FC<{ before: UIState; after: UIState; p: number; chatFrom?: Rect }> = ({ before, after, p, chatFrom }) => {
  if (p >= 0.999) return <Full state={after} />;
  const moves: Array<[Rect, Rect, Rect?]> = [
    [TILE(6, 140), TILE(6, 78), chatFrom], // Team chat -> first (source crop, destination, optional start)
    [TILE(6, 78), TILE(90, 78)],   // Mail
    [TILE(90, 78), TILE(174, 78)], // Calendar
    [TILE(174, 78), TILE(6, 140)], // Roadmap -> second row
  ];
  const q = clamp(p, 0, 1.08);
  return (
    <>
      <Full state={after} />
      <Crop state={after} s={R(180, 150, 70, 40)} d={R(0, 70, 264, 136)} />
      {moves.map(([a, b, from], i) => (
        <Crop key={i} state={before} s={a} d={{ x: lerp((from ?? a).x, b.x, q), y: lerp((from ?? a).y, b.y, q) - Math.sin(Math.PI * clamp(q)) * (from ? 0 : i === 0 ? 18 : 6), w: 84, h: 62 }}
          style={{ zIndex: i === 0 ? 2 : 1, borderRadius: TILE_RADIUS, filter: i === 0 ? `drop-shadow(0 ${6 * Math.sin(Math.PI * clamp(q))}px 10px rgba(0,0,0,0.25))` : undefined }} />
      ))}
    </>
  );
};

// ---------- display B ----------
export function SidebarBContent({ t }: { t: number }) {
  if (t < A['land-b'] - 0.15) return <Full state={UI.B01} />;
  if (t < A['share-on']) {
    const p = prog(t, A['land-b'] - 0.15, A['land-b'] + 0.25, easeOutCubic);
    return (
      <Morph before={UI.B01} after={UI.B02} p={p} region={R(0, 254, 264, 200)} items={[
        { from: strip(256), to: strip(294) },
        { from: strip(294), to: strip(332) },
        { from: strip(256), to: strip(256), src: 'after', fade: 'in', t0: 0.35, t1: 1 },
      ]} />
    );
  }
  const on = A['share-on'];
  if (t < on + 0.55) {
    const p = prog(t, on, on + 0.55, easeInOutCubic);
    return (
      <Morph before={UI.B02} after={UI.B03} p={p} region={R(0, 70, 264, 380)} items={[
        { from: TILE(6, 78), to: TILE(6, 140), radius: TILE_RADIUS },
        { from: R(0, 172, 264, 44), to: R(0, 234, 264, 44) },
        { from: strip(218), to: strip(280) },
        { from: strip(256), to: strip(318) },
        { from: strip(294), to: strip(356) },
        { from: strip(332), to: strip(394) },
        // The pins that live on A slide in from A's side.
        { from: shift(TILE(6, 78), 0, -300), to: TILE(6, 78), src: 'after', t0: 0.1, t1: 0.9, radius: TILE_RADIUS },
        { from: shift(TILE(90, 78), 0, -300), to: TILE(90, 78), src: 'after', t0: 0.15, t1: 0.95, radius: TILE_RADIUS },
        { from: shift(TILE(174, 78), 0, -300), to: TILE(174, 78), src: 'after', t0: 0.2, t1: 1, radius: TILE_RADIUS },
      ]} />
    );
  }
  const clickLeaves = A['pin-click'] + 0.45;
  if (t < clickLeaves) return <Full state={UI.B03} />;
  if (t < A.reorder) {
    const p = prog(t, clickLeaves, clickLeaves + 0.14);
    return <><Full state={UI.B03} /><Full state={UI.B04} opacity={p} /></>;
  }
  const p = spring(t, A.reorder, { freq: 2.4, damping: 0.8 });
  return <TileReorder before={UI.B04} after={UI.B05} p={p} />;
}

export function SidebarCContent() {
  return <Full state={UI.C01} />;
}

/** A restrained light sheen that passes down the rows on eighth notes as the camera arrives (film lighting, not UI). */
export function RowSheen({ t }: { t: number }) {
  const t0 = A['push-in-land'] + 0.5, t1 = t0 + 1.6;
  if (t < t0 || t > t1) return null;
  const p = (t - t0) / (t1 - t0);
  const y = -120 + p * 760;
  return (
    <div style={{ position: 'absolute', left: 0, top: y, width: 264, height: 120, pointerEvents: 'none', mixBlendMode: 'screen',
      background: 'linear-gradient(180deg, rgba(255,255,255,0) 0%, rgba(255,255,255,0.22) 50%, rgba(255,255,255,0) 100%)',
      opacity: Math.sin(Math.PI * p) }} />
  );
}

/** The sidebar's slide-in at the snap (A only). */
export const sidebarSlideA = (t: number) => (t < A.snap ? -300 : -300 * (1 - spring(t, A.snap, { freq: 2.1, damping: 0.82 })));

export { CLUTTER };
