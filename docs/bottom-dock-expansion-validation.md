# Bottom Dock expansion handoff validation

Date: 2026-09-20. Baseline: published 0.6.334 (`3b691b69`).

## Reproduction and cause

In a macOS 26.6.2 Apple Silicon VM, clicking the compact Dock's up arrow with
real Core Graphics mouse events and then moving into the workspace rows collapsed
the expanded panel. Five sweep durations (0.06, 0.15, 0.3, 0.6 and 1.0 seconds)
failed on the published build. AXPress with the pointer already inside the expanded
surface stayed open, so that earlier smoke path did not exercise the bug.

An instrumented build showed the expanded surface `(372, 296, 280, 444)` being
replaced by compact bounds around `(217, 674, 589, 64)`. SwiftUI retained the
outgoing native view during its transition. Its controller had a new owner, but its
old input and display link remained attached and continued publishing hit geometry.

The controller now detaches its previous driver when ownership changes. Retained
native views cannot publish surface, icon or drop geometry, reclaim ownership from
a backing-property callback, or intercept clicks after another renderer takes over.
A fresh compact snapshot can reclaim ownership normally when the panel collapses.
The fix does not add hover delays or enlarge invisible interaction regions.

## Automated validation

- The new all-placement regression failed before the fix with 24 assertions.
- The regression covers late pointer/display/layout callbacks, backing changes,
  surface/icon/drop publications, click routing and return to compact mode.
- 71 focused Dock, pointer, motion, auto-hide, gap and placement tests passed.
- Full arm64 Swift 6.2.4 suite: 1,008 tests, seven opt-in tests skipped, zero failures.
- All five original mouse-click/sweep paths stayed expanded with the ownership fix.

Final native checks used two projects, six application windows and a clock showing
seconds, date and weekday. With auto-hide both off and on, the expanded panel stayed
open over its top project filters, search and every workspace/window row. Real clicks
opened search and the Other Projects menu, and a Calendar row click activated Calendar.
Escape, reopening, and moving outside collapsed/hidden states worked. Earlier smoke
script failures were fixture issues: blank-description text fields were omitted from
the AX probe, Escape intentionally closed the panel, and the exact bottom screen pixel
invoked the native macOS Dock; the final run accounts for those behaviors.

## Independent review

Claude Opus 5 and agy (`gemini-3.8-flash-high`) reviewed the diff and scoped source,
then reviewed the supported fixes. Opus identified backing-change ownership reclamation
and outgoing click interception; both are guarded and covered by the regression. The
click guard is confined to `hitTest` so outgoing visual geometry remains unchanged.

Opus's later lifecycle hypotheses were checked against the owning view: one stable
`@State` controller is shared by both branches, and the native branch is selected only
at compact width. Constructing a compact renderer while that view is expanded is not
a path in this code. Runtime instrumentation observed reconfiguration during the
expected return to compact mode; the native interaction checks did not reproduce an
outgoing update stealing ownership while expanded. Arbitrary SwiftUI identity churn
and physical mixed-DPI display transitions remain outside the native smoke coverage.
No reviewer approval is claimed for those unverified scenarios.

Native smoke artifacts and read-only reviewer reports are under ignored
`.local/reviews/bottom-expanded-hover-20260920/` and
`.local/vm-share/results/bottom-expanded-hover-20260920/`.

The native reproduction uses a 1024-by-768-point Retina VM display. Physical
MacBook Air and multiple-display hardware checks remain unverified; all three Dock
placements are covered by the automated regression. This hotfix does not establish
a new CPU benchmark or change the previously documented interaction CPU result.
