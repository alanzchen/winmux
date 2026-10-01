import React from 'react';
import { AppWindow, type WindowKind } from '../components/AppWindow';
import { A, POPS, clamp, easeInCubic, easeInOutCubic, easeOutCubic, lerp, prog, spring } from '../lib/time';
import { UI, rect, type Rect } from '../lib/ui';
import { DESIGN_TILES, DISPLAYS, TILE_AREA } from './geometry';

export type WinSpec = { id: string; kind: WindowKind; title: string; seed: number };
type Dest = { kind: 'tile' | 'row' | 'right' | 'chip'; rect?: Rect };
type Clutter = WinSpec & { r: Rect; rot: number; pop: number; dest: Dest };

const row = (name: string) => rect(UI.A01f1, name);
const WRITING_CHIP = { x: 127, y: 822 };

// Pile-up layout on display A (hand-placed for composition), in pop order.
const C: Array<[string, WindowKind, string, number, number, number, number, number, Dest]> = [
  ['release', 'browser', 'Release notes', 380, 150, 620, 420, -2, { kind: 'row', rect: row('release') }],
  ['inbox', 'mail', 'Inbox', 60, 90, 560, 380, 3, { kind: 'row', rect: row('pin-mail') }],
  ['roadmap', 'notes', 'Roadmap', 820, 60, 520, 400, -3, { kind: 'row', rect: row('roadmap') }],
  ['prototype', 'browser', 'Prototype', 150, 380, 640, 440, 2, { kind: 'tile', rect: DESIGN_TILES.prototype }],
  ['week', 'calendar', 'Week', 900, 420, 480, 380, 4, { kind: 'row', rect: row('pin-cal') }],
  ['chat', 'messages', 'Team chat', 560, 40, 420, 340, -4, { kind: 'right' }],
  ['mockups', 'preview', 'Mockups', 40, 470, 520, 360, -2, { kind: 'tile', rect: DESIGN_TILES.mockups }],
  ['build', 'terminal', 'build', 700, 520, 520, 300, 3, { kind: 'row', rect: row('build') }],
  ['specs', 'textedit', 'Specs', 1000, 200, 400, 480, -3, { kind: 'tile', rect: DESIGN_TILES.specs }],
  ['changelog', 'textedit', 'Changelog', 260, 40, 420, 320, 5, { kind: 'row', rect: row('changelog') }],
  ['docs', 'browser', 'Docs', 620, 300, 560, 380, -5, { kind: 'right' }],
  ['store', 'browser', 'Store listing', 80, 250, 520, 360, 4, { kind: 'row', rect: row('store') }],
  ['chapter', 'textedit', 'Chapter 3', 880, 560, 460, 300, -2, { kind: 'chip' }],
  ['press', 'preview', 'Press kit', 420, 520, 480, 340, -4, { kind: 'row', rect: row('press') }],
  ['standup', 'notes', 'Standup notes', 1060, 80, 360, 300, 3, { kind: 'right' }],
  ['sketch', 'freeform', 'Sketches', 180, 150, 460, 330, -3, { kind: 'right' }],
  ['outline', 'notes', 'Outline', 720, 180, 420, 320, 6, { kind: 'chip' }],
  ['moodboard', 'freeform', 'Moodboard', 960, 330, 440, 340, -6, { kind: 'right' }],
  ['sources', 'browser', 'Sources', 320, 330, 500, 360, 3, { kind: 'chip' }],
  ['reading', 'browser', 'Reading list', 540, 400, 460, 340, -5, { kind: 'right' }],
];
export const CLUTTER: Clutter[] = C.map(([id, kind, title, x, y, w, h, rot, dest], i) => ({
  id, kind, title, seed: i + 3, r: { x, y, w, h }, rot, pop: POPS[i] ?? POPS[POPS.length - 1], dest,
}));

