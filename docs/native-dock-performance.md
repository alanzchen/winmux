# Native Dock performance — September 20, 2026

The compact app-icon Dock now uses AppKit and cached Core Animation layers.
Pointer motion updates layer positions and scales without publishing a new
SwiftUI view tree on every frame. Expanded workspace views, project browsing,
settings, menus, and the clock retain their existing presentation.

The required budgets remain **below 3% average interaction CPU** and **below 2%
idle CPU**. The current measurements do not yet establish the interaction target.
100% represents one occupied CPU core. CPU percentage is not Energy Impact or
power consumption.

## Current production candidate measurements

The production candidate was built as local prototype v18; it is not a published version.
Both idle runs met the idle gate. Interaction remains above the requested budget
in three of the four sustained-motion runs.

| Configuration | WinMux mean CPU | Highest ~5 s interval | WindowServer mean CPU |
| --- | ---: | ---: | ---: |
| Left, 120 movement events/s | 4.088% | 4.405% | 27.213% |
| Bottom, 120 movement events/s | 4.161% | 4.883% | 31.040% |
| Left, 60 movement events/s | 2.779% | 2.893% | 26.248% |
| Bottom, 60 movement events/s | 3.151% | 3.695% | 29.541% |
| Left, idle | 0.745% | 0.889% | — |
| Bottom, idle | 0.708% | 0.933% | — |

Each row covers at least 60 seconds with an awake display. Actual generator rates
were 119.97–120.00 or 60.00 events/s, with no input gap larger than 23 ms. There
were no deliberate input pauses. The highest five-second interval is reported
separately; it is not an instantaneous peak. Compositor totals are not exclusive
to WinMux and do not measure GPU utilization.

A matched repeat of the published 0.6.332 baseline, using the corrected generator
and the same 120-event/s paths, measured:

| Position | Published WinMux mean CPU | Published WindowServer mean CPU |
| --- | ---: | ---: |
| Left | 28.696% | 31.352% |
| Bottom | 29.343% | 34.324% |

These runs also used fresh processes, 20 seconds of settling, 10 seconds of
movement warm-up, and at least 60 seconds of measurement with no accessibility
inspection. They show about 86% less WinMux CPU in the candidate and a smaller
reduction in compositor CPU. They do not establish a battery-life improvement.
Raw comparison data is in `baseline-windowserver-v1/`; candidate data is in
`verify-v18/` under the results directory below.

As a reference, the native macOS Dock itself averaged 3.118% in a separate
120-event/s sweep, with WindowServer at 20.810%. Magnification was enabled;
WinMux was not running. Its icon count and auto-fitting differ from WinMux, so
this is an input/environment reference rather than a feature-for-feature
comparison. Earlier native-Dock runs in the same VM measured about 2.8%.
The VM cannot substantiate the user's physical MacBook Air percentages.

Candidate executable SHA-256:
`183d8a5493a5acd13b4982d22876b3f377a1f916a8af758619673c37a612b488`.
The app used the Xcode Release configuration and Swift 6.2.4, built from
`d2cfb353` plus this change; app and bundled baseline CLI were ARM64-only. The
local test bundle was ad-hoc signed, not notarized or distributed. The unrelated
working-copy glass-style edit was excluded from this isolated build.

## Implementation

- One analytical geometry calculation supplies artwork, pointer targets, drop
  targets, and accessibility bounds on the left, right, and bottom edges.
- Cached artwork moves at the display's refresh cadence. The display link sleeps
  when motion settles; no lower animation-rate cap is imposed.
- The glass shelf reserves the lens envelope on entry. Glass, the clock, and
  other stationary controls remain fixed while the pointer traverses the icons.
- An unchanged snapshot, pointer frame, bounds, and scroll offset produce no
  duplicate layer transaction. The clipping layer covers the compact lens
  envelope rather than the full expanded panel canvas.
- Public icon reads still detect replacement artwork; a bounded pixel-and-format
  cache avoids repeating color conversion and resampling of unchanged images.
- Hidden native Dock detection uses its physical activation edge. Merely moving
  over WinMux's bottom icons no longer causes rapid accessibility polling of the
  hidden macOS Dock. Badge reads batch three attributes in one request.
- Native clicks, workspace creation, dragging, context menus, external WinMux
  payload drops, scrolling, and accessibility actions reuse the existing action
  handlers. Project swipes retain one gesture coordinator across renderer changes.

`WINMUX_NATIVE_DOCK=0` selects the previous compact renderer for diagnostic
comparisons. It is not required for normal use.

## Measurement method

