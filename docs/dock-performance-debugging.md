# Dock performance debug mode

## Record a stutter

1. Select **Dock** in **Settings → Dock & Sidebar → Mode**. Then open
   **Advanced → Diagnostics** and enable
   **Record Dock performance (debug mode)**.
2. Move over the Dock normally: sweep across icons and separators, reverse
   direction, and leave/re-enter the rail. Screen recording is optional.
3. Turn the toggle off to save, or let the capture stop automatically after two
   minutes. Use **Show performance report in Finder** to find the JSON report.

Reports are local to `~/Library/Logs/WinMux/DockPerformance/`. Nothing is uploaded.
Recording starts off on every launch and does not change TOML configuration.
Keep separate captures when comparing settings, materials or screen recording.

## What gets recorded

The recorder samples active animation callbacks and native pointer/lifecycle events,
including periods when animation is paused. It stores 512 recent frame samples,
128 suspected timing samples, 256 recent input events and 128 input/state transitions
per panel, for up to eight current panels. Closed panels retain a smaller tail,
capped at eight archived panels.
Overwritten samples, archived panels and omitted panels are counted explicitly.

Records include:

- Actual callback arrival and native display-link timestamp, target and duration.
- State-publication end and first subsequent main-run-loop `beforeWaiting` time
  for the last callback in a turn (earlier coalesced callbacks have no such stamp).
  Suspect samples retain the preceding publication/run-loop times for context.
- Latest accepted vertical hover target's receive time and new-input count.
- Native pointer-event timestamp and receive time, inside/accepted/changed-target
  flags, magnification blockers, mouse passthrough, driver pause/resume/reset and
  attachment state. Each event carries the last callback time and frame sequence.
  These records continue while the driver sleeps; no idle polling is added.
- Geometry/preference update counts, tiny column-origin changes, relative shelf
  movement, icon counts and native hover-recheck counts.
- Refresh-session spans, including asynchronous waits; these are **not CPU time**.
- Version/hash, macOS/hardware model, CPU count, power/thermal state, display
  maximum refresh rate and scale, and settings at capture end.

There are no app names, window titles, screenshots, keyboard events, serial numbers
or absolute cursor positions. Debug builds may contain development version metadata;
signed release builds embed their release source hash.

Capturing never publishes per-frame Settings state or performs per-frame file I/O.
At stop, serialization runs off the main actor. Each report is limited to 5 MB;
rotation keeps the newest three reports. The directory is private (`700`), and
reports use permissions `600`. The interface reports write failures.

## Interpreting possible issues

Timing values are seconds in the `CACurrentMediaTime` host-clock domain, except
`nativeTimestamp`, which retains the original `NSEvent.timestamp` (system uptime).
Each capture has a UTC/host-time anchor. Each panel has its own sequence numbers.

Schema 2 adds an `input` report per panel. Schema-1 reports lack this information.
`recentEvents` contains the latest packets, including rejected or unchanged targets;
`transitions` separately retains lifecycle and acceptance changes so ordinary
movement does not immediately overwrite freeze/recovery context. There is no
SwiftUI hover handoff: native input directly updates the display-link target.
`nativePointer` records the global/local monitors; `tracking` records the native
tracking area (active even for a non-key panel). Both use the same acceptance path.
An input event records state **before** applying that target; a following `resume`
records the driver waking. Settled targets intentionally stop display callbacks.

The `blockers` bitmask combines disabled (1), expanded (2), Reduce Motion (4), menu
(8), editing (16), drop preview (32), swipe (64), drag (128), hidden (256) and detached
(512). Inspect rejection and recovery transitions before interpreting callback gaps:

- Native input with `accepted=false`: inspect `blockers` and `inside`.
- Changing accepted targets with no subsequent callbacks: investigate driver lifecycle.
- Continuing targets and callbacks during a visible freeze: profile rendering separately.
- No input records during a freeze: event delivery or main-thread work remains possible;
  absence alone does not prove that the cursor moved during that interval.

- `lateCallbacks`: a changed pose arrived more than 1.5 observed display intervals
  after the previous callback, outside the cadence warm-up/reset period.
- `expensivePublications`: publishing a changed pose used more than half the
  nominal frame budget. This does not include deferred SwiftUI layout.
- `missedDeadlines`: state publication finished past the native next-frame target.
- `maximumRunLoopTail`: time until the main loop first prepared to sleep after
  publication, including unrelated work. It is not a GPU completion timestamp.

These are **suspicions, not measured dropped presentations**. Inspect retained
samples alongside aggregate counts, which cover the whole capture. Latest-input
age naturally increases while the pointer is stationary and the animation settles;
only samples with new input measure fresh target delivery. Geometry counters are
correlated with callbacks in time, not a one-to-one proof of rendered frames.

Idle pauses, wake and cadence changes reset comparison baselines. `cadenceChanged`
marks a changed interval; the two-frame warm-up conservatively excludes those
frames from late/deadline classification, so inspect their raw timings too. On macOS 13,
`nativeDisplayTiming` is false: the legacy driver provides a callback host time,
not a next-frame deadline; `targetTimestamp` is zero and deadline/late-frame
classification is disabled. Its interval is a nominal display-rate hint.

SwiftUI/Core Animation already use GPU rendering. CPU view/layout work can still
delay a frame, and healthy callback timing cannot rule out compositor/GPU hitches.
Use Apple's [SwiftUI performance tools](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
and [Hitches guidance](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
when a report needs deeper attribution.

## Development checks

Use the pinned Swift 6.2.4 toolchain and `--arch arm64`:

```sh
swift test --arch arm64 --filter DockPerformanceTraceTest
WINMUX_DOCK_BENCHMARK=1 WINMUX_DOCK_SWEEP=rapid swift test -c release --arch arm64 --filter WorkspaceSidebarDockPerformanceTest
WINMUX_DOCK_INPUT_BENCHMARK=1 swift test -c release --arch arm64 --filter WorkspaceSidebarDockPerformanceTest.testNativeHoverCapture
```

For WindowServer delivery (including a non-key Dock and another active app), add
`WINMUX_DOCK_SYSTEM_INPUT=1`. This requires input-posting permission on the test
desktop and skips clearly if unavailable. Use `--disable-swift-testing` in Tart
for this XCTest-only native run; its AppKit loop can conflict with SwiftPM's second
Swift Testing discovery process.

The opt-in native hover test moves the pointer on an unlocked test desktop. It
uses the production native pointer handler and deferred layout, with a separate
input timer; it does not drive input or force layout from a display callback.
It measures synthetic input-injection overhead separately. Prefer the Tart test VM
for this automation; VM timing cannot certify physical 60/120 Hz presentation.
