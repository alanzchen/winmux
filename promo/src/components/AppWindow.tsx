// STYLIZED RECONSTRUCTION (disclosed in docs/provenance.md): neutral app windows drawn in code.
// Traffic lights, a title and abstract skeleton content only; no readable body text, no real apps' UI.
import React from 'react';
import { FONT } from './primitives';

export type WindowKind = 'browser' | 'notes' | 'preview' | 'textedit' | 'terminal' | 'mail' | 'calendar' | 'messages' | 'freeform';

const bars = (seed: number, n: number, min = 0.35, max = 0.95) =>
  Array.from({ length: n }, (_, i) => {
    const s = Math.sin((seed + 1) * 12.9898 + i * 78.233) * 43758.5453;
    return min + (s - Math.floor(s)) * (max - min);
  });

const Line: React.FC<{ w: number | string; h?: number; c?: string; mb?: number; r?: number }> = ({ w, h = 8, c = '#e4e6eb', mb = 10, r = 4 }) => (
  <div style={{ width: w, height: h, background: c, borderRadius: r, marginBottom: mb }} />
);

function Content({ kind, w, h, seed, accent }: { kind: WindowKind; w: number; h: number; seed: number; accent: string }) {
  const lines = bars(seed, 14);
  switch (kind) {
    case 'browser':
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#fff' }}>
          <div style={{ height: 34, background: '#f4f4f6', borderBottom: '1px solid #e2e3e8', display: 'flex', alignItems: 'center', padding: '0 14px', gap: 10 }}>
            <div style={{ width: 16, height: 10, borderRadius: 3, background: '#d5d7dd' }} />
            <div style={{ flex: 1, height: 20, borderRadius: 10, background: '#e6e7ec', margin: '0 12%' }} />
          </div>
          <div style={{ padding: '22px 7%' }}>
            <div style={{ height: Math.min(150, h * 0.26), borderRadius: 10, marginBottom: 20,
              background: `linear-gradient(120deg, ${accent} 0%, ${accent}55 60%, #ffffff00 100%)`, opacity: 0.85 }} />
            <Line w="46%" h={14} c="#cfd3da" mb={16} />
            {lines.slice(0, Math.max(3, Math.floor((h - 260) / 20))).map((p, i) => <Line key={i} w={`${p * 100}%`} />)}
          </div>
        </div>
      );
    case 'notes':
      return (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', background: '#fffdf6' }}>
          <div style={{ width: '30%', background: '#f6f1df', borderRight: '1px solid #ece4c8', padding: '16px 12px' }}>
            {lines.slice(0, 7).map((p, i) => (
              <div key={i} style={{ padding: '8px 8px', borderRadius: 6, marginBottom: 4, background: i === 1 ? '#f5c13d55' : 'transparent' }}>
                <Line w={`${60 + p * 30}%`} h={7} c="#d8cfae" mb={6} /><Line w={`${40 + p * 20}%`} h={6} c="#e6ddbf" mb={0} />
              </div>
            ))}
          </div>
          <div style={{ flex: 1, padding: '26px 6%' }}>
            <Line w="40%" h={14} c="#d9cfa8" mb={18} />
            {lines.map((p, i) => <Line key={i} w={`${p * 100}%`} c="#ece6d2" />)}
          </div>
        </div>
      );
    case 'preview':
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#2b2c31', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
          <div style={{ width: '72%', height: '72%', borderRadius: 8, overflow: 'hidden', position: 'relative', boxShadow: '0 10px 30px rgba(0,0,0,0.5)',
            background: `linear-gradient(135deg, ${accent} 0%, #f7b733 55%, #fc4a1a 100%)` }}>
            <div style={{ position: 'absolute', left: '12%', top: '18%', width: '38%', height: '46%', borderRadius: '50%', background: 'rgba(255,255,255,0.28)' }} />
            <div style={{ position: 'absolute', right: '10%', bottom: '12%', width: '44%', height: '30%', borderRadius: 14, background: 'rgba(20,20,40,0.28)' }} />
          </div>
        </div>
      );
    case 'textedit':
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#f0f0f2' }}>
          <div style={{ position: 'absolute', left: '8%', right: '8%', top: 18, bottom: 0, background: '#fff', boxShadow: '0 0 0 1px #e3e4e8', padding: '30px 8%' }}>
            <Line w="52%" h={16} c="#cfd2d8" mb={20} />
            {lines.concat(lines).slice(0, Math.max(4, Math.floor((h - 120) / 19))).map((p, i) => <Line key={i} w={`${p * 100}%`} />)}
          </div>
        </div>
      );
    case 'terminal':
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#15171c', padding: '18px 20px' }}>
          {lines.concat(lines).slice(0, Math.max(4, Math.floor((h - 60) / 20))).map((p, i) => (
            <div key={i} style={{ display: 'flex', gap: 8, marginBottom: 11 }}>
              <div style={{ width: 10, height: 9, borderRadius: 2, background: i % 4 === 0 ? '#57d68d' : '#3d4250' }} />
              <div style={{ width: `${p * 40}%`, height: 9, borderRadius: 2, background: i % 3 === 0 ? '#5ea8ff88' : '#8b93a766' }} />
              <div style={{ width: `${p * 25}%`, height: 9, borderRadius: 2, background: '#8b93a733' }} />
            </div>
          ))}
        </div>
      );
    case 'mail':
      return (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', background: '#fff' }}>
          <div style={{ width: '38%', borderRight: '1px solid #e6e7eb', padding: '10px 0' }}>
            {lines.slice(0, 8).map((p, i) => (
              <div key={i} style={{ display: 'flex', gap: 10, padding: '10px 14px', background: i === 0 ? `${accent}22` : 'transparent' }}>
                <div style={{ width: 26, height: 26, borderRadius: 13, background: ['#9ec5ff', '#ffc9a3', '#b8e6c1', '#e0c3ff'][i % 4], flexShrink: 0 }} />
                <div style={{ flex: 1 }}><Line w={`${50 + p * 40}%`} h={7} c="#cfd3da" mb={7} /><Line w={`${70 + p * 20}%`} h={6} mb={0} /></div>
              </div>
            ))}
          </div>
          <div style={{ flex: 1, padding: '26px 5%' }}>
            <Line w="55%" h={14} c="#cfd3da" mb={18} />
            {lines.map((p, i) => <Line key={i} w={`${p * 100}%`} />)}
          </div>
        </div>
      );
    case 'calendar': {
      const colors = ['#ff6b6b', '#4dabf7', '#51cf66', '#fcc419', '#b197fc'];
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#fff', padding: '14px 16px' }}>
          <Line w="30%" h={14} c="#d7dae0" mb={14} />
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 6, height: 'calc(100% - 40px)' }}>
            {Array.from({ length: 35 }, (_, i) => (
              <div key={i} style={{ borderRadius: 6, background: '#f5f6f8', position: 'relative', overflow: 'hidden' }}>
                {lines[i % 14] > 0.62 && <div style={{ position: 'absolute', left: 4, right: 4, top: 6, height: 10, borderRadius: 3, background: colors[i % 5], opacity: 0.8 }} />}
              </div>
            ))}
          </div>
        </div>
      );
    }
    case 'messages':
      return (
        <div style={{ position: 'absolute', inset: 0, display: 'flex', background: '#fff' }}>
          <div style={{ width: '32%', background: '#f6f6f8', borderRight: '1px solid #e7e7ea', padding: '12px 10px' }}>
            {lines.slice(0, 7).map((p, i) => (
              <div key={i} style={{ display: 'flex', gap: 9, padding: '9px 8px', borderRadius: 8, background: i === 0 ? '#1f7aff' : 'transparent', marginBottom: 2 }}>
                <div style={{ width: 24, height: 24, borderRadius: 12, background: i === 0 ? '#ffffffaa' : ['#b8e6c1', '#9ec5ff', '#ffc9a3'][i % 3], flexShrink: 0 }} />
                <div style={{ flex: 1 }}><Line w={`${45 + p * 40}%`} h={7} c={i === 0 ? '#ffffffcc' : '#cfd3da'} mb={6} /><Line w={`${65 + p * 25}%`} h={6} c={i === 0 ? '#ffffff88' : '#e4e6eb'} mb={0} /></div>
              </div>
            ))}
          </div>
          <div style={{ flex: 1, padding: '22px 5%', display: 'flex', flexDirection: 'column', gap: 12 }}>
            {lines.slice(0, Math.max(4, Math.floor((h - 80) / 58))).map((p, i) => (
              <div key={i} style={{ alignSelf: i % 3 === 1 ? 'flex-end' : 'flex-start', width: `${30 + p * 35}%`, height: 34 + (i % 2) * 12, borderRadius: 17,
                background: i % 3 === 1 ? accent : '#e9e9eb' }} />
            ))}
          </div>
        </div>
      );
    case 'freeform':
      return (
        <div style={{ position: 'absolute', inset: 0, background: '#fbfbfd',
          backgroundImage: 'radial-gradient(#d9dce3 1.2px, transparent 1.2px)', backgroundSize: '22px 22px' }}>
          {[['12%', '16%', '#ffe066'], ['46%', '12%', '#8ce99a'], ['30%', '52%', '#a5d8ff'], ['64%', '48%', '#ffc9c9']].map(([l, tp, c], i) => (
            <div key={i} style={{ position: 'absolute', left: l, top: tp, width: '22%', height: '26%', background: c, borderRadius: 6,
              boxShadow: '0 4px 10px rgba(0,0,0,0.12)', transform: `rotate(${[-3, 2, -1, 3][i]}deg)` }} />
          ))}
          <svg style={{ position: 'absolute', inset: 0 }} width="100%" height="100%" viewBox="0 0 100 100" preserveAspectRatio="none">
            <path d="M34 30 C 42 30, 44 24, 48 24" stroke="#adb5bd" strokeWidth={0.5} fill="none" />
            <path d="M40 58 C 50 60, 56 60, 64 58" stroke="#adb5bd" strokeWidth={0.5} fill="none" />
          </svg>
        </div>
      );
  }
}

