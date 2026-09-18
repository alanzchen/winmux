# Dock stutter investigation — September 18, 2026

## Status and evidence

The user still sees intermittent stutter in the latest WinMux on an **M5 MacBook
Air at 60 Hz**. The recording is from that machine; the development Mac's installed
0.6.322 copy is unrelated. Investigate released source **0.6.323 / a5608c6d**.
The uncommitted regular-glass experiment is excluded from this baseline.

The supplied 25.15-second video contains 1,407 frames: 1,305 frame intervals of
16.67 ms, 100 of 33.33 ms, and one of 50 ms. Longer intervals become more frequent
near the end of the clip, when motion subsides. These are **recording intervals**,
not measured application drops. Frame coalescing, capture overhead, and app stalls
remain possible explanations. Sampled frames show two workspaces, with eight app
icons in the first and none in the second.

An optimized, pinned Swift 6.2.4 retest from the released source measured CPU/layout
p99 of **2.47 ms** for three workspaces and **3.79 ms** for eight, with four apps per
workspace. The physical-display benchmark skipped because the development display
was asleep. Neither result establishes smooth presentation on the Air.

A fresh optimized native Tart run passed on its 60 Hz virtual display:

| Workspaces | Layout p99 / max | Callback arrival p99 / max |
| --- | --- | --- |
| 3 | 9.05 / 9.21 ms | 20.17 / 20.25 ms |
| 8 | 8.69 / 9.20 ms | 19.98 / 20.13 ms |

Each case recorded 240 samples and nominal target-timestamp cadence of 60 Hz,
with no gaps above the benchmark's 1.5-interval threshold. Actual callback arrivals
still varied. This illustrates why target-timestamp FPS alone is insufficient;
it does not establish missed presentation or reproduce the Air's symptom.

## What the current tests miss

`WorkspaceSidebarDockPerformanceTest` supplies pointer positions directly to the
motion controller. Its native observer also forces layout synchronously. This
exercises geometry callbacks but bypasses normal pointer delivery, SwiftUI hover
handling, and the global pointer monitor. Short runs and regular display-link
callbacks cannot establish that the compositor presented every intended pose.

Confirmed work worth measuring:

- `WorkspaceSidebarDockAnimationHost` changes the shelf's height and centered
  origin as magnification grows. Its glass surface changes geometry with it.
- Surface/icon preferences update native hit regions and request a hover recheck.
  `hasPendingHoverRecheck` already coalesces requests; queue flooding is unproven.
- `acceptedPointer` builds a shape path during hover handling, outside the
  display-link coalescing path.
- The 10 ms pointer interpolation time constant follows about 81% of a new target
  per 60 Hz frame. Variable input age or coordinate movement could look jerky even
  when frames arrive on time. This is a hypothesis, not a diagnosed defect.

Badge accessibility reads already run off the main actor, and app icons are
cached. Measure cache misses, badge publications, and refresh-session overlap
before changing them.

## First increment: automatic diagnostic capture

Add an opt-in **Record Dock performance** control. A capture ends automatically
after two minutes, with Stop/Export available sooner. During capture, record
timings automatically while the user moves normally; screen recording is optional.

1. Keep a preallocated, bounded ring of approximately 512 numeric samples per
   panel. Sample only while animation is active; do not add idle polling.
2. Record callback arrival, display-link timestamp/target/duration, synchronous
   state-publication end, latest input receive time, event count, pose-change flag,
   lifecycle/reset flags, and preference/recheck counters. Distinguish an actual
   `NSEvent.timestamp` from a SwiftUI hover callback's receive time.
3. Record frame and observed geometry generations plus local movement deltas to
   investigate shelf motion or stale coordinates. SwiftUI may coalesce updates:
   generation proximity is correlation, not proof of a one-to-one rendered frame.
   Diagnostics must not invalidate otherwise unchanged off-lens views.
