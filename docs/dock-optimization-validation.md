# Dock optimization validation — September 20, 2026

This pass investigates the Claude Opus 5 recommendations against the native
compact Dock. It preserves the actual-growth glass shelf, smooth magnification,
icon geometry, corner hit testing, and existing controls. It also includes the
previously committed hover-spacing correction after 0.6.333.

The **under-3% interaction CPU target remains unmet**. The new optimizations
reduce a matched bottom/120-events-per-second run from 6.331% to 5.780%, about
8.7%. This comparison is against the corrected, snug shelf, not the fixed-size
shelf shipped in 0.6.333. Idle and full interaction results are recorded below.
CPU percentage represents one occupied core at 100%; it is not power usage.

## Changes retained

- Replace the reflective artwork cache string with a typed structural key. Focus
  and opacity updates retain app layers and image subscriptions; workspace title
  styling still updates. Image size, rendered workspace identifier, full app
  identity, backing scale, and magnification raster scale still invalidate art.
- Answer rectangular interior hit tests directly. Curved corners and exact
  boundaries use the original Core Graphics path, created lazily. Both shelf
  geometry and radius changes invalidate that path.
- Remove intermediate geometry arrays and zero-scroll copies, reserve output
  capacity, and skip unchanged layer property setters.
- Pause the display link on temporary interaction resets; retain the existing
  display cadence and resume behavior. Detachment still invalidates the link
  and releases its target. Artwork teardown clears its structural cache key.

No animation throttling, lens quantization, pixel snapping, fixed maximum shelf,
or changes to glass appearance are part of this patch.

## Component attribution and rejected experiments

A separate diagnostic Release app held one component at its first frame during
continuous bottom-Dock movement. These variants deliberately violate appearance
and were never included in production. Each used a fresh process, 20 seconds of
settling, 10 seconds of pointer warm-up and at least 60 seconds of measurement.

| Component held fixed | WinMux mean CPU | WindowServer mean CPU |
| --- | ---: | ---: |
| None, initial baseline | 5.766% | 28.734% |
| Glass frame | 4.662% | 30.222% |
| Rim | 6.207% | 31.605% |
| Leading/trailing controls | 5.704% | 30.259% |
| Clipping rectangle | 6.175% | 31.758% |
| Geometry publication callbacks | 6.213% | 31.571% |
| None, repeat baseline | 5.974% | 30.333% |

Only holding the glass frame fixed showed a clear app CPU reduction. Component
deltas are not additive; the WindowServer totals include other desktop work.
These measurements do not justify changing the clipping model, freezing control
hosts, suppressing geometry callbacks, or changing rim drawing. Input/geometry
precomputation beyond simple allocation removal remains a profiling opportunity,
not an established performance win.

A separate ten-second sampling profile traced glass resizing through AppKit
frame-to-constraint updates into SwiftUI's platform-view host. Disabling the
translated autoresizing constraints collapsed the native glass view to 10×10
points after layout. Removing intrinsic size did not fix it. Explicit size
constraints rounded fractional shelf coordinates: for example, a requested
357.840481-point height became 358 points. The original frame-managed glass
preserved the exact geometry. All these experiments were rejected and reverted;
regression tests now cover both direct pointer rendering and AppKit layout.

The earlier spacing fix makes the shelf follow actual icon growth. A fixed shelf
costs less to resize but leaves the empty padding the user reported. Preserving
the intended appearance therefore keeps the resizing work until a geometry-
preserving alternative is demonstrated. This does not establish an inherent
SwiftUI or AppKit limit.

## Final measurements

| Configuration | WinMux mean CPU | Highest ~5 s interval | WindowServer mean CPU |
| --- | ---: | ---: | ---: |
| Spacing-fix baseline, bottom, 120 events/s | 6.331% | 6.703% | 31.796% |
| Candidate, bottom, 120 events/s | 5.780% | 6.259% | 30.457% |
| Candidate, left, 120 events/s | 5.752% | 6.021% | 28.479% |
| Candidate, bottom, 60 events/s | 4.514% | 4.772% | 27.896% |
| Candidate, left, 60 events/s | 5.279% | 5.882% | 27.177% |
| Candidate, left, idle after menu | 0.606% | 0.761% | — |
| Candidate, bottom, idle after menu | 0.705% | 0.936% | — |

