# Sidebar appearance validation

The optional compact app-icon mode and sidebar glass opacity control preserve the
existing appearance by default (`show-app-icons = false`, `glass-opacity = 1.0`).
Both controls are in **Settings → Appearance → Sidebar**; configuration examples
are in the [README](../README.md#workspace-app-icons-and-glass-opacity).

## Automated checks

Validated on September 16, 2026 with Swift **6.2.4**:

- **181 focused sidebar/configuration tests passed.**
- **692 tests passed** in the complete application suite.
- Debug application/CLI build and `git diff --check` passed.

```sh
swift test --filter 'WorkspaceSidebar|ConfigTest'
swift test
swift build
```

Coverage includes strict opacity parsing (including nonfinite values), backwards
defaults, settings persistence, nested tiled/tabbed and floating app summaries,
deduplication, search preservation, numeric labels, overflow, and accessibility
labels. Review also checked that optimistic workspace selection keeps app summaries
and that the new layout does not resize shared monitor/project controls.

The app-icon rail uses a vertical Dock-style column: equal-sized workspace number
tiles and app icons, with horizontal separators between workspaces. Wider rails
retain the column. It keeps its configured collapsed width through expansion,
including auto-hide. Number tiles fade into workspace titles and app icons move to
their expanded row positions while measured heights interpolate. Separators fade
without changing row spacing. Regression coverage includes
widths 28/44/120, empty and crowded workspaces, duplicate apps, filtered tab groups,
summary-only apps, and both sides of the former row-reveal threshold.

## Native rendering

Detached `NSHostingView` tests rendered actual workspace sections at 28-, 44-, and
120-point rail widths with 0, 1, 3, 6, and 104 apps. Pixel bounds checks passed.
The Dock preview includes real app icons, active and inactive workspaces, separators,
and an empty workspace. It was visually inspected:
`.build/sidebar-appearance-ui/workspace-app-icons-preview.png`.

Actual workspace cards were also rendered at six intermediate expansion positions.
Anchor checks verified equal square number/app tiles, a fixed compact column, and mounted destinations;
height checks verified continuous expansion for empty, single-window, and grouped
workspaces. A pixel regression verifies numeric labels remain readable at all five
preview positions. Numeric and long workspace labels were visually inspected in the morph
preview: `.build/sidebar-morph-ui/workspace-app-icons-morph-preview.png`.

The actual sidebar surface was rendered at 0%, 40%, and 100% opacity. Its background
alpha changed while the foreground pixels stayed unchanged. Solid surfaces remained
opaque at all three values. Workspace card glass uses the same configured opacity.

These checks open no windows and change no user configuration. Live backdrop blur
and mouse/VoiceOver operation of the settings controls have not been manually
smoke tested in a running application. Live hover/reverse animation timing and
multi-monitor movement remain manual checks. Existing search, rename, drag, Override,
sidebar layering, and settings scroll-retention code paths remain in place.