4. Use one verified monotonic clock domain and one UTC/session anchor. Do not mix
   `mach_continuous_time()` with display-link times without explicit conversion;
   reset the cadence baseline on idle/resume, sleep/wake, or display/rate changes.
5. Snapshot a bounded number of suspect episodes with surrounding samples. Arrival
   gaps above 1.5 observed frame intervals and negative deadline slack are initial
   triggers, not proof of dropped presentation. Analyze raw fields after capture.
   Account for variable refresh, pause transitions, and unchanged poses.
6. No string formatting, file writes, or per-frame logging on the animation path.
   Serialize captured data off the main actor at stop/timeout, with bounded output
   and explicit dropped-sample counts. Keep at most three local reports of 5 MB
   each. Include build/hash, OS, hardware class, display rate/scale, settings, and
   workload counts; exclude app identities, titles, screenshots, and absolute
   cursor tracks. Share reports only through an explicit export.

Call the measured interval **state-publication time**. Returning from
`withTransaction` does not mean SwiftUI layout, Core Animation commit, or GPU
presentation has finished. Add scoped signposts around input, publication,
preference processing, and hover rechecks; correlate with existing refresh-session
signposts. Keep expensive trace collection separate from normal logging.

## Reproduction and attribution

Start with the reported two-workspace layout, matching icon size, magnification,
opacity, backing scale, and appearance. Record power/thermal conditions. Use
optimized builds and three 60-second runs through the **real pointer path**:
rapid sweeps, reversals, separator crossings, stationary hover, and edge exits.
Do not inject targets from the frame callback or force layout during measurement.

Prioritize these experiments:

1. Default glass, screen recording off: capture input age, pose/geometry movement,
   callback cadence, and native timing on a 60 Hz display. Repeat on the affected
   Air; a VM cannot substitute for its GPU and display.
2. Repeat with recording on to separate capture-related load from ordinary use.
3. When a stall reproduces, attach SwiftUI/Time Profiler and Hitches tracing;
   use Metal System Trace when compositor/render work needs investigation.
4. Compare glass with solid material using identical geometry, as a diagnostic
   experiment. A difference implicates the material path but does not prove a
   particular texture allocation or justify removing glass.
5. If timing stays healthy, examine shelf recentering, input age, and pose/geometry
   skew. Only then test a fixed shelf envelope, bounded eager layout, or a different
   pointer filter. Measure added input latency before accepting extra smoothing.

Preserve fresh hit regions, click-through, drag/drop, separators, and left-edge
alignment throughout. Do not freeze hover handling until animation settles.

## Validation and review decisions

Test the recorder with simulated 60/120 Hz cadence, stalls, idle/wake/rate changes,
multiple panels, unchanged poses, and bounded retention. Compare diagnostics on
and off; aim for under 1% of the frame budget and simplify if overhead is material.
Report p50/p95/p99/max, suspect events per 1,000 active frames, input latency, and
commit/render hitch durations separately. A successful fix must eliminate the
reproducible, attributed problem across repeated runs and preserve interaction
regressions. Do not describe callback FPS as displayed FPS or claim physical
120 Hz verification from 60 Hz tests.

Claude CLI (`claude-fable-5`) and agy CLI (`gemini-3.8-flash-high`) completed
independent diagnoses and a follow-up discussion. Both supported investigating
the input-path gap, geometry/preference work, and glass rendering. We rejected
unsupported claims that preferences flood the queue, glass necessarily reallocates
textures every frame, or a preferred refresh range guarantees delivery. Recording
gaps alone also do not prove frame coalescing. Both recommended starting with
minimal telemetry before expanding the experiment matrix.

Raw reports, source bundles, recording analysis, and test logs are under ignored
`.local/reviews/dock-stutter-20260918/`. This document is an investigation plan;
the diagnostic capture is not implemented yet.

## Apple references

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
- [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
- [CADisplayLink targetTimestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/targettimestamp)
