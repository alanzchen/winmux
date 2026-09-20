# Expanded bottom Dock clipping validation

Validated locally on 2026-09-20, based on `eed58d9b`.

## Reproduction and cause

With the Dock at the bottom and a configured width of 280 points, open the
sidebar and select another project through **Other Projects**. Both project
panes initially fit in a 560-point surface. Running `reload-config` reproduced
the reported screenshot: the surface shrank to 280 points while the content
remained in two-project browsing mode, clipping both sides.

The normal panel refresh unconditionally restored the configured single-pane
width. Opening an editor/search and leaving a pinned sidebar had equivalent
width-reset paths. Pinning an already-open split view also lost the width
because the previous pinned width was absent.

The fix preserves the current expanded width when opening controls, tracks the
last configured pane width across pinned and unpinned modes, and only applies
setting-driven resizing when that setting changes. Explicit browse-mode changes
and ordinary collapse still resize directly. Closing search in pinned mode
retains both project panes. No timers, observers, or render loops were added.

## Automated validation

- The first three new regression tests failed against the original code, with
  13 failed assertions.
- Final focused run: 118 tests, no failures.
- Final full XCTest run: 988 tests, seven skipped, no failures.
- SwiftPM debug build and Xcode Release build passed using Swift 6.2.4.
- The local app and matching CLI both passed ARM64-only architecture checks;
  the test app passed ad-hoc signature verification.
- Five new regression tests cover routine refresh at all three Dock positions
  with auto-hide on/off, single/split width increases and decreases, pinned
  pointer exit, pinning an existing split view, editor preparation, and pinned
  versus unpinned command close.

## Native macOS checks

Used the isolated `winmux-tests` VM on an M2 Ultra host: macOS 26.6.2, a
1024-by-768-point Retina display, and six fixture application windows. The
baseline contained the code at `eed58d9b`; the candidate was a local Xcode app
labelled `0.6.329-bottom-local`. Its source and binary hashes are recorded with
the raw results. An unrelated working-tree glass appearance change was excluded.

The baseline failed the native accessibility geometry check after refresh:
the search control measured 256 points wide instead of the expected 536.
The candidate retained the expected 536-point width and centered placement
through five consecutive reloads. Screenshots confirmed that both panes fit.

Additional native checks passed:

- Split widths followed pane settings of 280 → 320 → 240 → 280 points.
- Pinning an open split view and moving the pointer away retained both panes.
- Starting search and pressing Escape in pinned mode retained both panes.
- Both panes and the clock remained inside the expanded surface with the clock
  enabled and seconds hidden.
- Unpinning returned to the compact Dock; reopening started with one pane.
- Pointer exit after the brief split-browse grace period returned to the
  compact Dock.

An existing command-toggle quirk was reproduced in both baseline and candidate:
after opening through the CLI, browsing a second project, and collapsing by
pointer exit, the first subsequent `open-sidebar` command can clear a retained
inline input session instead of reopening. This separate behavior is not changed
by the clipping fix. The failed initial reopen checks remain in the raw results.

Physical MacBook Air and multiple physical display smoke checks remain untested.
This work did not publish a release or replace the host's installed app.

## Independent reviews

Claude CLI (`claude-fable-5`) and agy CLI (`gemini-3.8-flash-high`) independently
reviewed the scoped diff and surrounding code. Their pin-transition and inline
editing findings were verified and fixed. Both targeted follow-up reviews found
no blocking issues in the final code. The full suite and native checks above
were completed after supplying the follow-up review bundle.

Raw review reports, build/test logs, and source manifests are under
`.local/reviews/bottom-expanded-20260920/`. Native screenshots, accessibility
trees, and geometry results are under
`.local/vm-share/results/bottom-expanded-20260920/`.
