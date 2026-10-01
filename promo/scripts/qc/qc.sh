#!/usr/bin/env bash
# QC for a built film. Usage: bash scripts/qc/qc.sh <film.mp4>
# Writes <out>/qc/*.txt|json and prints a summary; <out> is $PROMO_OUT_DIR, or else the film's folder.
# It measures (it can't listen), and fails if the captions don't match the narration.
# Needs ffmpeg, ffprobe, node and python3. Reads the narration manifest from $PROMO_BUILD_DIR,
# or else promo/build/<version>, where the film is named winmux-intro_<version>.mp4.
set -euo pipefail
MP4="$(cd "$(dirname "${1:?usage: qc.sh <film.mp4>}")" && pwd)/$(basename "$1")"
base=$(basename "$MP4" .mp4)
abs() { if [[ "$1" == /* ]]; then echo "$1"; else echo "$PWD/$1"; fi; }
OUT_DIR="$(abs "${PROMO_OUT_DIR:-$(dirname "$MP4")}")"
BUILD_DIR="${PROMO_BUILD_DIR:+$(abs "$PROMO_BUILD_DIR")}"
cd "$(dirname "$0")/../.."
BUILD_DIR="${BUILD_DIR:-$PWD/build/${base#winmux-intro_}}"
Q="$OUT_DIR/qc"
mkdir -p "$Q"

echo "== ffprobe"
ffprobe -v error -show_entries format=duration,size,bit_rate:stream=index,codec_type,codec_name,profile,width,height,sample_aspect_ratio,display_aspect_ratio,r_frame_rate,avg_frame_rate,pix_fmt,color_range,color_space,sample_rate,channels,duration,start_time,nb_frames \
  -of json "$MP4" > "$Q/$base.ffprobe.json"
python3 - "$Q/$base.ffprobe.json" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
for s in d['streams']:
    print(' ', s['codec_type'], s['codec_name'], s.get('profile',''), s.get('width',''), s.get('height',''), 'SAR', s.get('sample_aspect_ratio',''), 'DAR', s.get('display_aspect_ratio',''), s.get('r_frame_rate',''), s.get('pix_fmt',''), s.get('color_range',''), s.get('sample_rate',''), s.get('channels',''), 'dur', s.get('duration'), 'start', s.get('start_time'), 'frames', s.get('nb_frames',''))
print('  format duration', d['format']['duration'], 'size', d['format']['size'])
EOF

echo "== full decode check (errors below, none = clean)"
ffmpeg -v error -i "$MP4" -f null - 2> "$Q/$base.decode-errors.txt" || true
echo "  decode error lines: $(wc -l < "$Q/$base.decode-errors.txt" | tr -d ' ')"

echo "== loudness (EBU R128) and true peak"
ffmpeg -hide_banner -nostats -i "$MP4" -map 0:a:0 -af ebur128=peak=true -f null - 2>&1 | sed -n '/Summary/,$p' > "$Q/$base.ebur128.txt"
grep -E "I:|LRA:|Peak:" "$Q/$base.ebur128.txt" | sed 's/^/  /'

echo "== clipping / levels (astats on decoded audio)"
ffmpeg -hide_banner -nostats -i "$MP4" -map 0:a:0 -af astats=metadata=0 -f null - 2>&1 | grep -E "Overall|Peak level dB|Peak count|Number of samples|Flat factor|DC offset" | tail -8 > "$Q/$base.astats.txt"
sed 's/^/  /' "$Q/$base.astats.txt"
python3 - "$MP4" <<'EOF'
import subprocess,sys,struct
raw=subprocess.run(['ffmpeg','-v','error','-i',sys.argv[1],'-map','0:a:0','-f','s16le','-ac','2','-'],capture_output=True).stdout
n=len(raw)//2
vals=struct.unpack('<%dh'%n, raw)
full=sum(1 for v in vals if v>=32767 or v<=-32768)
print(f'  samples at 16-bit full scale after AAC decode: {full} of {n}')
EOF

echo "== black / frozen frames"
ffmpeg -hide_banner -nostats -i "$MP4" -vf "blackdetect=d=0.25:pic_th=0.97:pix_th=0.06" -an -f null - 2>&1 | grep -o "black_start:[^ ]* black_end:[^ ]* black_duration:[^ ]*" > "$Q/$base.blackdetect.txt" || true
ffmpeg -hide_banner -nostats -i "$MP4" -vf "freezedetect=n=0.0015:d=1.0" -an -f null - 2>&1 | grep -oE "freeze_(start|end|duration): [0-9.]+" | paste - - - > "$Q/$base.freezedetect.txt" || true
echo "  blackdetect (>=0.25 s):"; sed 's/^/    /' "$Q/$base.blackdetect.txt"; [ -s "$Q/$base.blackdetect.txt" ] || echo "    none"
echo "  freezedetect (>=1.0 s):"; sed 's/^/    /' "$Q/$base.freezedetect.txt"; [ -s "$Q/$base.freezedetect.txt" ] || echo "    none"

echo "== aspect / uniform scaling (measured)"
node scripts/qc/aspect.mjs "$MP4" > "$Q/$base.aspect.json"
python3 - "$Q/$base.aspect.json" <<'EOF2'
import json,sys
d=json.load(open(sys.argv[1]))
st=d['stream']; print(f"   {st['width']}x{st['height']} SAR {st['sample_aspect_ratio']} DAR {st['display_aspect_ratio']} -> ok {d['sarDar']['ok']}")
i=d['icon']; print(f"   WinMux icon on the end card: {i['widthPx']} x {i['heightPx']} px (w/h {i['ratio']}) square {i['square']}")
u=d['authenticUiScale']; print(f"   authentic UI render scale at {u['t']} s: {u['pxPerPtX']} px/pt horizontal vs {u['pxPerPtY']} vertical (ratio {u['ratio']}) uniform {u['uniform']}")
t=d['trafficLights']; print(f"   traffic-light dots: {[(x['color'], x['w'], x['h'], x['ratio']) for x in t['dots']]} round {t['round']}")
EOF2

echo "== last frame"
ffmpeg -hide_banner -loglevel error -sseof -0.05 -i "$MP4" -frames:v 1 -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG:file=-" -f null - 2>/dev/null | grep -o -m 1 "YAVG=[0-9.]*" | sed 's/^/   final frame luma (16 = black in limited range): /' || true

echo "== beat / A-V sync at accents"
node scripts/qc/sync.mjs "$MP4" > "$Q/$base.sync.json"
python3 - "$Q/$base.sync.json" <<'EOF'
import json,sys
d=json.load(open(sys.argv[1]))
print('  ', d['summary'])
for r in d['rows']:
    print(f"   {r['id']:<16} t={r['t']:6.2f}  audio onset {r['audio']['offsetMs']:+5d} ms  visual onset {r['video']['offsetMs']:+5d} ms")
EOF

echo "== captions vs narration placement"
manifest="$BUILD_DIR/vo/manifest.json"
[[ -f "$manifest" ]] || { echo "   no narration manifest at $manifest; set PROMO_BUILD_DIR to the build folder" >&2; exit 1; }
python3 - "$manifest" "$OUT_DIR/captions/winmux-intro.en.srt" <<'EOF'
import json,re,sys
m=json.load(open(sys.argv[1]))
srt=open(sys.argv[2]).read().strip().split('\n\n')
def ts(x):
    h,mi,rest=x.split(':'); s,ms=rest.split(','); return int(h)*3600+int(mi)*60+int(s)+int(ms)/1000
ok=len(srt)==len(m['lines'])
if not ok: print(f"   MISMATCH {len(srt)} SRT cues for {len(m['lines'])} narration lines")
for blk,l in zip(srt,m['lines']):
    lines=blk.split('\n'); a,b=[ts(x.strip()) for x in lines[1].split('-->')]
    text=' '.join(lines[2:])
    good = a <= l['speechStart']+0.01 and b >= l['speechEnd']-0.01 and text==l['text'] and b<=86 and l['speechEnd'] <= l['maxEnd']+0.01
    ok &= good
    if not good: print('   MISMATCH', l['id'], a, b, l['speechStart'], l['speechEnd'])
print(f"   {len(srt)} SRT cues, all cover their spoken line and match the script text; every line ends inside its window: {ok}")
sys.exit(0 if ok else 1)
EOF