export const ACCENTS: Record<WindowKind, string> = {
  browser: '#2f80ff', notes: '#f5c13d', preview: '#6a5cff', textedit: '#9aa0a6', terminal: '#1b1d22',
  mail: '#2f80ff', calendar: '#ff4d4f', messages: '#34c759', freeform: '#2bb3c0',
};

/** A window drawn at its natural size (nw x nh); parents position/scale it with transforms. */
export const AppWindow: React.FC<{
  kind: WindowKind; title: string; nw: number; nh: number; active?: boolean; seed?: number; contentOpacity?: number; dark?: boolean;
}> = ({ kind, title, nw, nh, active = true, seed = 1, contentOpacity = 1 }) => {
  const tb = kind === 'terminal' ? '#22252c' : '#f3f3f5';
  const light = (c: string) => (active ? c : '#cfd0d4');
  return (
    <div style={{ position: 'absolute', left: 0, top: 0, width: nw, height: nh, borderRadius: 14, overflow: 'hidden', background: '#fff',
      boxShadow: active ? '0 26px 60px rgba(0,0,0,0.42), 0 0 0 1px rgba(0,0,0,0.18)' : '0 18px 40px rgba(0,0,0,0.32), 0 0 0 1px rgba(0,0,0,0.16)' }}>
      <div style={{ position: 'absolute', left: 0, right: 0, top: 30, bottom: 0, opacity: contentOpacity }}>
        <Content kind={kind} w={nw} h={nh - 30} seed={seed} accent={ACCENTS[kind]} />
      </div>
      <div style={{ position: 'absolute', left: 0, right: 0, top: 0, height: 30, background: tb, borderBottom: kind === 'terminal' ? '1px solid #111' : '1px solid #e1e2e6',
        display: 'flex', alignItems: 'center' }}>
        <div style={{ display: 'flex', gap: 8, paddingLeft: 13 }}>
          {['#ff5f57', '#febc2e', '#28c840'].map((c) => (
            <div key={c} style={{ width: 12, height: 12, borderRadius: 6, background: light(c), boxShadow: 'inset 0 0 0 0.5px rgba(0,0,0,0.18)' }} />
          ))}
        </div>
        <div style={{ position: 'absolute', left: 80, right: 80, textAlign: 'center', fontFamily: FONT, fontSize: 13, fontWeight: 600,
          color: kind === 'terminal' ? (active ? '#d7dae0' : '#7d828c') : active ? '#3a3b40' : '#9a9ba1', whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis' }}>
          {title}
        </div>
      </div>
    </div>
  );
};
