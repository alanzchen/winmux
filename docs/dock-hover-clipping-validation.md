# Dock hover clipping validation — September 18, 2026

## Cause and change

Adaptive sizing fitted the resting icons and controls to the available height.
Magnification then increased the workspace column height while the outer panel
remained capped by the screen. The scroll viewport correctly clipped overflow,
which could slice the final app icon horizontally above the bottom controls.

Sizing now also reserves an upper bound on magnification growth. The bound comes
from the same sine displacement used to position the icons, including workspace
separators. A half-point size search runs when the snapshot or viewport changes;
hover does not refit icons. The configured icon size remains a ceiling. Extremely
crowded columns retain the existing 16-point minimum and scrolling behavior.

## Validation

- The new native SwiftUI regression failed before the fix with six clipped-icon
  assertions. It now checks every icon at multiple lens positions and magnification
  amounts (0.25, 0.5, 1), including icon edges, gaps, and icons next to the
  bottom controls.
- Additional geometry coverage checks that the reserve bounds actual column growth
  across different icon sizes, workspace counts, empty workspaces, and separators.
- Full suite on the host and Tart macOS VM: **815 tests, three expected skips, zero
  failures** on each. ARM64 app/CLI build passed.
- A rendered host fixture shows the complete last icon above the controls. Generate
  the fixture with `WINMUX_DOCK_CAPTURE_DIRECTORY=/absolute/output/path` while
  running `WorkspaceSidebarDockAdaptiveSizingTest/testMagnificationKeepsEveryFittedIconAboveBottomControls`.

- Claude (`claude-fable-5`) and agy (`gemini-3.8-flash-high`) completed initial
  and targeted follow-up reviews with no remaining supported blockers. Their
  proposed removal of a 32-point reserve was rejected after verifying it is the
  actual expand button (28 points plus 4 points of padding). Boundary-hover test
  coverage was expanded following review.

Raw logs and review reports are under ignored
`.local/reviews/dock-hover-clipping-20260918/`. The fixture uses synthetic app icons;
it is not a screenshot of the user's installed app. No installation or release is
part of this change.
