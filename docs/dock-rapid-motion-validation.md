# Rapid Dock motion validation — September 18, 2026

## Change

The workspace page previously consumed the display-frame environment outside its
scroll view and `ForEach`. Every cursor frame rebuilt the workspace/action tree,
including menus and drag handlers in sections outside the magnification lens.

The page now constructs that tree from its snapshot. Small section modifiers read
the moving pointer and publish each section's magnification independently. Sections
outside the lens keep an identical environment value. App/configuration changes
still rebuild the snapshot content normally.

Icon and button layout sizes now stay at their resting size; scale and offset
transforms produce the magnified frames. This avoids renegotiating each child's
size every tick. The active-workspace dot remains unscaled. Icon geometry,
left-edge alignment, separator movement, scrolling, and compact-to-expanded
identity remain unchanged. This performance change does not alter the glass style.

## Optimized host measurements

Pinned Swift 6.2.4, ARM64. The rapid CPU/layout sweep moves 40 points per sample,
reverses every 12 samples, and records 120 warmed samples with four apps per
workspace. Before and after use the same benchmark and fixture.

| Workspaces | Before p50 / p99 | After p50 / p99 | After maximum |
| --- | --- | --- | --- |
| 3 | 3.06 / 3.14 ms | 1.82 / 2.12 ms | 2.16 ms |
| 8 | 6.97 / 7.31 ms | 3.58 / 3.73 ms | 3.93 ms |

Eight-workspace p99 fell about 49%, leaving more CPU time within the 8.33 ms
120 Hz budget. These are sampled layout costs, **not measured GPU presentation or
a guarantee of zero dropped frames**. The host's native benchmark skipped because
its physical display was asleep.

Run the rapid scenarios with the pinned toolchain and the usual manifest compiler
override for this Mac:

```sh
WINMUX_DOCK_SWEEP=rapid WINMUX_DOCK_BENCHMARK=1 \
  swift test --arch arm64 -c release --disable-swift-testing \
  --filter WorkspaceSidebarDockPerformanceTest
WINMUX_DOCK_SWEEP=rapid WINMUX_DOCK_NATIVE_BENCHMARK=1 \
  swift test --arch arm64 -c release --disable-swift-testing \
  --filter WorkspaceSidebarDockPerformanceTest
```

The native scenario sends eight pointer packets per callback, with the motion
controller retaining only the latest target for the next frame.

## Native Tart measurements

macOS 26.6.2, optimized ARM64 build, production sidebar panel, 60 Hz virtual
display, four apps per workspace, 240 measured callbacks after warmup. The same
glass material and eight-packet rapid sweep were used before and after.

| Workspaces | Before layout p95 / p99 / max | After layout p95 / p99 / max |
| --- | --- | --- |
| 3 | 8.79 / 10.44 / 12.14 ms | 8.19 / 9.32 / 13.19 ms |
| 8 | 10.69 / 11.00 / 12.59 ms | 8.36 / 8.59 / 8.84 ms |

Both versions delivered 60 display-link callbacks per second with zero missed
callback intervals in these short runs. Callback timing does not prove GPU
presentation. Eight-workspace p99 improved about 22%; the three-workspace maximum
still spiked. The VM does not establish an 8.33 ms worst-case bound or verify
physical 120 Hz presentation.

## Regression checks and review

- Full suite on the host (debug) and Tart macOS VM (optimized): **813 tests,
  three expected skips, zero failures** on each.
- ARM64 app and CLI build passed.
- New native-hosting regression verifies that rapid pointer updates leave off-lens
  view bodies unchanged, and that entering their lens immediately updates them.
- Prepared section origins match the shared column geometry through separators.
- Native mouse events successfully click an app at its magnified outer edge.
  Native anchor measurements continue matching the rendered magnified frames.
- Existing magnification, adaptive sizing, hit-target, morph, drag, and input tests
  pass.
- Claude (`claude-fable-5`) and agy (`gemini-3.8-flash-high`) independently reviewed
  both optimization stages and reported no confirmed blockers.
- Reviewers identified remaining section-height layout and preference propagation
  work. Geometry publication remains live because hover, click-through, and drop
  targets need the current displayed bounds; freezing it until pointer settlement
  would risk stale input regions. Native updates already coalesce hover rechecks.
- The suggested drag-coordinate risk does not apply: the recognizer uses global
  coordinates and forwards the native mouse sample. Morph-anchor hiding also
  matches the isolated dot's explicit opacity condition.
- Manual VoiceOver focus-frame verification remains outstanding.

Raw review and benchmark logs are under ignored
`.local/reviews/dock-rapid-motion-20260918/`. Physical 120 Hz presentation remains
unverified. This change does not install the app or publish a release.