Use an ARM64 Xcode Release app, not the SwiftPM development executable. Start a
fresh process for each configuration, settle for 20 seconds, then warm up with
10 seconds of pointer movement before measuring at least 60 seconds. Keep glass,
magnification, badges, and clock settings identical between runs. Do not run
builds, tests, accessibility-tree inspection, or sampling profilers during the
measurement. Verify icon geometry separately, then use fixed coordinates.

Compile `script/dock-pointer-sweep.swift` before measuring. It posts a continuous
sinusoidal sweep with a three-second round trip and writes its actual event rate
and largest scheduling gap to JSON. Example arguments, which must be adapted to
the current display and verified icon bounds:

```sh
swiftc script/dock-pointer-sweep.swift -o /tmp/dock-pointer-sweep
/tmp/dock-pointer-sweep vertical 218.5 478.5 34 75 120 /tmp/pointer-input.json
```

Run the sampler concurrently with the sweep:

```sh
python3 -B script/measure-idle-cpu.py --mode interaction --pid "$WINMUX_PID" \
  --warmup 10 --seconds 60 --output /tmp/interaction-cpu.json
```

The interaction sampler fails when mean CPU is at least 3% or the display sleeps.
Its `run_valid` checks process identity and awake sampling endpoints, not that
the cursor followed the desired path: also inspect the generator report and a
separate geometry check. For idle, move the pointer away, stop input, and omit
`--mode interaction`; the default requires every five-second interval below 2%
and rejects input or a sleeping display. CPU counters use the machine's Mach
timebase, rather than assuming one tick equals one nanosecond.

The measurements here use an isolated macOS 26.6.2 Tart VM on Apple M2 Ultra,
8 virtual CPUs, a 1024×768-point Retina display, one workspace with six app icons,
48-point resting icons, 1.5× magnification, clear glass, badges, a minute-only
clock, and auto-hide disabled. The separate input generator is excluded from
WinMux CPU. WindowServer is measured separately and includes the rest of the VM
compositor's work. These are synthetic-input VM observations, not measurements
on the user's physical MacBook Air.

## Remaining work

The interaction budget is still unmet. A separate 30-second-per-case experiment
replaced mouse movement monitoring with a Core Graphics event tap and disabled
panel mouse-move delivery. It increased CPU (left 3.68% to 4.17%, bottom 3.97% to
4.56%) and was discarded. Removing global monitoring alone also failed to close
the gap. Neither experiment is enabled or included in production source.

Profiles of the native renderer now emphasize AppKit event delivery and Core
Animation commit work; the expensive per-frame SwiftUI rebuilding was removed.
This does not prove an inherent SwiftUI or AppKit performance limit. Further work
needs an on-device trace of the physical MacBook Air, including native event rate,
rendering cadence, WindowServer, and energy use, to choose the next bottleneck
rather than promising a percentage from the VM. The 3% gate remains unchanged.

## Validation and review

The Swift 6.2.4 ARM64 suite executes 1,001 tests with seven intentional
native/opt-in skips and zero failures. Native regressions cover all-edge magnification geometry, clipping,
expanded/compact transitions, magnification toggling, stationary-pointer recovery
after scrolling, tracking attachment, stable accessibility identity, click commit,
drag identity across model changes, and current payload-drop destinations.
The ARM64 Xcode Release build, explicit SwiftPM build, and CPU-counter
conversion tests pass.

Separate native VM smoke checks confirmed app activation by click and AXPress,
workspace creation, moving a window by dragging, workspace context menus,
project swiping, bottom expansion without the previously reported clipping,
left-edge auto-hide/reveal, and yielding to the native macOS Dock at the bottom
edge followed by recovery when the pointer leaves it.
The menu-bar hover probe selected all 14 tested entries (median 5.77 ms,
p95 7.08 ms, maximum 44.18 ms). This diagnostic ran separately from CPU sampling.
Physical multiple-display behavior, physical trackpad/frame pacing, GPU/power,
and full end-to-end external payload dragging remain unverified here.

agy CLI (`gemini-3.8-flash-high`) completed independent read-only reviews and
follow-ups. Accepted findings resulted in click-release semantics, stable drag
and accessibility identities, persistent swipe capture, correct monitor scope,
tracking lifecycle fixes, and stationary-pointer recovery. Its last targeted
review found no supported regression in the scene deduplication and clip changes.
Claude CLI (`claude-fable-5`) returned its session usage limit and did not complete
an audit; no substitute model or Claude approval is claimed.

Raw reports, configurations, screenshots, input rates, and review transcripts are
under `.local/vm-share/results/native-dock-20260920/` and
`.local/reviews/native-dock-20260920/` (ignored by Git). The public 0.6.332 baseline
is documented in `docs/dock-interaction-cpu-validation.md`. No release or hosted
CI run is part of this change.
