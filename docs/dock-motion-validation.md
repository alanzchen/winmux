# Dock motion validation

## Rendering and timing

On macOS 14 and later, magnification uses a view-bound `CADisplayLink`. It follows
the view's display and requests that display's maximum refresh rate, including
120 Hz and higher. macOS 13 retains the existing display-refresh driver. Pointer
events only replace a target; display callbacks deliver one interpolated pose.
The link pauses when the pose settles and is invalidated when the view detaches.

A critically damped spring starts enlargement from zero velocity, reaching about
91% after 100 ms. Sizes, neighboring positions, separator movement, and shelf
height share its strength. Exit retains the last valid pointer until the spring
settles, including when a protruding icon shrinks away from that point. Reduce
Motion, menu tracking, expansion, and dragging still suppress magnification.

Per-frame state lives below the sidebar's root. Compact buttons share their icons'
computed geometry instead of measuring a second overlay. Icons and badges scale
from resting dimensions, and compact hover no longer publishes workspace models.

## Reproduce the checks

Use Swift 6.2.4 and Apple Silicon:

```sh
TOOLCHAINS=org.swift.624202602241a xcrun swift test --arch arm64
TOOLCHAINS=org.swift.624202602241a xcrun swift build --arch arm64
TOOLCHAINS=org.swift.624202602241a WINMUX_DOCK_BENCHMARK=1 \
  xcrun swift test --arch arm64 --configuration release --disable-swift-testing \
  --filter WorkspaceSidebarDockPerformanceTest
TOOLCHAINS=org.swift.624202602241a WINMUX_DOCK_NATIVE_BENCHMARK=1 \
  xcrun swift test --arch arm64 --configuration release --disable-swift-testing \
  --filter WorkspaceSidebarDockPerformanceTest
```

The pointer benchmark reports CPU/layout p50, p95, p99, and maximum durations.
The native benchmark opens temporary glass Docks at the screen's right edge,
drives real display callbacks, and includes periodic root-model updates. It
reports callback cadence, missed display intervals, delivery jitter, and layout
durations. Wake and unlock the display first. Neither benchmark measures GPU
presentation; virtual-display timing cannot establish physical 120 Hz smoothness.

Focused regressions cover burst coalescing, gentle entry, equal response at
60/120 Hz, rapid reversal, exit beyond the resting rail, idle suspension, resets,
fixed left edges, separators, native hit regions, and compact/expanded morphs.

## Drag completion

Lifting the last app icon removes its source view, which can prevent SwiftUI from
delivering the gesture's `onEnded`. Both the native mouse-up fallback and local
mouse-up events now finish the sidebar session. Gesture cleanup clears live hover
previews while retaining a committed destination until its workspace model arrives.
Provider drops clear the preview immediately even when the pointer stays over the
target. Regression tests cover the missing gesture callback, duplicate mouse-up,
and committed handoff retention.

## Validation record — 2026-09-17

Host and isolated Tart results are recorded in `.build/prerelease-validation/`.
Both ran 779 tests with three expected skips and no failures, followed by an
application build. The VM's native benchmark delivered 60 callbacks per second
with zero missed display intervals across both fixtures (240 measured frames each).
VM debug layout p99 was 7.85 ms / 7.84 ms; callback-delivery p99 was about 19.9 ms
on its 60 Hz virtual display. These are separate from host optimized CPU timings.

Host optimized CPU/layout results (120 measured samples, four apps per workspace):

| Workspaces | p50 | p95 | p99 | Maximum |
| --- | --- | --- | --- | --- |
| 3 | 3.26 ms | 3.71 ms | 4.08 ms | 4.39 ms |
| 8 | 3.95 ms | 4.95 ms | 5.73 ms | 6.13 ms |

These sampled durations fit an 8.33 ms CPU frame budget; they exclude GPU
presentation and the live window manager's other work. Optimized XCTest was run
with `--disable-swift-testing`: the package's CLI entry point otherwise rejects
the separate Swift Testing runner's `--test-bundle-path` invocation after XCTest
passes. The ordinary debug suite runs successfully without that flag.

The native VM screenshot is `.local/vm-share/results/dock-120-native.png`.
The connected physical display reports 60 Hz; its desktop was locked during the
native checks. Physical 120 Hz presentation and a manual drag on the installed app
remain unverified. These changes have not been installed or released.
