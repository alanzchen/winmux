# Dock performance review — 2026-09-17

Reviewed using Claude CLI (`claude-fable-5`) and agy CLI
(`gemini-3.8-flash-high`), followed by code inspection, regression tests and
measurements. Both CLIs ran read-only reviews of this repository. Raw transcripts,
the Instruments trace, and test logs are under `.local/reviews/` (ignored by Git).

## Changes supported by evidence

- **Native geometry:** hover previously converted every drop target on every
  visible monitor, sometimes twice per frame. Targets now remain in local view
  coordinates; a drag hit test converts the pointer once and projects only the
  winning rectangle. Current geometry is used after scrolling, moving or hiding
  a panel. Icon containment also converts one pointer instead of every icon.
- **Native rechecks:** surface and icon preferences update their caches immediately
  and share one deferred hover/passthrough check. This avoids checking a mixture of
  old and new geometry within a layout pass. Protruding icons remain interactive.
- **Rendering:** project filtering and app counts are prepared outside the frame
  callback. Sections beyond the lens use stable magnification inputs. Dock mode
  keeps a lazy stack through expansion and dragging, preserving gesture state.
  Sidebar mode retains its original eager stack.
- **Frame delivery:** horizontal-only motion does not restart the vertical lens.
  Legacy display callbacks coalesce while the main thread is busy. A delayed entry
  callback advances at most two display intervals, capped at 33 ms; a regression
  verifies that a 50 ms hitch at 120 Hz does not skip most of the entry ramp.
- **Drag cleanup:** a failing test reproduced a lifted icon surviving generic move
  reset. Both the idle fallback and provider completion now finish the sidebar
  gesture. The committed handoff remains until the destination model arrives.
- **Benchmark coverage:** the native fixture now uses the real registered panel,
  production actions adapter, deferred hover checks and installed app icons.

## Review claims that were not adopted

Neither reviewer measured production callback overhead. Specific claims of
10–25 ms overhead or an exact 120 Hz improvement were unsupported. The icon lookup
probe measured roughly 2 microseconds per cached-system miss, too small to justify
new negative-cache expiration behavior in this patch.

The committed handoff already has completion hooks in both workspace move paths;
removing it would restore a blank destination slot. All workspace apps are already
included in the layout, so the claimed capped-array indexing defect was absent.
Both existing and new drop lookup require the pointer inside the visible panel
before applying target hit slop; the suggested outer-edge regression was preexisting
behavior, not introduced here. Pointer-origin, hover hysteresis and reentry-velocity
changes lacked a reproduction and were left intact. Gemini retracted its unsupported
timing, source-quote, app-count and handoff claims during follow-up review.

A short-column eager-stack experiment improved debug median layout from 4.12 to
3.75 ms, but Claude identified that crossing its icon-count threshold could recreate
drop destinations during a drag. The experiment was removed. Stack identity now
stays stable through the compact-to-expanded Dock morph as well.

## Validation

Pinned Swift 6.2.4, ARM64 only. Host and Tart ran **786 tests**, with three expected
skips and no failures, plus application builds. Focused tests cover the reset-first
race, local clipping/hit slop, delayed entry, horizontal motion and queued frames.
The full motion/morph, all-icon, separator and drag handoff regressions also pass.

Optimized host CPU/layout benchmark, 120 samples per fixture, four apps per workspace:

| Workspaces | Baseline p50 / p99 | After p50 / p99 | After maximum |
| --- | --- | --- | --- |
| 3 | 3.80 / 4.42 ms | 3.22 / 3.33 ms | 3.36 ms |
| 8 | 4.15 / 4.35 ms | 3.86 / 4.45 ms | 5.16 ms |

These are individual runs, not a claim that every percentile improved. The larger
fixture's p99 remains near its baseline. This synthetic fixture omits native panel
callbacks and therefore cannot measure the removed cross-monitor work.

The real-panel Tart benchmark delivered **60 callbacks/s with zero missed intervals**
over 240 measured frames per fixture. Final debug layout p99/max was **8.97/10.69 ms**
for three workspaces and **10.18/11.18 ms** for eight. These debug spikes exceed an
8.33 ms budget. Deferred work contributes to callback cadence, but is outside the
synchronous layout timer. Delivery p99 was approximately 20 ms on the 60 Hz virtual
display. Screenshot: `.local/vm-share/results/dock-reviewed-native-final.png`.

An additional optimized native VM run also delivered 60 callbacks/s without missed
intervals. Layout p95/p99/max was **7.24/8.82/9.31 ms** for three workspaces and
**7.54/9.94/10.79 ms** for eight. Optimized native tail latency therefore still exceeds
the 8.33 ms target in the VM. The targeted Instruments profile attributes about
2.86 of 3.11 sampled main-thread CPU seconds to `NSHostingView.layout()` and its
SwiftUI graph/rendering work. The icon and badge lookup microbenchmarks were about
2–3 microseconds per lookup; no speculative cache or rendering rewrite was added.

These tests do not measure GPU presentation or establish physical 120 Hz smoothness.
A physical 120 Hz run and manual drag verification on the installed app remain
outstanding. The verified fixes do not establish that every reported stutter is
resolved. This work does not install the app or publish a release.
