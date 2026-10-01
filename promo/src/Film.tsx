import React from 'react';
import { AbsoluteFill, useCurrentFrame } from 'remotion';
import { DisplayFrame } from './components/primitives';
import { A, DURATION, FPS, clamp, easeInOutCubic, prog } from './lib/time';
import { FONT } from './components/primitives';
import { RailsAndList, Ghosts, PointerLayer, DisplayLabels } from './film/drag';
import { Finale, convergeDim } from './film/finale';
import { DH, DISPLAYS, DW, SCREEN, camera, cameraSpeed, type Cam } from './film/geometry';
import { Loupes } from './film/overlays';
import { RowSheen, SidebarAContent, SidebarBContent, SidebarCContent, sidebarSlideA } from './film/sidebars';
import { CONVERGE, DrawWindow, chatFlight, chipPulse, clutterDraws, tiledDrawsA, tiledDrawsB, tiledDrawsC } from './film/windows';

// Depth of field on A's windows while the camera studies the sidebar (24-44 s).
const depthBlur = (t: number) => 3.2 * prog(t, 23.2, 24.0) * (1 - prog(t, 43.9, 44.8));

const visible = (cam: Cam, x: number, w: number) => {
  const half = SCREEN.w / 2 / cam.z;
  return x + w + 60 > cam.x - half && x - 60 < cam.x + half;
};

const Sidebar: React.FC<{ x?: number; children: React.ReactNode }> = ({ x = 0, children }) => (
  <div style={{ position: 'absolute', left: x, top: 0, width: 264, height: 884, overflow: 'hidden', borderRadius: '0 14px 14px 0',
    boxShadow: '8px 0 30px rgba(0,0,0,0.25)' }}>
    {children}
  </div>
);

function DisplayA({ t }: { t: number }) {
  const power = prog(t, 0.05, 1.0) * (1 - convergeDim(t));
  const chip = chipPulse(t);
  return (
    <DisplayFrame x={DISPLAYS.A.x} y={DISPLAYS.A.y} w={DW} h={DH} wallpaper="A" power={power} fade={1 - 0.92 * convergeDim(t)} glow="rgba(76,120,255,0.5)">
      <div style={{ position: 'absolute', inset: 0, filter: depthBlur(t) > 0.2 ? `blur(${depthBlur(t)}px) brightness(${1 - depthBlur(t) * 0.04})` : undefined }}>
        {[...clutterDraws(t).filter((d) => !d.over), ...tiledDrawsA(t)].map((d) => <DrawWindow key={d.spec.id} d={d} />)}
      </div>
      {t >= A.snap && t < CONVERGE.sidebarA && (
        <Sidebar x={sidebarSlideA(t)}><SidebarAContent t={t} /><RowSheen t={t} /></Sidebar>
      )}
      {clutterDraws(t).filter((d) => d.over).map((d) => <DrawWindow key={d.spec.id} d={d} />)}
      {chip > 0 && (
        <div style={{ position: 'absolute', left: 127 - 22, top: 822 - 22, width: 44, height: 44, borderRadius: 22,
          boxShadow: `0 0 0 ${2 + chip * 3}px rgba(255,183,3,${0.7 * chip}), 0 0 ${20 * chip}px rgba(255,183,3,${0.6 * chip})` }} />
      )}
      <RailsAndList t={t} />
    </DisplayFrame>
  );
}

// Studio Display and LG UltraFine power on with the drum fill at 47.5-48.0 s.
const flicker = (t: number) => {
  if (t < A.fill) return 0;
  if (t >= A['displays-reveal']) return 1;
  const x = (t - A.fill) / (A['displays-reveal'] - A.fill);
  return clamp(x < 0.25 ? 0.55 : x < 0.5 ? 0.2 : x < 0.75 ? 0.85 : 0.6 + 0.4 * (x - 0.75) * 4);
};

function DisplayB({ t }: { t: number }) {
  const power = flicker(t) * (1 - convergeDim(t));
  return (
    <DisplayFrame x={DISPLAYS.B.x} y={DISPLAYS.B.y} w={DW} h={DH} wallpaper="B" power={power} fade={1 - 0.92 * convergeDim(t)} glow="rgba(60,200,220,0.45)">
      {tiledDrawsB(t).map((d) => <DrawWindow key={d.spec.id} d={d} />)}
      {t < CONVERGE.sidebarB && <Sidebar><SidebarBContent t={t} /></Sidebar>}
    </DisplayFrame>
  );
}

