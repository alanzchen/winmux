# Tabs startup and sidebar resizing

## Reproduced failures

During an edge drag from 240 to 300 points, pointer hover can apply the new
sidebar width before the throttled resize refresh. The refresh previously
compared that width with the old 240-point setting and inferred that a second
project pane was open. This produced a 600-point sidebar while application
windows reserved only 300 points. Collapse/reopen reset the mistaken inference.
The native panel regression reproduces both pointer entry and exit in this gap.

At startup, the new-window placement path explicitly excluded existing windows,
including in Tabs mode. The subsequent startup layout heuristic could turn more
than three windows into a legacy stack. Tests also reproduced a stack being
created by a legacy default-root-layout setting. The three original regressions
failed 11 assertions before the fixes.

## Resulting behavior

Sidebar pane count comes from explicit project browsing state, independently of
the visible width. Hover and deferred resize refreshes can no longer mistake a
single resized pane for two panes. Intentional two-project browsing retains its
combined width when resizing or changing Settings.

Tabs mode gives unrestored regular windows their own tabs during startup without
activating each window as it is enumerated. Restored split layouts remain intact.
Tabs mode skips the legacy startup heuristic, automatic stack insertion, and
stack defaults for new workspace roots. Other modes and explicit window-placement
configuration retain their behavior.

## Validation

Swift 6.4, arm64 only:

- Initial focused sidebar, tab, saved-workspace, and new-window tests: 740 tests,
  seven skips, zero failures. Focused review follow-up: 42 tests, zero skips or
  failures; final timer correction: 18 tests, zero skips or failures.
- Full suite after review follow-ups: 1,445 tests, seven skips, zero failures.
- `swift build --arch arm64`: passed.
- Native AppKit panel tests cover the hover/resize race, repeated edge drags,
  rendered surface geometry, two-project resize, browse-state resets, and the
  earlier mouse-ownership regression. Startup-session tests cover native focus,
  restored-stack migration, and simulated secondary-display placement.

No WinMux process was running in the available desktop session. Live dragging
against another application's accessibility-managed window, startup with real
existing application windows, and physical multi-monitor checks remain unverified.

Independent reviewer reports and the scoped source bundle are retained under
ignored `.local/reviews/tabs-startup-width-*`.

The Claude Opus 5 and Gemini 3.8 Flash High reviews prompted a shared
project-browsing transition and additional startup-session, secondary-display,
collapse/reset, and narrowing-drag coverage. Checks against the surrounding code
confirmed that startup observes native focus before layout, restored stacks pass
through migration, burst opening already preserves tab order, and the layout
enum contains only tiles and stacks. Intentional restored splits and the explicit
new-workspace opt-out remain supported.

Claude's final follow-up identified a stale, brief collapse delay when closing
project browsing while already collapsed. Navigation changes now reset that timer
before the geometry guard, with a regression assertion. Both reviewers confirmed
the correction; no remaining blocking findings were reported. The existing hover
width clamp remains because its callers may already pass the combined pane width;
the resize refresh sets the final width from explicit browsing state.
