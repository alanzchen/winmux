# Menu bar hover validation — September 20, 2026

WinMux's top menu bar dropdown could leave the highlight on an earlier row while
the cursor moved. This reproduced in published 0.6.329 as well as the current
code before this fix, including with window management disabled.

## Cause and change

On the test desktop, an installed AppKit global mouse-move monitor interfered
with native menu tracking. A minimal SwiftUI menu reproduced the delay even when
the global monitor's handler did nothing. A local monitor alone stayed fast.
Returning early from the global handler did not fix the delay; removing that
monitor for the duration of menu tracking did.

WinMux now removes its main global pointer monitor synchronously when a native
menu starts tracking and restores it when the last tracked menu closes. Menu
identities prevent duplicate notifications or nested menus from restoring it
early. Local input and the separate keyboard, mouse-up, and drag observers remain
available. Dismissal resamples the current pointer and schedules one Dock/sidebar
hover recheck, including when Escape leaves the pointer stationary over an icon.
There is no new timer or recurring polling.

The implementation uses AppKit's
[menu tracking notifications](https://developer.apple.com/documentation/appkit/nsmenu/didendtrackingnotification),
including the end notification sent when a menu is cancelled.

## Native measurements

Test environment: Tart macOS 26.6.2 on Apple M2 Ultra, arm64, 1024 × 768-point
Retina display. The left Dock had six app icons, glass, magnification, badges,
and a clock without seconds. The final local Release app was built with Swift
6.2.4 from `e69c1f15` plus this fix, with matching CLI metadata
`0.6.329-menu-local`. Native builds excluded the unrelated local glass experiment.
App and CLI SHA-256 hashes matched between host and guest and stayed unchanged
through validation. Automatic updates were disabled in the guest.

The helper posts cursor movement, then observes the target menu item's
`AXSelected` state. Additional movement packets arrive about every 8 ms until
selection is observed, with a 500 ms timeout. These numbers include input
injection and accessibility-query overhead; they are not physical display or
GPU presentation latency.

| Case | Successful row selections | Median | 95th percentile | Maximum |
| --- | ---: | ---: | ---: | ---: |
| Current code before fix, rerun after builds completed | 139 / 140 | 29.72 ms | 221.88 ms | ≥500 ms timeout |
| Final fix, hover | 210 / 210 | 5.90 ms | 7.06 ms | 7.52 ms |
| Final fix, press-hold-drag selection | 140 / 140 | 5.93 ms | 7.25 ms | 16.41 ms |

Earlier full-app runs also passed 420/420 hover selections with maxima below
11 ms. Entering the dropdown from active sidebar search passed 70/70 selections.
The minimal control using the production monitor owner, with the other global
observers still installed, passed 140/140 with a maximum of 7.68 ms.

After final menu and hover checks, a 60.52-second idle measurement with a
15-second warm-up averaged **0.680% CPU**, with a highest complete five-second
interval of **0.745%**. The display remained awake and the sampler verified no
input during the measurement. CPU is process user plus system time, where 100%
is one core. Every interval stayed below the existing 2% target.

## Functional checks and review

- Arrow-key navigation selected the expected row; Escape dismissed the menu.
- Clicking Copy to clipboard executed the expected action and closed the menu.
- With the cursor moved onto the Dock while the menu was open, Escape restored
  magnification without another movement packet. The Calendar icon's accessible
  frame grew from 48 × 48 to 72 × 72 points; a screenshot confirmed the result.
- Four new regressions cover monitor removal/restoration, nested and duplicate
  notifications, stop/start behavior, and recovery from registration failure.
- Final focused menu/pointer tests and the full suite passed: **983 tests,
  7 skipped, zero failures**. SwiftPM arm64 build and Xcode Release build passed.
- Claude (`claude-fable-5`) and agy (`gemini-3.8-flash-high`) completed independent
  reviews and targeted follow-ups with no blocking findings. Review prompted
  the fresh pointer sample on resume and direct verification of drag selection.
  The suggested drag-monitor interference did not reproduce, so that observer
  was preserved. The pointer sample's default timestamp uses system uptime.

Raw source manifests, reviews, test/build logs, and the final measurement summary
are under `.local/reviews/menu-hover-20260920/`. Native helpers are under
`.local/vm-share/input/menu-hover-20260920/`; JSON results and the recovery
screenshot are under `.local/vm-share/results/menu-hover-20260920/`.

This validates the local macOS VM. The affected MacBook Air, physical frame
presentation, additional displays, and older macOS versions remain untested.
No release was published and the host's installed app was not replaced.
