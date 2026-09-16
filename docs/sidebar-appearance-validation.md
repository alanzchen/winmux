# Sidebar appearance validation

The optional compact app-icon mode and sidebar glass opacity control preserve the
existing appearance by default (`show-app-icons = false`, `glass-opacity = 1.0`).
Both controls are in **Settings → Appearance → Sidebar**; configuration examples
are in the [README](../README.md#workspace-app-icons-and-glass-opacity).

## Automated checks

Validated on September 16, 2026 with Swift **6.2.4**:

- **168 focused sidebar/configuration tests passed.**
- **679 tests passed** in the complete application suite.
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

## Native rendering

Detached `NSHostingView` tests rendered the actual compact header at 28-, 44-, and
120-point rail widths with 0, 1, 3, 6, and 104 apps. Pixel bounds checks passed.
The full workspace-card preview was visually inspected:
`.build/sidebar-appearance-ui/workspace-app-icons-preview.png`.

The actual sidebar surface was rendered at 0%, 40%, and 100% opacity. Its background
alpha changed while the foreground pixels stayed unchanged. Solid surfaces remained
opaque at all three values. Workspace card glass uses the same configured opacity.

These checks open no windows and change no user configuration. Live backdrop blur
and mouse/VoiceOver operation of the settings controls have not been manually
smoke tested in a running application. Existing search, rename, drag, Override,
sidebar layering, and settings scroll-retention code paths remain in place.