All seven runs passed the measurement-validity checks. Both idle runs passed
all-intervals-below-2%; all four candidate interaction runs failed the under-3%
mean gate. Actual movement rates were 119.999 or 59.999–60.000 events/s; maximum
input gaps were 10.2–12.4 ms at 120 events/s and 18.8–19.0 ms at 60 events/s.
The highest interval is not an instantaneous peak. This is one paired bottom
comparison and one sample per other configuration; it is not a statistical
confidence interval or evidence of a battery-life improvement.

## Method and scope

Measurements use the Xcode Release configuration, Swift 6.2.4, ARM64, in an
isolated macOS 26.6.2 Tart VM on an Apple M2 Ultra host with eight virtual CPUs.
The Retina display is 1024×768 points. There is one workspace and six app icons,
48-point resting icons, 1.5× magnification, clear glass, badges, a minute-only
clock, and auto-hide disabled. Each interaction row uses a fresh process,
20-second settling, ten-second movement warm-up, then at least 60 seconds of
continuous sinusoidal input. Builds, tests, screenshots, accessibility inspection,
and sampling profilers are excluded from timed measurements. WindowServer is
sampled separately. Screenshots and functional checks follow the timed intervals.

Idle checks first open and dismiss a workspace context menu, move the pointer
away, warm up for 20 seconds, then measure at least 60 seconds. This exercises
the temporary-reset link pause path as well as stationary idle. The idle gate
requires every roughly five-second CPU interval below 2%; the interaction gate
requires mean CPU below 3%. All measurements require an awake display.

The isolated candidate excludes the unrelated working-copy glass-style edit.
Its active rendering code matches the final patch. A subsequent teardown-only
cache-key invalidation and extra tests do not execute in the measured steady
state. The signed release is rebuilt from the clean committed source.

## Validation and independent review

The final ARM64 suite passed **1,007 tests, seven expected skips, zero failures**.
The amended native Dock/pointer subset passed all 21 tests. The Xcode ARM64
Release build passed; the local release pipeline repeats tests and builds from a
clean checkout. Focused coverage includes cache invalidation and reuse, exact
rounded hit regions on all three edges, native glass layout, backing-scale
changes, display-link pause/recovery and teardown lifetime.

Native VM smoke checks confirmed mouse activation of Calculator, accessibility
activation of Notes, workspace context menu opening/dismissal, magnification
recovery after the menu, bottom expansion through accessibility and automatic
collapse, left auto-hide/reveal/hide, right-edge hover geometry, and WinMux
recovery after revealing and dismissing the native macOS Dock. Screenshots show
tight padding over icons and controls and an unclipped bottom expanded view.
The first mouse-driven expansion screenshot had already returned to compact;
expansion was verified separately with the pointer held inside the expanded
region. This is not a measured menu-hover latency test.

Actual Claude CLI `claude-opus-5` and agy CLI `gemini-3.8-flash-high` performed
independent read-only reviews with scoped source and diff bundles, followed by
targeted reviews. Accepted findings added an independent backing-scale key for
the create glyph, removed duplicate reset trace events, and invalidated the
artwork key at teardown. Tests now explicitly check unchanged artwork reuse,
exact corner boundary points, direct-render glass geometry, backing-scale
collisions, temporary reset recovery and detached-driver release.

The potential post-detach stale-artwork case is defensive: SwiftUI dismantling
is terminal in production; this patch does not introduce a reusable dismantled
view lifecycle. The reviewer request for radius-only invalidation coverage is
not a separate production path here: compact rail width derives from icon size,
which also changes the artwork key and invalidates geometry. App identity uses
synthesized equality over all stored fields; no app identity field was dropped.

Physical MacBook Air CPU/power, physical multi-monitor moves, GPU use and
battery-life changes remain unmeasured. Context-menu targeting during an
in-progress structural animation remains a separate audit opportunity, not a
confirmed regression introduced by these optimizations. No claim that all
performance work is complete is made.

Raw reviews: `.local/reviews/dock-optimization-20260920/`. Attribution, profiles,
CPU reports, input-generator reports and screenshots are under
`.local/vm-share/results/native-dock-20260920/optimization-attribution/`,
`optimization-profile/`, `optimization-final/` and `smoke-optimization/`.
