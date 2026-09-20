# Dock placement and macOS Dock

Choose **Settings → Dock & Sidebar → Position & visibility → Position**:

- **Left**: vertical shelf; icons magnify toward the right.
- **Bottom**: horizontal shelf; icons magnify upward. Search, rename, and workspace
  details expand into an upright panel centered at the bottom.
- **Right**: vertical shelf; icons magnify toward the left.

The active workspace dot sits on the side nearest the display edge. Separators
move with their workspace groups and retain their thickness. App selection,
badges, replacement icons, project emojis, monitor filters, and drag/drop use the
same actions as the left Dock. Adaptive icon sizing uses the available length;
very crowded shelves scroll when they reach the 16-point minimum.

The configurable **Edge gap** closes during expansion. The TOML key retains its
original name for compatibility:

```toml
[workspace-sidebar]
mode = 'dock'
dock-position = 'bottom' # 'left' (default), 'bottom', or 'right'
dock-left-gap = 2
```

Sidebar mode keeps its original left-edge layout regardless of the saved Dock
position. A visible compact shelf reserves space for tiled windows at its selected
edge. Auto-hidden shelves reserve no space. A pinned expanded Bottom panel reserves
up to 60% of the available display height, with a 600-point maximum; unpinned search
panels temporarily overlay windows.

## Sharing the display with the native Dock

In **all three Dock placements**, WinMux hides on the display where the macOS
Dock is visible and returns after it disappears. Other displays remain available.
Sidebar mode is unaffected. Tiled-window reservations stay stable during this
temporary hiding, so revealing the native Dock does not resize your windows.
If the native Dock is configured to remain visible,
the WinMux Dock stays hidden on that display.

Bottom mode temporarily enables native Dock auto-hide. WinMux records the prior
setting before changing it and restores it on placement/mode change, disable,
normal quit, or handled termination. A recovery record survives a crash and is
restored or adopted on the next launch. An explicit user change while Bottom mode
is running ends WinMux's ownership of the preference.

Visibility reads use the Dock's Accessibility list frame, clipped to its reserved
rectangle. Hidden AX elements remain present beyond the screen edge; they must
not hide WinMux on an adjacent display. Reads run on a utility task, at most one
at a time. Pointer movement near the native Dock edge speeds up checks on every display;
idle checks drop to once per second even if the pointer stays at an edge. Only changes to the set of affected displays refresh
the panels. No screen-recording permission or screen capture is needed.

The integration dynamically resolves optional `CoreDockGetRect`,
`CoreDockGetAutoHideEnabled`, and `CoreDockSetAutoHideEnabled` symbols from
HIServices. These are private macOS APIs, so missing symbols/read failures disable
the affected integration rather than preventing launch. API declarations are
cross-checked with the local SDK and the [published CoreDock header](https://gist.github.com/w0lfschild/90db263867f469738c01e9e2d937f874).

## Validation

Run the pinned Swift 6.2.4 toolchain on Apple Silicon:

```sh
swift test --arch arm64 --filter 'WorkspaceSidebarDockPositionTest|SystemDockTest'
swift test --arch arm64
swift build --arch arm64
```

Focused tests exercise configuration compatibility, off-origin display geometry,
edge-gap hover reveal, horizontal native pointer tracking, inward magnification,
rendered pixel clipping, upright expansion, and clipped workspace drop targets.
Preference tests cover one-time acquisition/restoration, pre-existing auto-hide,
manual changes, recovery, and unavailable APIs.

Native smoke checks should cover revealing the macOS Dock, switching placement
while search/drag is active, quitting Bottom mode, and moving the native Dock
between displays. Physical multi-display and high-refresh verification require
that hardware; offscreen AppKit rendering does not establish display frame pacing.

### Latest local check (2026-09-19)

- Swift 6.2.4: **927 tests, 7 opt-in skips, 0 failures**; ARM64 debug app and CLI build passed.
- AppKit render checks cover bottom/right magnified pixels and hit geometry, every
  icon with crowded footer controls, upright expansion, and single-owner drag targets.
- Claude Fable 5 and agy Gemini 3.8 Flash High independently reviewed the code;
  accepted findings added stale-read/delayed-setter recovery (including restore after disable), idle polling limits,
  accurate initial hit regions, minute-boundary clock updates, monotonic visibility timers,
  and cross-edge handling.
- Interactive native Dock reveal, live auto-hide setter/restore, physical multi-display,
  and display frame-pacing checks remain pending; the Mac was locked during this pass.
  Automated rendering and injected preference tests do not establish those results.