// The frantic search: windows raised by clicks on the 8ths of bars 4-5.
export const RAISES: Array<[number, string]> = [
  [8.25, 'inbox'], [8.75, 'release'], [9.25, 'week'], [9.75, 'roadmap'], [10.0, 'chat'], [10.25, 'build'],
  [10.5, 'docs'], [10.75, 'prototype'], [11.0, 'specs'], [11.25, 'store'], [11.5, 'press'],
];

/** Row-bound windows land in order (pins first, then rows top to bottom), 16ths apart. */
const ROW_ORDER = ['inbox', 'week', 'release', 'roadmap', 'build', 'changelog', 'store', 'press'];
export const landTime = (id: string) => A.snap + 0.1 + ROW_ORDER.indexOf(id) * 0.0625 + 0.42;

type Draw = { spec: WinSpec; r: Rect; rot: number; scale: number; opacity: number; contentOpacity: number; active: boolean; z: number; over?: boolean };

function lastEventId(t: number) {
  let best = { t: -1, id: '' };
  for (const c of CLUTTER) if (c.pop <= t && c.pop > best.t) best = { t: c.pop, id: c.id };
  for (const [rt, id] of RAISES) if (rt <= t && rt > best.t) best = { t: rt, id };
  return best.id;
}

export function clutterDraws(t: number): Draw[] {
  if (t > A.snap + 1.4) return [];
  const active = t < A.snap ? lastEventId(t) : '';
  const out: Draw[] = [];
  CLUTTER.forEach((c, i) => {
    if (t < c.pop) return;
    const sp = spring(t, c.pop, { freq: 3.2, damping: 0.6 });
    const appear = clamp((t - c.pop) / 0.08);
    let r = { ...c.r, y: c.r.y + (1 - sp) * 26 };
    let rot = c.rot + (1 - sp) * 5;
    let scale = 0.86 + 0.14 * sp;
    let opacity = appear, contentOpacity = 1;
    // raise pulse
    let z = i;
    let lastRaise = -1;
    RAISES.forEach(([rt, id], k) => { if (id === c.id && rt <= t) { z = 100 + k; lastRaise = rt; } });
    if (lastRaise > 0) scale *= 1 + 0.025 * Math.sin(Math.PI * clamp((t - lastRaise) / 0.18));
    // anticipation just before the snap
    const pre = prog(t, A.snap - 0.25, A.snap, easeInOutCubic);
    if (t < A.snap) { scale *= 1 - 0.02 * pre; }
    // the snap
    if (t >= A.snap) {
      const d = c.dest;
      if (d.kind === 'tile') {
        const p = spring(t, A.snap, { freq: 1.7, damping: 0.78 });
        r = { x: lerp(c.r.x, d.rect!.x, p), y: lerp(c.r.y, d.rect!.y, p), w: lerp(c.r.w, d.rect!.w, p), h: lerp(c.r.h, d.rect!.h, p) };
        rot = c.rot * (1 - p); scale = 1; z = 300 + i;
      } else if (d.kind === 'row') {
        const t0 = landTime(c.id) - 0.42;
        const p = prog(t, t0, t0 + 0.42, easeInOutCubic);
        const target = d.rect!;
        const fit = (target.h * 1.25) / c.r.h;
        const cx = lerp(c.r.x + c.r.w / 2, target.x + target.w / 2, p), cy = lerp(c.r.y + c.r.h / 2, target.y + target.h / 2, p) - Math.sin(Math.PI * p) * 40;
        r = { x: cx - c.r.w / 2, y: cy - c.r.h / 2, w: c.r.w, h: c.r.h };
        scale = lerp(1, fit, easeInCubic(p) * 0.6 + p * 0.4);
        rot = c.rot * (1 - p);
        opacity = 1 - clamp((p - 0.62) / 0.38);
        z = 400 + i;
      } else if (d.kind === 'right') {
        const p = prog(t, A.snap + (i % 3) * 0.03, A.snap + 0.55, easeInCubic);
        r = { ...c.r, x: c.r.x + p * 1700 };
        scale = 1 - 0.25 * p; rot = c.rot * (1 - p);
        z = 200 + i;
      } else {
        const p = prog(t, A.snap + 0.06 + (i % 3) * 0.05, A.snap + 0.72, easeInOutCubic);
        const cx = lerp(c.r.x + c.r.w / 2, WRITING_CHIP.x, p), cy = lerp(c.r.y + c.r.h / 2, WRITING_CHIP.y, p) - Math.sin(Math.PI * p) * 60;
        r = { x: cx - c.r.w / 2, y: cy - c.r.h / 2, w: c.r.w, h: c.r.h };
        scale = lerp(1, 0.03, easeInCubic(p)); rot = c.rot + p * 20;
        opacity = 1 - clamp((p - 0.7) / 0.3);
        z = 250 + i;
      }
      if (opacity <= 0.01 && d.kind !== 'tile') return;
    }
    // Windows flying into sidebar rows or the project chip travel above the sidebar panel.
    const over = t >= A.snap && (c.dest.kind === 'row' || c.dest.kind === 'chip');
    out.push({ spec: c, r, rot, scale, opacity, contentOpacity, active: t < A.snap ? c.id === active : c.id === 'prototype', z, over });
  });
  return out.sort((a, b) => a.z - b.z);
}