function DisplayC({ t }: { t: number }) {
  const power = flicker(t) * (1 - convergeDim(t));
  return (
    <DisplayFrame x={DISPLAYS.C.x} y={DISPLAYS.C.y} w={DW} h={DH} wallpaper="C" power={power} fade={1 - 0.92 * convergeDim(t)} glow="rgba(240,90,160,0.4)">
      {tiledDrawsC(t).map((d) => <DrawWindow key={d.spec.id} d={d} />)}
      {t < A.converge + 1.2 && <Sidebar><SidebarCContent /></Sidebar>}
    </DisplayFrame>
  );
}

const Haze: React.FC<{ t: number }> = ({ t }) => (
  <AbsoluteFill>
    <div style={{ position: 'absolute', inset: 0, background: 'radial-gradient(120% 80% at 50% 45%, #0d1020 0%, #06070c 55%, #030307 100%)' }} />
    <div style={{ position: 'absolute', left: 200 + Math.sin(t * 0.07) * 80, top: 120, width: 900, height: 700, borderRadius: '50%',
      background: 'radial-gradient(closest-side, rgba(67,97,238,0.16), rgba(67,97,238,0))', filter: 'blur(20px)' }} />
    <div style={{ position: 'absolute', left: 900 + Math.cos(t * 0.05) * 90, top: 380, width: 1000, height: 760, borderRadius: '50%',
      background: 'radial-gradient(closest-side, rgba(114,9,183,0.13), rgba(114,9,183,0))', filter: 'blur(20px)' }} />
  </AbsoluteFill>
);

/** On-screen disclosure during the spacious displays reveal (no narration over it). */
const DISCLOSURE = { in: 44.6, out: 48.9 };
const Disclosure: React.FC<{ t: number }> = ({ t }) => {
  const o = prog(t, DISCLOSURE.in, DISCLOSURE.in + 0.5) * (1 - prog(t, DISCLOSURE.out - 0.5, DISCLOSURE.out));
  if (o <= 0) return null;
  return (
    <div style={{ position: 'absolute', left: 0, right: 0, top: 956, display: 'flex', justifyContent: 'center', opacity: o,
      transform: `translateY(${(1 - o) * 8}px)` }}>
      <div style={{ padding: '9px 20px', borderRadius: 999, background: 'rgba(8,10,18,0.74)', boxShadow: '0 0 0 1px rgba(255,255,255,0.12)',
        fontFamily: FONT, fontSize: 21, fontWeight: 500, letterSpacing: 0.2, color: 'rgba(232,238,252,0.94)', whiteSpace: 'nowrap' }}>
        WinMux UI rendered with demo data · App windows and display motion illustrated
      </div>
    </div>
  );
};

export const Film: React.FC = () => {
  const frame = useCurrentFrame();
  const t = frame / FPS;
  const cam = camera(t);
  const speed = cameraSpeed(t, FPS);
  const blur = Math.min(5, Math.max(0, (speed - 40) * 0.06));
  const worldOn = t < A['logo-land'] + 0.1;
  const flight = chatFlight(t);
  return (
    <AbsoluteFill style={{ background: '#030307', overflow: 'hidden' }}>
      <Haze t={t} />
      {worldOn && (
        <div style={{ position: 'absolute', left: 0, top: 0, width: 0, height: 0, transformOrigin: '0 0',
          transform: `translate(${SCREEN.w / 2}px, ${SCREEN.h / 2}px) scale(${cam.z}) translate(${-cam.x}px, ${-cam.y}px)`,
          filter: blur > 0.4 ? `blur(${blur}px)` : undefined }}>
          {visible(cam, DISPLAYS.A.x, DW) && <DisplayA t={t} />}
          {t > 44 && visible(cam, DISPLAYS.B.x, DW) && <DisplayB t={t} />}
          {t > 44 && visible(cam, DISPLAYS.C.x, DW) && <DisplayC t={t} />}
          <DisplayLabels t={t} />
          {flight && <DrawWindow d={flight} />}
          <Ghosts t={t} />
          <PointerLayer t={t} />
        </div>
      )}
      <Loupes t={t} cam={cam} />
      <Finale t={t} cam={cam} />
      <AbsoluteFill style={{ pointerEvents: 'none', background: 'radial-gradient(130% 100% at 50% 50%, rgba(0,0,0,0) 60%, rgba(0,0,0,0.45) 100%)' }} />
      <Disclosure t={t} />
      {/* The whole composition, background included, reaches black on the last frame. */}
      <AbsoluteFill style={{ background: '#000', opacity: prog(t, A['fade-out'], DURATION - 1 / FPS, easeInOutCubic) }} />
    </AbsoluteFill>
  );
};
