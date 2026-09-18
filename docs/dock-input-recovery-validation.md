# Dock input recovery — September 18, 2026

## Change

The 0.6.325 capture recorded 1,708 animation poses and three delayed callbacks, but
could not explain intervals when the Dock stopped responding and later recovered
without the pointer leaving. Input was split: native passthrough could send an
exit, while SwiftUI hover alone supplied new targets.

Native global/local pointer events now update each panel's motion target before
the 30 Hz expansion throttle. A persistent native tracking area also handles
non-key panels. All entry, movement, exit and geometry rechecks use the same
acceptance path. Tracking exits check the current position instead of blindly
clearing magnification. Guard changes recheck a stationary pointer asynchronously.
Only display callbacks publish animation frames; settled pointers sleep.

Visible surface/icon bounds, menu/drag/edit/Reduce Motion guards, spring behavior,
left-edge alignment and fork configuration remain. The separate local glass-style
draft is excluded from this change and from the VM source export.

Schema-2 debug reports add bounded input and lifecycle records that survive paused
animation. See [performance debugging](dock-performance-debugging.md).

## Validation

- Pinned Swift 6.2.4, ARM64: **848 tests, five expected opt-in skips, zero failures**.
  ARM64 development application build passed.
- Regressions cover native movement with no SwiftUI hover, repeated-target restart,
  stationary guard/geometry recovery, unthrottled delivery through a real panel,
  outside padding and protruding icons, window coordinates, hide/detach/reattach,
  teardown without state publication, stable tracking areas and diagnostic retention.
- A fully populated eight-current/eight-retired-panel report fits the 5 MB cap.
  Old schema-1 panel reports still decode.
- Optimized Tart/macOS 26 native run: **seven tests, zero failures**. The 15-second
  WindowServer input sweep posted 572 events, observed 161 local and 368 global
  mouse events, and produced 801 changed poses. Another application window was
  made key, then Finder was activated. The fixture used the production hosting
  hierarchy and event handler, without forced layout from display callbacks.
- VM capture: one flagged late callback (maximum gap 40.02 ms), maximum synchronous
  publication 0.255 ms, zero expensive publications and zero missed publication
  deadlines. These are callback/publication metrics, **not displayed GPU FPS**.

## Review and remaining limits

Independent Claude Fable 5 and agy Gemini 3.8 Flash reviews led to explicit non-key
tracking, publication-free teardown, corrected attachment telemetry, cheap blocked
and outside-window paths, and additional integration tests. Geometry already
schedules a native recheck through panel preferences; unconditional rechecks on
every SwiftUI update would add unnecessary animation work. Expansion previously
reset motion too, so that behavior was retained.

Both targeted follow-up reviews reported no remaining concrete blockers. Claude's
requested WindowServer-delivery merge check subsequently passed. SwiftUI-only
guard bits can lag their model change by one view-update cycle; live native
menu/drag/visibility guards and the scheduled recheck bound that remaining cosmetic
window. The `hidden` and `capture` diagnostic cases are used by panel hide and
recorder start, respectively.

The affected Mac17,3/macOS 27 machine and a physical 120 Hz display have not been
retested. VM timing cannot establish smooth physical presentation or eliminate
compositor stalls. Overlapping third-party windows and unusual event-routing
conditions remain native smoke-test scenarios. The update fixes the identified
input handoff weakness; it does not establish that every reported hitch had that
cause. No release or installed application was replaced during this work.

Raw reviews, source bundles, logs and capture analysis are under ignored
`.local/reviews/dock-input-recovery-20260918/`; the VM report is under
`.local/vm-share/results/`.

Apple references: [event monitors](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html),
[native tracking areas](https://developer.apple.com/documentation/appkit/nstrackingarea),
[hitch pipeline](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app).
