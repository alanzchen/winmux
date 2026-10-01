#!/usr/bin/env bash
# Stills deliverables: contact sheet, thumbnails, preview clip, and a visual beat-sync sheet.
# Usage: bash scripts/qc/sheets.sh <film.mp4>
# Writes <out>/stills and <out>/qc, where <out> is $PROMO_OUT_DIR, or else the film's folder.
# The labelled sheets are drawn with AppKit through `xcrun swift`; without it they're skipped.
set -euo pipefail
MP4="$(cd "$(dirname "${1:?usage: sheets.sh <film.mp4>}")" && pwd)/$(basename "$1")"
OUT_DIR="${PROMO_OUT_DIR:-$(dirname "$MP4")}"
[[ "$OUT_DIR" == /* ]] || OUT_DIR="$PWD/$OUT_DIR"
cd "$(dirname "$0")/../.."
S="$OUT_DIR/stills"; Q="$OUT_DIR/qc"; F="$(mktemp -d)"
trap 'rm -rf "$F"' EXIT
mkdir -p "$S" "$Q"

# Thumbnails (full-res frames).
ffmpeg -hide_banner -loglevel error -y -ss 83.5 -i "$MP4" -frames:v 1 -q:v 2 "$S/thumbnail.jpg"
ffmpeg -hide_banner -loglevel error -y -ss 58.6 -i "$MP4" -frames:v 1 -q:v 2 "$S/thumbnail-alt-rails.jpg"
ffmpeg -hide_banner -loglevel error -y -ss 70.3 -i "$MP4" -frames:v 1 -q:v 2 "$S/thumbnail-alt-shared-pins.jpg"

# Preview clip: the displays reveal, rails, list and drop (44.0-61.4 s), with short audio fades.
ffmpeg -hide_banner -loglevel error -y -ss 44.0 -t 17.4 -i "$MP4" -c:v libx264 -crf 18 -preset slow -pix_fmt yuv420p \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -af "afade=t=in:st=0:d=0.3,afade=t=out:st=16.9:d=0.5" -c:a aac -b:a 256k -movflags +faststart "$S/preview-clip_44-61s.mp4"

# Frames for the sheets, then labelled grids (AppKit; this ffmpeg has no drawtext).
python3 - "$MP4" "$F" <<'PY'
import json, subprocess, sys
mp4, F = sys.argv[1:3]
def grab(t, path):
    subprocess.run(['ffmpeg','-hide_banner','-loglevel','error','-y','-ss',f'{t:.3f}','-i',mp4,'-frames:v','1','-vf','scale=384:-1',path], check=True)
contact = []
for k, t in enumerate([x * 2 + 1 for x in range(43)]):
    p = f'{F}/c{k:02d}.png'; grab(t, p); contact.append({'path': p, 'label': f'{int(t//60)}:{t%60:04.1f}'})
name = mp4.rsplit('/', 1)[-1].removesuffix('.mp4')
json.dump({'cols': 6, 'cellW': 384, 'cellH': 216, 'title': f'{name}: contact sheet (one frame every 2 s, from 0:01)', 'items': contact}, open(f'{F}/contact.json','w'))
b = json.load(open('cues/beats.json'))
T = lambda bar, beat: (bar*4+beat)*60/b['bpm']
sync = []
for i, a in enumerate([a for a in b['accents'] if a['strength'] >= 0.55]):
    t = T(a['bar'], a['beat'])
    for j, dt in enumerate((-0.1, 0.0, 0.15)):
        p = f'{F}/s{i:02d}_{j}.png'; grab(max(0, t + dt), p)
        sync.append({'path': p, 'label': f"{a['id']} @{t:.2f}s {dt:+.2f}"})
json.dump({'cols': 3, 'cellW': 384, 'cellH': 216, 'title': 'Beat sync: frames 0.1 s before, at, and 0.15 s after each strong accent', 'items': sync}, open(f'{F}/sync.json','w'))
PY
if command -v xcrun >/dev/null 2>&1 && xcrun swift --version >/dev/null 2>&1; then
  xcrun swift scripts/qc/compose-sheet.swift "$F/contact.json" "$S/contact-sheet.png"
  xcrun swift scripts/qc/compose-sheet.swift "$F/sync.json" "$Q/sync-sheet.png"
else
  echo "xcrun swift is unavailable: skipped the labelled contact and sync sheets"
fi
echo "stills -> $S; sync sheet -> $Q/sync-sheet.png"
