# Dock motion optimization and capture validation

September 18, 2026. Baseline: `7089748c`, including the rendering path released in
0.6.323. The separate, uncommitted regular-glass experiment was excluded. These
checks used Swift 6.2.4 and ARM64 builds; no app was installed or released.

## Changes

- Build artwork, workspace controls and action closures from the workspace
  snapshot. A smaller motion host and modifiers update transforms and hit regions
  during magnification. Artwork still responds to new snapshots and badge updates.
- Preserve the lazy workspace layout, left-edge anchoring, separator motion,
  drag-preview sizing, morph anchors and current native hit regions.
- Ignore column-origin differences below 0.001 point at the state boundary.
  An experimental eager layout produced up to 25 repeated updates from rounding
  differences around `2.84e-14` point. The original lazy layout did **not** reproduce
  that loop, including with the clock enabled. The eager experiment was removed;
  the tolerance remains defensive hardening, not an attributed production fix.
- Add bounded, opt-in, two-minute performance capture in Settings → Appearance.
  See [capture instructions and interpretation](dock-performance-debugging.md).

## Measurements

Matched optimized host builds differed only in the header implementation. Each
case sampled 120 rapid pointer positions. Values below are CPU/view/layout time,
not GPU presentation intervals. A second optimized run checked repeatability.

| App counts per workspace | Original p50 / p99 | Optimized p50 / p99 | Optimized repeat p50 / p99 |
| --- | --- | --- | --- |
| 8, 0 (recording's workload) | 1.734 / 1.881 ms | 1.672 / 1.777 ms | 1.717 / 2.192 ms |
| 4, 4, 4 | 2.315 / 2.513 ms | 2.140 / 2.312 ms | 2.174 / 2.600 ms |
| Eight workspaces, four apps each | 3.602 / 4.195 ms | 2.966 / 3.096 ms | 2.986 / 3.197 ms |

The larger case reduced median work by about **17%** and p99 by 24–26%. The
two-workspace case was substantially unchanged; its tail varied between runs.
These results do not establish the cause of the user's intermittent Air stutter.

Two optimized 15-second Tart runs exercised the AppKit hover path with eight apps
and an empty workspace, rapid sweeps, reversals and exits. Input came from a
separate timer; neither input nor forced layout ran inside the display callback.

| Capture | Changed poses | Suspected late callbacks | Retained callback-gap p99 | Maximum callback gap |
| --- | --- | --- | --- | --- |
| Clock off | 782 | 1 | 20.76 ms | 44.79 ms |
| Clock with seconds | 777 | 2 | 20.58 ms | 47.80 ms |

Both runs used the VM's 60 Hz display. p99 covers retained, non-baseline samples;
counts and maxima cover the entire capture. Neither recorded expensive state
publication or publication past a native deadline. Synthetic input injection p99
was 2.53 / 2.46 ms. Earlier original-header runs also had occasional late callbacks;
these short runs do **not** demonstrate improved presentation cadence.

A 20,000-iteration microbenchmark measured approximately 1.12 microseconds of
added motion/sample-recording work per callback in the VM. This excludes framework,
preference and run-loop observer overhead; it is not whole-app capture overhead.

## Regression checks and reviews

- Final focused recorder, invalidation and magnification checks passed.
- Complete suite: **839 tests, 5 intentional skips, 0 failures**; ARM64 debug build
  passed in Tart on macOS 26.6.2 / Xcode 26.5 with pinned Swift 6.2.4.
- Optimized hover captures and CPU benchmarks passed separately. Existing native
  protruding-icon click, clipping, morph, drag and layout regressions passed.
- Added coverage proves motion leaves artwork construction stable, moves hit
  frames and adopts a changed snapshot. Recorder tests cover simulated 60/120 Hz,
  idle/wake/cadence resets, legacy timing, retirement, rotation, automatic stop,
  file permissions and disabled-mode behavior.
- Independent read-only Claude CLI (`claude-fable-5`) and agy CLI
  (`gemini-3.8-flash-high`) reviews and follow-ups completed. Accepted findings
  corrected detached-panel retention, preceding-frame context, overflow button
  iteration, indicator fallback and non-vacuous snapshot/hit-frame assertions.
  Both final rendering reviews found no blocking production defects.

Raw reports, benchmark logs and reviewer responses remain in ignored
`.local/reviews/dock-stutter-fix-20260918/`; native JSON captures are in ignored
`.local/vm-share/results/`.

## Remaining verification

The affected M5 MacBook Air and a physical 120 Hz display remain untested with
this change. Callback timing cannot measure compositor/GPU presentation. Capture
ordinary use on the Air, without screen recording first; correlate remaining
suspect timings with SwiftUI/Time Profiler and Hitches traces if needed.

The recorder conservatively excludes two baseline frames after cadence changes.
More than eight concurrent panels are counted as omitted; a rejected panel is
retried on registration or the next capture. Reports exceeding 5 MB fail with an
explicit error. These limits bound diagnostic work and must be considered when
interpreting a report.
