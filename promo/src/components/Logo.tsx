// The WinMux icon, rebuilt from the exact geometry and gradients of resources/winmux-logo.svg
// (winmux repo at ee150c27), so the finale can fly five objects into the real mark.
import React from 'react';

type Stop = [number, string, number];
export type LogoWindow = {
  key: 'A' | 'B' | 'C' | 'D' | 'E'; x: number; y: number; w: number; h: number; rx: number; rot: number;
  vec: [number, number, number, number]; stops: Stop[]; stroke: string; strokeOpacity: number; strokeWidth: number;
};

export const LOGO_WINDOWS: LogoWindow[] = [
  { key: 'A', x: 128, y: 92, w: 180, h: 148, rx: 34, rot: -10, vec: [120, 96, 312, 250], stops: [[0, '#4CC9F0', 0.55], [0.5, '#4361EE', 0.28], [1, '#0B1026', 0.62]], stroke: '#7DE3FF', strokeOpacity: 0.52, strokeWidth: 1.8 },
  { key: 'B', x: 294, y: 84, w: 136, h: 166, rx: 32, rot: 11, vec: [288, 96, 430, 240], stops: [[0, '#FFB703', 0.55], [0.5, '#FB8500', 0.26], [1, '#241000', 0.64]], stroke: '#FFD166', strokeOpacity: 0.5, strokeWidth: 1.8 },
  { key: 'C', x: 96, y: 280, w: 192, h: 138, rx: 36, rot: 8, vec: [88, 282, 280, 414], stops: [[0, '#80ED99', 0.5], [0.5, '#2D6A4F', 0.28], [1, '#03150C', 0.66]], stroke: '#B7FFC8', strokeOpacity: 0.48, strokeWidth: 1.8 },
  { key: 'D', x: 310, y: 274, w: 124, h: 132, rx: 32, rot: -8, vec: [296, 274, 432, 404], stops: [[0, '#F72585', 0.5], [0.5, '#7209B7', 0.27], [1, '#160018', 0.68]], stroke: '#FF8BD1', strokeOpacity: 0.48, strokeWidth: 1.8 },
  { key: 'E', x: 78, y: 186, w: 138, h: 106, rx: 28, rot: -7, vec: [84, 176, 214, 286], stops: [[0, '#FFD6FF', 0.46], [0.5, '#C77DFF', 0.25], [1, '#13001E', 0.64]], stroke: '#E0AAFF', strokeOpacity: 0.48, strokeWidth: 1.7 },
];
// Draw order in the SVG: A, B, C, D, E (E on top).

const hexA = (hex: string, a: number) => {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${a})`;
};
/** CSS approximation of a window's userSpace linear gradient (used while it flies). */
export const cssGradient = (w: LogoWindow) => {
  const [x1, y1, x2, y2] = w.vec;
  const angle = (Math.atan2(x2 - x1, -(y2 - y1)) * 180) / Math.PI - w.rot;
  return `linear-gradient(${angle}deg, ${w.stops.map(([o, c, a]) => `${hexA(c, a)} ${o * 100}%`).join(', ')})`;
};

/** The exact icon as SVG. `parts` fades the background, windows and shine independently. */
export const LogoSvg: React.FC<{ size: number; x: number; y: number; bg?: number; windows?: number; shine?: number; sweep?: number }> = ({
  size, x, y, bg = 1, windows = 1, shine = 1, sweep = -1,
}) => (
  <svg width={size} height={size} viewBox="0 0 512 512" style={{ position: 'absolute', left: x, top: y, overflow: 'visible' }}>
    <defs>
      <radialGradient id="lgBg" cx="0" cy="0" r="1" gradientUnits="userSpaceOnUse" gradientTransform="translate(160 96) rotate(38) scale(440)">
        <stop offset="0" stopColor="#2B2B2B" /><stop offset="0.35" stopColor="#121212" /><stop offset="0.72" stopColor="#070707" /><stop offset="1" stopColor="#000000" />
      </radialGradient>
      {LOGO_WINDOWS.map((w) => (
        <linearGradient key={w.key} id={`lg${w.key}`} x1={w.vec[0]} y1={w.vec[1]} x2={w.vec[2]} y2={w.vec[3]} gradientUnits="userSpaceOnUse">
          {w.stops.map(([o, c, a]) => <stop key={o} offset={o} stopColor={c} stopOpacity={a} />)}
        </linearGradient>
      ))}
      <linearGradient id="lgShine" x1="120" y1="90" x2="416" y2="420" gradientUnits="userSpaceOnUse">
        <stop offset="0" stopColor="#FFFFFF" stopOpacity="0.14" /><stop offset="0.5" stopColor="#FFFFFF" stopOpacity="0.03" /><stop offset="1" stopColor="#000000" stopOpacity="0.3" />
      </linearGradient>
      <linearGradient id="lgSweep" x1="0" y1="0" x2="1" y2="0">
        <stop offset="0" stopColor="#fff" stopOpacity="0" /><stop offset="0.5" stopColor="#fff" stopOpacity="0.55" /><stop offset="1" stopColor="#fff" stopOpacity="0" />
      </linearGradient>
      <filter id="lgShadow" x="52" y="60" width="412" height="406" filterUnits="userSpaceOnUse">
        <feDropShadow dx="0" dy="18" stdDeviation="18" floodColor="#000000" floodOpacity="0.55" />
      </filter>
      <clipPath id="lgClip"><rect width="512" height="512" rx="112" /></clipPath>
    </defs>
    <g clipPath="url(#lgClip)">
      <rect width="512" height="512" rx="112" fill="url(#lgBg)" opacity={bg} />
      <g filter="url(#lgShadow)" opacity={windows}>
        {LOGO_WINDOWS.map((w) => (
          <rect key={w.key} x={w.x} y={w.y} width={w.w} height={w.h} rx={w.rx} fill={`url(#lg${w.key})`} stroke={w.stroke}
            strokeOpacity={w.strokeOpacity} strokeWidth={w.strokeWidth} transform={`rotate(${w.rot} ${w.x + w.w / 2} ${w.y + w.h / 2})`} />
        ))}
      </g>
      <rect x="1.5" y="1.5" width="509" height="509" rx="110.5" stroke="url(#lgShine)" strokeWidth="3" fill="none" opacity={shine * bg} />
      <ellipse cx="256" cy="432" rx="132" ry="24" fill="#000000" fillOpacity={0.35 * bg} />
      {sweep >= 0 && sweep <= 1 && (
        <rect x={-300 + sweep * 1100} y="-50" width="220" height="612" fill="url(#lgSweep)" transform="rotate(18 256 256)" opacity={0.5} />
      )}
    </g>
  </svg>
);
