# Bottom Dock stationary-pointer expansion validation

Date: 2026-09-21. Baseline: published 0.6.335 (`3afad15c`).

## Reproduction and cause

In a macOS 26.6.2 Apple Silicon VM, clicking the bottom Dock's expansion arrow
and leaving the cursor on it made the panel repeatedly expand and collapse.
The debug trace recorded about 50 cycles while the pointer was stationary.
Moving into the expanded view stopped the cycle.

The compact Dock extended approximately from x=218 to x=806. The expanded view
extended from x=372 to x=652, leaving the arrow's original position at x=667
outside the expanded hover region. Collapse brought the compact Dock back under
the cursor before the expanded state was finalized, immediately reopening it.

Expansion now remembers the opening Dock's hover region. Hover retention uses
the union of that region and the current expanded surface, so the opening point
remains valid when the layout changes. Leaving both regions still collapses the
panel. The remembered region does not participate in click or drop hit testing.
It survives reversal of a collapse, including an auto-hide slide, and is discarded
after collapse or hide completion, explicit close, system suppression, reset, or
a change to Dock placement, size, gap or auto-hide configuration. This adds a
rectangle check, without timers or polling.

## Automated validation

- Two initial behavior regressions failed before the fix with 41 assertions.
- A follow-up auto-hide re-entry regression failed twice before its fix; it now
  covers reversal during a slide, hide completion and subsequent reveal.
- A pure geometry regression rejects old hover regions after Dock layout changes.
- They cover the stationary opening point, the expanded view, points outside
  both regions, click-through outside visible content, explicit close, reopening,
  moving the panel, and system suppression. Auto-hide is covered both on and off.
- 75 focused Dock, pointer, motion, auto-hide, gap and placement tests passed.
- Full arm64 Swift 6.2.4 suite: 1,012 tests, seven opt-in tests skipped, zero failures.

The original real-mouse reproduction stays expanded after this fix, with no
collapse in the debug trace until the pointer leaves both regions. With auto-hide
both off and on, two repeated real-click cycles per mode passed all 100 stationary
samples, movement along the opening Dock, movement into the expanded view, quick
pointer excursions and normal outside collapse. One auto-hide excursion reached
an active hide in the debug trace and reversed successfully on pointer return.

Further native checks used two projects and six application windows. Hovering all
visible project filters and workspace/window rows kept the expanded panel open.
Real clicks opened search and the Other Projects menu; a Calendar row click
activated Calendar. Escape, reopening and subsequent outside collapse also passed
with auto-hide off and on.

Both the native renderer and the SwiftUI fallback passed two more auto-hide
cycles, including reveal at the former arrow's horizontal position after a full
hide. The fallback check covers this observed sequence, not every possible
SwiftUI preference-delivery ordering.

## Independent review

Claude Opus 5 and agy (`gemini-3.8-flash-high`) reviewed the source and the follow-up
fixes independently. Accepted findings added retention during a reversed auto-hide
slide, invalidation after configuration changes, and stronger lifecycle assertions.
The tests isolate geometry from the host desktop pointer; the real pointer event
and animation lifecycle is checked separately in the VM. Reduce Motion takes the
immediate-hide assertion path instead of skipping the lifecycle test.

Other hypotheses were checked against their actual callers. The hover cue cannot
exceed compact width. The native renderer publishes geometry synchronously before
returning the rendered snapshot, and expanded magnification blockers clear compact
icon hit regions. Same-target slide calls carry their own cleanup completions. The
opening rectangle intentionally remains a snapshot until that opening session ends;
re-capturing during a reversed collapse could instead retain outgoing expanded bounds.
Neither reviewer approval nor complete coverage of arbitrary rendering interleavings
is claimed.

Native artifacts and read-only review reports are kept under ignored
`.local/vm-share/results/dock-expansion-flicker-20260921/` and
`.local/reviews/dock-expansion-flicker-20260921/`.

The reproduction uses a 1024-by-768-point Retina VM display. Physical MacBook Air
and multiple-display hardware checks remain unverified. This hotfix does not
establish a new CPU benchmark or change the previously documented interaction
CPU result.
