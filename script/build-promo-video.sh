#!/usr/bin/env bash
# Builds the WinMux product video from promo/ (see promo/README.md).
# It isn't part of the app's build, CI or make targets, and it needs no credentials or network TTS.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: script/build-promo-video.sh [--version vN[.N[.N]]] [--output DIR] [--with-temp-vo] [--no-qc]

Builds the WinMux product video from promo/, using the locked npm dependencies and the
prerecorded narration masters in promo/vo/.

  --version LABEL   Output label, such as v3 or v3.1 (default: v3)
  --output DIR      Output folder (default: promo/out/winmux-intro-<version>). It must not exist yet,
                    and must be outside promo/ or under promo/out/.
  --with-temp-vo    Also render a comparison film with a macOS `say` voice (never for release)
  --no-qc           Skip QC and stills
  -h, --help        Show this help

Environment: PROMO_RENDER_CONCURRENCY=N sets Remotion's render threads.
Tested on macOS on Apple silicon. Needs Node.js 20+ with npm 10+, ffmpeg and ffprobe with
libx264 and the aac encoder, python3 (for QC), about 3 GB of free disk, and network access for
`npm ci` and the one-time download of Remotion's headless Chrome shell.
EOF
}

die() {
  echo "build-promo-video: $*" >&2
  exit 1
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
promo="$repo_root/promo"
version="v3"
output=""
with_temp_vo=0
run_qc=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || die "--version needs a value"
      version="$2"
      shift 2
      ;;
    --output)
      [[ $# -ge 2 && -n "$2" ]] || die "--output needs a value"
      output="$2"
      shift 2
      ;;
    --with-temp-vo)
      with_temp_vo=1
      shift
      ;;
    --no-qc)
      run_qc=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

[[ "$version" =~ ^v[0-9]+(\.[0-9]+){0,2}$ ]] || die "--version must look like v3, v3.1 or v3.1.2"
[[ -f "$promo/package.json" && -f "$promo/package-lock.json" ]] || die "promo/ is missing or incomplete"
command -v node >/dev/null 2>&1 || die "node is required (20 or later)"

# The output folder: absolute, with symlinks resolved, and new. Inside promo/ it must be under
# promo/out/, because later builds replace promo/build/<version> and npm ci replaces node_modules.
[[ -n "$output" ]] || output="$promo/out/winmux-intro-$version"
output="$(node -e '
const fs = require("fs"), path = require("path");
let p = path.resolve(process.argv[1]);
const rest = [];
while (!fs.existsSync(p)) { rest.unshift(path.basename(p)); p = path.dirname(p); }
console.log(path.join(fs.realpathSync(p), ...rest));
' "$output")"
[[ ! -e "$output" && ! -L "$output" ]] || die "$output already exists; choose another --output or --version (nothing is overwritten)"
promo_real="$(cd "$promo" && pwd -P)"
case "$output/" in
  "$promo_real/out/"?*) ;;
  "$promo_real/"*) die "--output must be outside promo/ or under promo/out/ (builds replace promo/build and promo/node_modules)" ;;
esac

# Preflight.
[[ "$(uname -s)" == Darwin ]] || echo "build-promo-video: warning: only macOS on Apple silicon has been tested" >&2
command -v npm >/dev/null 2>&1 || die "npm is required (10 or later)"
node_major="$(node -p 'process.versions.node.split(".")[0]')"
((node_major >= 20)) || die "node $(node -v) is too old; 20 or later is required"
npm_major="$(npm -v | cut -d. -f1)"
((npm_major >= 10)) || die "npm $(npm -v) is too old; 10 or later is required"
for tool in ffmpeg ffprobe; do
  command -v "$tool" >/dev/null 2>&1 || die "$tool is required"
done
encoders="$(ffmpeg -hide_banner -encoders 2>/dev/null)"
grep -q " libx264 " <<<"$encoders" || die "ffmpeg lacks the libx264 encoder"
grep -q " aac " <<<"$encoders" || die "ffmpeg lacks the aac encoder"
if ((run_qc)); then
  command -v python3 >/dev/null 2>&1 || die "python3 is required for QC (or pass --no-qc)"
