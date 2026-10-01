# WinMux product video (source)

This folder builds the 86-second WinMux introduction. Its look:
- **Format:** 1920×1080 at 60 fps, with narration, music and English captions.
- **Motion graphics:** made in code with [Remotion](https://www.remotion.dev) and React.
- **UI:** offscreen renders of WinMux's real SwiftUI views (v0.6.379), drawn from demo data.
- **Music:** original, synthesized in code.
- **Narration:** an approved, prerecorded AI-generated voice (Google Gemini TTS).

The published film is attached to the [`promo-video-v3` release](https://github.com/alanzchen/winmux/releases/tag/promo-video-v3). That release isn't an app release.

This folder is separate from the app. SwiftPM, the Xcode project, `make` and CI never read it.

## Build

From the repository root:

```sh
script/build-promo-video.sh --version v3
```

The script checks the tools, installs the locked dependencies (`npm ci`) and downloads Remotion's headless Chrome shell. It then renders the film and runs QC. A clean build took about 3 minutes on an Apple M2 Ultra.

**Output:** by default it writes to `promo/out/winmux-intro-v3/`, and `--output DIR` chooses another folder. It never overwrites an existing output folder. If a build fails, its partial output stays for inspection: remove it, or choose another folder, to retry.

| Path | Contents |
|---|---|
| `winmux-intro_v3.mp4` | H.264 High, 1920×1080, 60 fps, BT.709, AAC 48 kHz stereo; −16 LUFS, true peak ≤ −1.5 dBTP |
| `winmux-intro_v3.sha256` | Checksum of the film |
| `captions/` | English captions (`.srt` and `.vtt`), timed from the measured speech |
| `audio/` | The mix, the narration stem, the music bed as mixed, the unducked score, and `mix-report.json` |
| `timing-sheet.md` | Narration placement and the beat grid's accents |
| `qc/` | ffprobe, a full decode, EBU R128 loudness and true peak, black and freeze detection, aspect and uniform-scaling measurements, the last frame, beat and A/V sync, and a caption check |
| `stills/` | Thumbnails, a timestamped contact sheet and a short preview clip |

**Requirements.** It's tested only on macOS 27 on Apple silicon, with Node 26.10, npm 11.19, ffmpeg 9.0.2 and Python 3.14. Other setups are untested.
- **Node:** 20 or later, with npm 10 or later.
- **ffmpeg and ffprobe:** with libx264 and the native AAC encoder.
- **python3:** for QC.
- **Disk:** about 3 GB free.
- **Network:** needed for `npm ci` and the one-time browser download. npm 11 may warn that esbuild's install script wasn't approved; the build doesn't need it.
- **GPU:** the render uses Chrome's Metal-backed ANGLE renderer (`--gl=angle`).
- **macOS-only parts:** `xcrun swift` labels the QC sheets, and the optional TEMP voice uses `say`.
- **Not needed:** no credentials, no network TTS and no macOS `say`.

**Options:**

| Option | What it does |
|---|---|
| `--version vN[.N]` | Labels the output (default `v3`) |
| `--output DIR` | Chooses the output folder. It must be new, and outside `promo/` or under `promo/out/`. |
| `--with-temp-vo` | Also renders a comparison film with a macOS `say` voice (macOS only; never for release) |
| `--no-qc` | Skips QC and stills |
| `PROMO_RENDER_CONCURRENCY=N` | Sets Remotion's render threads |

**Determinism.** The audio, captions and timing are deterministic: fixed seeds, frame-exact timing, and no network inputs once the dependencies are installed. A clean rebuild on the machine that made the published film reproduced its audio and captions bit for bit. In the picture, 4,216 of the 5,160 frames were pixel-identical. The rest differed imperceptibly (PSNR 47 dB or more) where Chrome's GPU draws blurs, glows and gradients, so the MP4 isn't byte-identical. Other machines, GPUs and tool versions may differ more.

## Layout

| Path | What it is |
|---|---|
| `cues/beats.json` | The editable beat grid: 120 BPM, sections, chords and accents. The picture and the music both read it. |
| `cues/narration.json` | Narration lines, start times and hard windows |
| `src/` | The Remotion composition. `film/geometry.ts` holds the camera; the acts are in `film/windows.tsx`, `film/sidebars.tsx`, `film/drag.tsx`, `film/overlays.tsx` and `film/finale.tsx`. |
| `public/ui/` | Authentic UI renders (3× PNG) with their exported row, tile and group frames (JSON) |
| `public/ui-hi/` | An 8× render of the same state, for the badge close-up |
| `vo/L01.wav` … `L16.wav` | Approved narration masters: native 24 kHz, 16-bit mono. The build derives 48 kHz copies. |
| `scripts/music/` | The score synthesizer, a small DSP kit (no samples) |
| `scripts/vo/prepare.mjs` | Resamples, trims and levels the lines; never time-stretches |
| `scripts/mix.mjs` | Places the lines un-stretched, ducks the music, then applies loudness and a limiter |
| `scripts/captions.mjs`, `scripts/timing-sheet.mjs` | Captions and the timing sheet |
| `scripts/qc/` | The QC checks and stills |
| `scripts/vo/gemini-tts.mjs` | Optional. Regenerates narration takes; you need your own Google Cloud Vertex AI access, configured through environment variables only. |
| `harness/LocalPromoRenderHarness.swift.txt` | The render-only harness that produced `public/ui/`. It's kept as `.txt` so it's never compiled; its header explains how to use it. |
| `docs/` | The narration script, with a Chinese translation, and the provenance notes |

To preview interactively, run `npm ci` and then `npm run studio` in this folder.

## Editing

- **Choreography:** edit a bar or beat in `cues/beats.json`. The score (`scripts/music/synth.mjs`) and the picture both follow it.
- **Narration timing:** edit `start` and `maxEnd` in `cues/narration.json`. Lines are never time-stretched; the build stops if a line overruns its window.
- **UI states:** re-render them with the harness at the release commit, then replace `public/ui/`.

## Licences and disclosure

Read [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and [docs/provenance.md](docs/provenance.md). In brief:
- **Remotion:** it's licensed per user. Rendering the video with it is free for individuals, non-profits and for-profit organizations with up to 3 employees; other organizations need a Remotion Company License. This applies to whoever builds the video. The published film was made by an individual (Remotion free licence).
- **Narration:** it's **AI-generated** with Google Gemini TTS (`gemini-3.1-flash-tts-preview`, voice Kore) through Vertex AI, and the audio carries Google's SynthID watermark.
- **Picture:** the film says on screen that its UI uses demo data and that the app windows and display motion are illustrated.
- **Code:** it's under the repository's [MIT License](../LICENSE.txt).
