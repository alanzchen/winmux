// Authentic WinMux UI renders (offscreen NSHostingView, 3x) and the frames the harness exported.
// Units: points (1 pt = 1 world unit inside a display).
import { staticFile } from 'remotion';
import A01f1 from '../../public/ui/A01-design-f1.json';
import A01f2 from '../../public/ui/A01-design-f2.json';
import A01f3 from '../../public/ui/A01-design-f3.json';
import A02 from '../../public/ui/A02-roadmap.json';
import A03 from '../../public/ui/A03-writing.json';
import A04 from '../../public/ui/A04-collapsed.json';
import A04b from '../../public/ui/A04b-pin-drop-preview.json';
import A05 from '../../public/ui/A05-pinned.json';
import A06 from '../../public/ui/A06-drag-source.json';
import A07 from '../../public/ui/A07-after-drop.json';
import A08 from '../../public/ui/A08-shared.json';
import A09 from '../../public/ui/A09-after-click.json';
import A10 from '../../public/ui/A10-reordered.json';
import B01 from '../../public/ui/B01-base.json';
import B02 from '../../public/ui/B02-after-drop.json';
import B03 from '../../public/ui/B03-shared.json';
import B04 from '../../public/ui/B04-after-click.json';
import B05 from '../../public/ui/B05-reordered.json';
import C01 from '../../public/ui/C01-base.json';

export type Rect = { x: number; y: number; w: number; h: number };
type Target = Rect & { type: string; name?: string; id?: string; workspace?: string; after?: boolean };
type RenderJson = { name: string; width: number; height: number; targets: Target[] };

const make = (json: RenderJson) => ({
  name: json.name,
  src: staticFile(`ui/${json.name}.png`),
  width: json.width,
  height: json.height,
  targets: json.targets,
});
export type UIState = ReturnType<typeof make>;

export const UI = {
  A01f1: make(A01f1), A01f2: make(A01f2), A01f3: make(A01f3), A02: make(A02), A03: make(A03), A04: make(A04), A04b: make(A04b),
  A05: make(A05), A06: make(A06), A07: make(A07), A08: make(A08), A09: make(A09), A10: make(A10),
  B01: make(B01), B02: make(B02), B03: make(B03), B04: make(B04), B05: make(B05), C01: make(C01),
};

export const RAILS = {
  idle: staticFile('ui/R01-idle.png'),
  hoverB: staticFile('ui/R02-hover-b.png'),
  openB: staticFile('ui/R03-open-b.png'),
  width: 62,
};
export const LIST = { plain: staticFile('ui/L01-list-b.png'), gap: staticFile('ui/L02-list-b-gap.png'), width: 280 };

/** Frame of a tab row or pinned tile (by workspace name) or a group header (by collection id). */
export function rect(state: UIState, name: string): Rect {
  const t = state.targets.find((x) => (x.type === 'workspace' && x.name === name) || (x.type === 'collection' && x.id === name));
  if (!t) throw new Error(`no frame for ${name} in ${state.name}`);
  return { x: t.x, y: t.y, w: t.w, h: t.h };
}
export function maybeRect(state: UIState, name: string): Rect | null {
  try { return rect(state, name); } catch { return null; }
}

export const SIDEBAR = { w: 264, h: 884 };