/** The Writing project's windows pulse the switcher chip as they arrive. */
export const chipPulse = (t: number) => Math.max(0, ...CLUTTER.filter((c) => c.dest.kind === 'chip').map((c, i) => {
  const arrive = A.snap + 0.72 - (2 - i) * 0.0;
  const x = (t - arrive) / 0.35;
  return x <= 0 || x >= 1 ? 0 : Math.sin(Math.PI * x);
}));

export const SPECS: Record<string, WinSpec> = Object.fromEntries(CLUTTER.map((c) => [c.id, { id: c.id, kind: c.kind, title: c.title, seed: c.seed }]));

/** Display A's tiled windows after the snap (the Design review tab, then Roadmap / Chapter 3 / Team chat). */
export function tiledDrawsA(t: number): Draw[] {
  if (t < A.snap + 1.4) return [];
  const out: Draw[] = [];
  const focus = t >= A['focus-1'] && t < A['focus-2'] ? 'mockups' : t >= A['focus-2'] && t < A['focus-3'] ? 'specs' : 'prototype';
  const slide = (t0: number, dir: 1 | -1, inbound: boolean, dur = 0.45) => {
    const p = inbound ? prog(t, t0, t0 + dur, easeOutCubic) : prog(t, t0, t0 + dur * 0.8, easeInCubic);
    return inbound ? (1 - p) * 1240 * dir : -p * 1240 * dir;
  };
  // Design review until the Roadmap click.
  if (t < A['row-click'] + 0.5) {
    const dx = t >= A['row-click'] ? slide(A['row-click'], 1, false) : 0;
    for (const id of ['prototype', 'mockups', 'specs']) {
      const r = DESIGN_TILES[id];
      out.push({ spec: SPECS[id], r: { ...r, x: r.x + dx }, rot: 0, scale: 1, opacity: 1, contentOpacity: 1, active: id === focus, z: 1 });
    }
  }
  // Roadmap: in at the click, out to Writing at the switch, back at the return, out when Team chat arrives.
  const roadmapIn = t >= A['row-click'] && t < A['pin-arrives'] + 0.05;
  if (roadmapIn) {
    let dx = 0;
    if (t < A['project-switch']) dx = slide(A['row-click'], 1, true);
    else if (t < A['project-back']) dx = slide(A['project-switch'], 1, false);
    else dx = slide(A['project-back'], -1, true);
    const leaving = prog(t, A['pin-arrives'] - 0.2, A['pin-arrives'], easeInCubic);
    if (!(t >= A['project-switch'] + 0.4 && t < A['project-back'])) {
      out.push({ spec: SPECS.roadmap, r: { ...TILE_AREA, x: TILE_AREA.x + dx }, rot: 0, scale: 1 - 0.04 * leaving, opacity: 1 - leaving,
        contentOpacity: 1, active: t < A['pin-click'], z: 2 });
    }
  }
  if (t >= A['project-switch'] && t < A['project-back'] + 0.5) {
    const dx = t < A['project-back'] ? slide(A['project-switch'], 1, true) : slide(A['project-back'], -1, false);
    out.push({ spec: SPECS.chapter, r: { ...TILE_AREA, x: TILE_AREA.x + dx }, rot: 0, scale: 1, opacity: 1, contentOpacity: 1, active: true, z: 3 });
  }
  if (t >= A['pin-arrives'] && t < CONVERGE.chatA) {
    out.push({ spec: SPECS.chat, r: TILE_AREA, rot: 0, scale: 1, opacity: 1, contentOpacity: 1, active: true, z: 4 });
  }
  return out;
}