fi
if ((with_temp_vo)); then
  command -v say >/dev/null 2>&1 || die "--with-temp-vo needs macOS say"
fi
free_kb="$(df -Pk "$promo" | awk 'NR == 2 { print $4 }')"
((free_kb >= 3 * 1024 * 1024)) || die "about 3 GB must be free on the volume holding promo/"
mkdir -p "$(dirname "$output")"
free_out_kb="$(df -Pk "$(dirname "$output")" | awk 'NR == 2 { print $4 }')"
((free_out_kb >= 512 * 1024)) || die "about 0.5 GB must be free for the output"
if command -v shasum >/dev/null 2>&1; then
  sha256() { shasum -a 256 "$@"; }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256() { sha256sum "$@"; }
else
  die "shasum or sha256sum is required"
fi

echo "== WinMux product video $version -> $output"
echo "   node $(node -v), npm $(npm -v), $(ffmpeg -version | head -1 | cut -d' ' -f1-3)"

cd "$promo"
# Locked dependencies, then Remotion's headless Chrome shell (downloaded once into node_modules).
npm ci --no-audit --no-fund
npx --no-install remotion browser ensure

build="$promo/build/$version"
rm -rf "$build" # intermediates only; never the output folder
mkdir -p "$build" "$output/qc"
trap 'status=$?; ((status == 0)) || echo "build-promo-video: failed; the partial output is in $output (remove it, or pass another --output, to retry)" >&2' EXIT
export PROMO_BUILD_DIR="$build" PROMO_OUT_DIR="$output"

node scripts/cues-check.mjs
node scripts/music/synth.mjs
node scripts/vo/prepare.mjs final
node scripts/mix.mjs final
node scripts/captions.mjs final
node scripts/timing-sheet.mjs

render_args=(src/index.ts WinMuxIntro "$build/video-noaudio.mp4" --codec=h264 --crf=16 --pixel-format=yuv420p
  --color-space=bt709 --muted --gl=angle)
if [[ -n "${PROMO_RENDER_CONCURRENCY:-}" ]]; then
  [[ "$PROMO_RENDER_CONCURRENCY" =~ ^[1-9][0-9]*$ ]] || die "PROMO_RENDER_CONCURRENCY must be a positive integer"
  render_args+=("--concurrency=$PROMO_RENDER_CONCURRENCY")
fi
npx --no-install remotion render "${render_args[@]}"

disclosure="Narration: AI-generated voice (Google Gemini TTS, gemini-3.1-flash-tts-preview, voice Kore). Music: original, synthesized in code. UI: offscreen renders of WinMux v0.6.379 SwiftUI views with demo data; app windows and display motion are illustrated."
mux() { # mux <video> <audio wav> <bitrate> <title> <comment> <film>
  ffmpeg -hide_banner -loglevel error -i "$1" -i "$2" -map 0:v:0 -map 1:a:0 -map_metadata -1 \
    -c:v copy -c:a aac -b:a "$3" -ar 48000 -movflags +faststart \
    -metadata title="$4" -metadata comment="$5" "$6"
}

film="$output/winmux-intro_${version}.mp4"
mux "$build/video-noaudio.mp4" "$output/audio/winmux-intro_mix.wav" 320k "WinMux product introduction $version" "$disclosure" "$film"

if ((with_temp_vo)); then
  node scripts/vo/temp-say.mjs
  node scripts/vo/prepare.mjs temp
  node scripts/mix.mjs temp
  node scripts/captions.mjs temp
  mux "$build/video-noaudio.mp4" "$build/audio-temp/winmux-intro_mix_temp.wav" 256k \
    "WinMux product introduction $version (TEMP say voice, comparison only)" \
    "TEMP narration from macOS say, for timing comparison only; not the release voice." \
    "$output/winmux-intro_${version}_TEMP-VO-say.mp4"
fi

if ((run_qc)); then
  bash scripts/qc/qc.sh "$film" | tee "$output/qc/qc-summary.txt"
  bash scripts/qc/sheets.sh "$film"
fi

(cd "$output" && sha256 "$(basename "$film")" >"winmux-intro_${version}.sha256")
echo "== done: $film"
cat "$output/winmux-intro_${version}.sha256"
