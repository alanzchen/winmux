# Sidebar appearance validation

The optional compact app-icon mode and sidebar glass opacity control preserve the
existing appearance by default (`show-app-icons = false`, `glass-opacity = 1.0`).
Both controls are in **Settings → Appearance → Sidebar**; configuration examples
are in the [README](../README.md#workspace-app-icons-and-glass-opacity).

## Automated checks

Validated on September 16, 2026 with Swift **6.2.4**:

- **187 focused sidebar/configuration tests passed.**
- **698 tests passed** in the complete application suite.
- Debug application/CLI build and `git diff --check` passed.
- Previous build `a75368c9` passed CI and distribution checks; its DMG predates
  the Dockset refinements below. See the [release validation record](releasing.md#dock-style-sidebar-build--september-16-2026).

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
tiles and app icons, with horizontal separators between workspaces. It uses a fixed
64-point compact width, including auto-hide; the stored collapsed width is restored
when app icons are disabled. Number tiles fade into workspace titles and app icons move to
their expanded row positions while measured heights interpolate. Separators fade
without changing row spacing. Regression coverage includes
widths 28/44/120, empty and crowded workspaces, duplicate apps, filtered tab groups,
summary-only apps, and both sides of the former row-reveal threshold. The 28/44/120
rendering cases stress component bounds; production Dock mode resolves to 64 points.

Six geometry regressions cover the centered compact surface, full-height expansion,
tall scrolling content, clock/display/project reserves, clipping invisible drag targets,
and keeping the original target under the pointer when a drag preview appears.
Each native panel caches its own local targets and reprojects them after moving or
showing, including same-size display rearrangements.

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

These detached checks open no windows and change no user configuration.

## Dockset reference comparison

Used the live [Dockset website](https://dockset.app/) in **Custom Dock → Left →
Dark/Glass** as the reference. Its measured rail was approximately 62.8 pixels wide,
with 15.4-pixel corners, a 19.6 × 1-pixel divider, and 2.8-pixel running dots.
WinMux uses 64-point width, 16-point corners, 20 × 1-point dividers, and 2.5-point dots.
The native compact glass uses a neutral dark tint and a subtle upper-edge highlight.
Its height fits the workspaces and controls, centered within the available area.

![Native before and after](images/sidebar-dockset-before-after.png)

These are **real WindowServer captures of the production sidebar view in a dedicated
native preview window**, with sample workspaces. The before view uses `a75368c9` in
an isolated checkout; both use the identical wallpaper crop and 64 × 508-point canvas.
Only the preview window is captured. The reference is a browser screenshot of Dockset;
it is not a screenshot of the installed macOS Dock. Different contents and rendering
engines make a pixel-identical reference comparison inappropriate. Native rendering
was inspected after two refinement iterations; a before/after pixel-difference image
is retained locally in `.build/dock-visual-match/`.

![Native transition positions](images/sidebar-dockset-transition.png)

Live native captures at 0%, 50%, and 100% expansion verify the surface and icon positions.
Reproduce with the existing development renderer; `--expansion` accepts 0–1:

```sh
swift run winmux-marketing-renderer --sidebar-dock-proof \
  --width 64 --height 508 --expansion 0.5 --hold-seconds 0 \
  --output /tmp/winmux-sidebar.png
```

The harness never starts window management or reads the user's configuration.
Interactive hover/reverse timing, mouse/VoiceOver operation of settings, and real
multi-monitor movement still need manual checks in the running app. Existing search,
rename, drag, Override, sidebar layering, and settings scroll-retention behavior remains
covered by regressions; these screenshots do not establish live input behavior.
