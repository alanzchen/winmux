# Resizable settings window

## Behavior

The settings window starts at 760 × 620 points and supports resizing in both
directions. The minimum usable area is 700 × 480 points; native titlebar/toolbar
space is accounted for separately. Presenting an existing window preserves its
size and position instead of resetting and centering it.

The navigation sidebar remains adjustable, with at least 460 points reserved for
the detail pane. Long panes scroll vertically. Focus and Move shortcut pads stack
in narrow windows and sit side by side when their content area reaches 872 points.
A SwiftUI `Layout` positions the same native recorder views across this breakpoint.

Settings rows fill the available width and long labels wrap. The config editor
places its path and action buttons on separate lines, truncates long paths in the
middle, and exposes the full path in a tooltip. Resizing retains the unsaved draft,
editor focus, and keeps Appearance scrolled instead of jumping to the top.

## Validation

Pinned Swift 6.2.4, ARM64 only. Six new `ShortcutSettingsLayoutTest` regressions cover:

- Removal of old fixed native limits, minimum usable height, and preserved frame.
- Five scrollable panes at 700 × 480, 760 × 620, and 1320 × 900 usable points.
- Directional pad positions and native recorder identity across reflow.
- Editor draft/focus retention and expansion of the text area.
- Appearance scroll retention during a width change.
- A 280-point navigation column followed by shrinking to the minimum window size.

The complete suite passes **799 tests**, with **three expected skips** and **zero
failures**, followed by the application build. Both app and CLI report `arm64`.

Claude CLI (`claude-fable-5`) and agy CLI (`gemini-3.8-flash-high`) performed
independent reviews and targeted follow-ups. Claude identified the toolbar-height
mismatch; the minimum-size calculation and full-size-content fixture now account
for it. agy's suggested Behavior-pane coverage was added. The directional layout
also declares its 424-point intrinsic minimum explicitly. Raw reports and logs
are retained under ignored `.local/reviews/settings-resize-20260917/`.
Both final reviews reported no confirmed blockers.

## Remaining native checks

WindowServer captures from the test runner were blank; AppKit bitmap renders were
incomplete. They are excluded as visual evidence, and the experimental capture
helper was removed. The tests verify real AppKit geometry and view state, but a
manual visual check of the scene-created window and restoration across a full app
restart remain outstanding. No installation or release is part of this change.