export const CONVERGE = { sidebarA: A.converge, chatA: A.converge + 0.1, sidebarB: A.converge + 0.2, docsB: A.converge + 0.3, moodC: A.converge + 0.4 };

export function tiledDrawsB(t: number): Draw[] {
  const out: Draw[] = [];
  if (t < A['pin-click'] + 0.1) out.push({ spec: SPECS.chat, r: TILE_AREA, rot: 0, scale: 1, opacity: 1, contentOpacity: 1, active: false, z: 1 });
  const fallback = A['pin-click'] + 0.45;
  if (t >= fallback && t < CONVERGE.docsB) {
    const p = prog(t, fallback, fallback + 0.4, easeOutCubic);
    out.push({ spec: SPECS.docs, r: { ...TILE_AREA, x: TILE_AREA.x + (1 - p) * 60 }, rot: 0, scale: 1, opacity: p, contentOpacity: 1, active: false, z: 2 });
  }
  return out;
}
export function tiledDrawsC(t: number): Draw[] {
  return t < CONVERGE.moodC ? [{ spec: SPECS.moodboard, r: TILE_AREA, rot: 0, scale: 1, opacity: 1, contentOpacity: 1, active: false, z: 1 }] : [];
}

/** Team chat's window flies from Studio Display to the clicked display (world coordinates). */
export function chatFlight(t: number): Draw | null {
  const t0 = A['pin-click'] + 0.1, t1 = A['pin-arrives'];
  if (t < t0 || t >= t1) return null;
  const p = easeInOutCubic(clamp((t - t0) / (t1 - t0)));
  const from = { x: DISPLAYS.B.x + TILE_AREA.x, y: TILE_AREA.y }, to = { x: TILE_AREA.x, y: TILE_AREA.y };
  const s = 1 - 0.42 * Math.sin(Math.PI * p);
  const cx = lerp(from.x, to.x, p) + TILE_AREA.w / 2, cy = lerp(from.y, to.y, p) + TILE_AREA.h / 2 - Math.sin(Math.PI * p) * 300;
  return { spec: SPECS.chat, r: { x: cx - TILE_AREA.w / 2, y: cy - TILE_AREA.h / 2, w: TILE_AREA.w, h: TILE_AREA.h }, rot: -3 * Math.sin(Math.PI * p),
    scale: s, opacity: 1, contentOpacity: 1, active: true, z: 999 };
}

export const DrawWindow: React.FC<{ d: Draw }> = ({ d }) => (
  <div style={{ position: 'absolute', left: d.r.x, top: d.r.y, width: d.r.w, height: d.r.h, opacity: d.opacity,
    transform: `rotate(${d.rot}deg) scale(${d.scale})`, transformOrigin: '50% 50%' }}>
    <AppWindow kind={d.spec.kind} title={d.spec.title} nw={d.r.w} nh={d.r.h} active={d.active} seed={d.spec.seed} contentOpacity={d.contentOpacity} />
  </div>
);
