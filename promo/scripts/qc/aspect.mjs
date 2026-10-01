// Aspect / uniform-scaling check on the delivered MP4 (measured, not assumed):
// 1) ffprobe SAR/DAR; 2) the WinMux icon on the end card is square (edge-gradient scan);
// 3) macOS traffic-light dots are round (colour segmentation, bounding boxes).
// Usage: node scripts/qc/aspect.mjs <film.mp4>
import { execFileSync } from 'node:child_process';

const mp4 = process.argv[2];
const W = 1920, H = 1080;
const probe = JSON.parse(execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries',
  'stream=width,height,sample_aspect_ratio,display_aspect_ratio', '-of', 'json', mp4], { encoding: 'utf8' })).streams[0];
const frame = (t) => execFileSync('ffmpeg', ['-v', 'error', '-ss', String(t), '-i', mp4, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'], { maxBuffer: 1 << 26 });
const L = (f, x, y) => { const i = (y * W + x) * 3; return 0.2126 * f[i] + 0.7152 * f[i + 1] + 0.0722 * f[i + 2]; };

// Icon: expected square from the end-card geometry (300 px at (810,250), end-card push about (960,560)).
const t = 83.5, push = 1 + 0.035 * ((t - 78) / 8);
const exp = { l: 960 + (810 - 960) * push, r: 960 + (1110 - 960) * push, t: 560 + (250 - 560) * push, b: 560 + (550 - 560) * push };
const f = frame(t);
const edgeAlongRow = (y, x0, x1) => { let best = { g: -1, x: x0 }; for (let x = Math.round(x0); x <= x1; x++) { const g = Math.abs(L(f, x + 1, y) - L(f, x - 1, y)); if (g > best.g) best = { g, x }; } return best.x; };
const edgeAlongCol = (x, y0, y1) => { let best = { g: -1, y: y0 }; for (let y = Math.round(y0); y <= y1; y++) { const g = Math.abs(L(f, x, y + 1) - L(f, x, y - 1)); if (g > best.g) best = { g, y }; } return best.y; };
const midY = Math.round((exp.t + exp.b) / 2), midX = 960;
const left = edgeAlongRow(midY, exp.l - 25, exp.l + 25), right = edgeAlongRow(midY, exp.r - 25, exp.r + 25);
const top = edgeAlongCol(midX, exp.t - 25, exp.t + 25), bottom = edgeAlongCol(midX, exp.b - 25, exp.b + 25);
const icon = { widthPx: right - left, heightPx: bottom - top, ratio: +((right - left) / (bottom - top)).toFixed(4) };

// Traffic lights: segment red/yellow/green dots of the active window in calm, un-blurred frames.
function dots(tt) {
  const g = frame(tt);
  const cls = (i) => {
    const r = g[i], gg = g[i + 1], b = g[i + 2];
    if (r > 220 && gg < 140 && b < 130) return 'red';
    if (r > 220 && gg > 160 && gg < 215 && b < 90) return 'yellow';
    if (r < 90 && gg > 170 && b < 110) return 'green';
    return null;
  };
  const seen = new Uint8Array(W * H), out = [];
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const k = y * W + x; if (seen[k]) continue;
    const c = cls(k * 3); if (!c) continue;
    let minx = x, maxx = x, miny = y, maxy = y, n = 0, sx = 0, sy = 0, sxx = 0, syy = 0; const st = [k]; seen[k] = 1;
    while (st.length) { const q = st.pop(); const qx = q % W, qy = (q / W) | 0; n++; sx += qx; sy += qy; sxx += qx * qx; syy += qy * qy;
      minx = Math.min(minx, qx); maxx = Math.max(maxx, qx); miny = Math.min(miny, qy); maxy = Math.max(maxy, qy);
      for (const [dx, dy] of [[1, 0], [-1, 0], [0, 1], [0, -1]]) { const nx = qx + dx, ny = qy + dy; if (nx < 0 || ny < 0 || nx >= W || ny >= H) continue;
        const nk = ny * W + nx; if (!seen[nk] && cls(nk * 3) === c) { seen[nk] = 1; st.push(nk); } } }
    const w = maxx - minx + 1, h = maxy - miny + 1, fill = n / (w * h);
    // Dot-sized blobs whose fill matches a disc or ellipse (pi/4 ~ 0.785; the test itself is aspect-neutral).
    if (n >= 40 && w >= 6 && h >= 6 && w <= 34 && h <= 34 && fill > 0.62 && fill < 0.9)
      out.push({ t: tt, color: c, x: minx, y: miny, w, h, fill: +fill.toFixed(3), bboxRatio: +(w / h).toFixed(3),
        // Second-moment roundness: sqrt(var_x / var_y) is 1.0 for a circle and robust to edge thresholds.
        ratio: +Math.sqrt((sxx / n - (sx / n) ** 2) / (syy / n - (sy / n) ** 2)).toFixed(3) });
  }
  return out;
}
const tl = dots(22.2); // a calm, un-blurred frame (focus on Mockups): the key window's three dots, ~12 px
const worst = tl.reduce((m, d) => Math.max(m, Math.abs(d.ratio - 1)), 0);

// Uniform scaling inside an authentic render: icon centroids 84 pt apart horizontally (Mail -> Calendar pins)
// and 165 pt apart vertically (Mail pin -> Release notes row icon) must give the same px-per-pt factor.
function tileAspect(tt) {
  const g = frame(tt);
  const centroid = (x0, y0, x1, y1, test) => {
    let n = 0, sx = 0, sy = 0;
    for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) { const i = (y * W + x) * 3; if (test(g[i], g[i + 1], g[i + 2])) { n++; sx += x; sy += y; } }
    return { n, x: sx / n, y: sy / n };
  };
  const blue = (r, gg, b) => b > 190 && r < 110 && gg > 80 && gg < 215;
  const red = (r, gg, b) => r > 200 && gg < 110 && b < 110;
  // Camera at 25 s: (338, ~272.2, ~2.0125). Regions around each icon (screen px).
  const mail = centroid(330, 170, 420, 250, blue);       // Mail pin icon (tile 6..90, 78..140 pt)
  const cal = centroid(500, 150, 600, 250, red);         // Calendar pin icon's red header (tile 90..174 pt)
  const safari = centroid(295, 470, 350, 545, blue);     // Release notes row icon (row 256..292 pt)
  const kx = (cal.x - mail.x) / 84, ky = (safari.y - mail.y) / 165;
  return { t: tt, pixels: { mail: mail.n, calendar: cal.n, safari: safari.n }, pxPerPtX: +kx.toFixed(4), pxPerPtY: +ky.toFixed(4), ratio: +(kx / ky).toFixed(4), expected: 1 };
}
const tile = tileAspect(25.0);
const result = {
  file: mp4,
  stream: probe,
  icon: { ...icon, expectedSquarePx: +(exp.r - exp.l).toFixed(1), square: Math.abs(icon.ratio - 1) <= 0.02 },
  authenticUiScale: { ...tile, uniform: Math.abs(tile.ratio - 1) <= 0.02 },
  trafficLights: { dots: tl, count: tl.length, worstDeviationFromRound: +worst.toFixed(3), round: tl.length > 0 && worst <= 0.06, metric: 'second-moment sqrt(var_x/var_y)' },
  sarDar: { ok: probe.sample_aspect_ratio === '1:1' && probe.display_aspect_ratio === '16:9' && probe.width === 1920 && probe.height === 1080 },
};
console.log(JSON.stringify(result, null, 2));
