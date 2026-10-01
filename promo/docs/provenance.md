# Provenance

How each part of the product video was made, and what is illustrated rather than captured.

## Authentic WinMux UI

The film's sidebar, display rails, destination list and pinned tiles are offscreen renders of WinMux's real SwiftUI views at v0.6.379 (commit `ee150c27`). They were produced with `harness/LocalPromoRenderHarness.swift.txt` and are stored in `public/ui/` (3×) and `public/ui-hi/` (8×).

**Views:**
- `WorkspaceSidebarView` in Tabs mode, with the solid Fog chrome and the light appearance;
- `WorkspaceSidebarDropDestinationHintsView`, the full-height display rails;
- `WorkspaceSidebarDropDestinationView`, another display's list.

**Rendering:** an `NSHostingView` is hosted in a borderless offscreen window that reports a backing scale of 3 (8 for the badge close-up), and captured with `cacheDisplay`.

**Demo data only:**
- **Projects:** Launch, Writing, Home and Research.
- **Tabs:** Prototype, Mockups, Specs, Release notes, Roadmap, build, Changelog, Store listing, Press kit, Docs, Standup notes, Sketches, Moodboard, Reading list, Ideas, Chapter 3, Outline and Sources.
- **Badge:** a demo badge "3" on Messages.
- **Displays:** "Built-in Retina Display", "Studio Display" and "LG UltraFine" are demo names. No real displays were involved.

**Icons:** they're the system apps' own icons, looked up by WinMux as it does for any app. See [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).

**Motion between states is the film's own:** it slices the renders at the frames the harness exports, and moves the slices, for rows sliding, tiles moving, groups folding and the list paging. WinMux's own animation curves weren't captured. For readability, the rails open after a pause of about 1 s; the app's pause is 0.22 s.

## Illustrated, not captured

This is stated on screen during the displays reveal, from 44.6 to 48.9 s.

- **App windows:** neutral windows drawn in code (`src/components/AppWindow.tsx`). They have traffic lights, which grey out when a window is inactive as in macOS, a title, and abstract placeholder content. No real app UI is shown.
- **The three-display arrangement:** a composite. The bezels, glows and wallpapers are original CSS drawings.
- **Motion between displays:** illustrative. That covers:
  - the whip pan between displays;
  - the tab row travelling to Studio Display;
  - the Messages window arcing across;
  - the loupes, tethers, light sheen and camera moves.
- **What it depicts is the shipped behavior:**
  - the display rails and another display's list during a drag (`Sources/AppBundle/ui/sidebar/WorkspaceSidebarDropDestination*.swift`);
  - shared pinned tabs, click-to-bring-here, the faint display outline on pins kept on another display, and reordering shared pins without moving any tab ([docs/configuration.md](../../docs/configuration.md), Tabs).
- **Hardware:** the film doesn't claim to show real multi-display hardware.
- **The badge callout:** "On Built-in Retina Display" is a film label paraphrasing the badge's tooltip. It isn't a render of a macOS tooltip.

## Logo, type and colour

- **Logo:** the icon is rebuilt in code (`src/components/Logo.tsx`) from the geometry and gradients of `resources/winmux-logo.svg`.
- **Film text:** Inter (OFL 1.1). The UI renders' text is macOS's system font, drawn by macOS.
- **Colour:** the film is encoded as BT.709, limited range.

## Music

The music is composed and synthesized in code by `scripts/music/synth.mjs` and `dsp.mjs`. It uses no samples, and it's deterministic.
- **Structure:** 120 BPM in D major, opening in B minor, with a 43-bar arrangement driven by `cues/beats.json`.
- **Motif:** the WinMux motif (A–D–E–A) lands at the snap, the displays reveal and the logo.
- **Ending:** a plagal cadence, D → G/D → D(add9), closes on the end card.
- **Accents:** the music's accents are the picture's accents, since both read one grid.

## Narration

The narration is AI-generated with Google Gemini TTS, using model `gemini-3.1-flash-tts-preview` and prebuilt voice Kore, through Vertex AI. It was generated on 2026-09-30.
- **Takes:** 16 lines, plus brisker retakes of L06 and L15. The approved takes are `vo/L01.wav` … `L16.wav`.
- **Format:** native 24 kHz, 16-bit, mono.
- **Style direction:** warm, confident and unhurried, in neutral American English, with "WinMux" pronounced WIN-mux. The prompt is in `scripts/vo/gemini-tts.mjs`.
- **Build processing:** the build upsamples the masters to 48 kHz with ffmpeg's swr resampler (128-tap). It trims each to at most 0.08 s of lead-in and 0.25 s of tail, levels each line to about −18 LUFS, and catches rare transients with a −2 dBFS limiter.
- **Placement:** lines are placed un-stretched on the beat grid, and the music ducks 9 dB under the voice.
- **Checks:** pronunciation and timing were checked objectively. Durations fit their windows, and "WinMux" measures as one two-syllable word. Listen before reusing the takes elsewhere.
