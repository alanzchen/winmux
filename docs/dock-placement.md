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

WinMux hides only when the macOS Dock is visible on the **same edge of the same
display**, and returns after it disappears. For example, a bottom macOS Dock
leaves a left or right WinMux Dock visible. Other displays remain available.
Sidebar mode is unaffected. Tiled-window reservations stay stable during this
temporary hiding, so revealing the native Dock does not resize your windows.
If the native Dock is configured to remain visible on the same edge,
the WinMux Dock stays hidden on that display.

Bottom mode temporarily enables native Dock auto-hide. WinMux records the prior
setting before changing it and restores it on placement/mode change, disable,
normal quit, or handled termination. A recovery record survives a crash and is
restored or adopted on the next launch. An explicit user change while Bottom mode
is running ends WinMux's ownership of the preference.

Visibility reads use the Dock's Accessibility list frame. With auto-hide enabled,
macOS can report a zero-thickness reserved rectangle even while the Dock is visible.
WinMux extends that reservation inward using the AX list size and native orientation,
then clips the animated list frame to it. The reservation anchors the owning display
through reveal and hide animations. Hidden AX elements remain beyond the screen edge; they must
not hide WinMux on an adjacent display. Reads run on a utility task, at most one
at a time. Pointer movement near the native Dock edge speeds up checks on every display;
idle checks drop to once per second even if the pointer stays at an edge. Only changes to the set of affected displays refresh
the panels. No screen-recording permission or screen capture is needed.

The integration dynamically resolves optional `CoreDockGetRect`, `CoreDockGetOrientationAndPinning`,
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
manual changes, recovery, and unavailable APIs. Visibility tests cover every pair
of WinMux/native Dock positions across three display origins, reveal/hide animation
frames, and screen-spanning Docks with system margins.
The captured `test-fixtures/accessibility/native-dock-autohide.json` regression
covers a visible Dock whose reserved rectangle has zero height. Synthetic tests
cover thin reservations on all three edges, hidden lists crossing adjacent display
boundaries, invalid geometry, and short Docks' pointer polling.

Native smoke checks should cover revealing the macOS Dock, switching placement
while search/drag is active, quitting Bottom mode, and moving the native Dock
between displays. Physical multi-display and high-refresh verification require
that hardware; offscreen AppKit rendering does not establish display frame pacing.

### Auto-hide reveal check (2026-09-20)

- Swift 6.2.4: **959 tests, 7 opt-in skips, 0 failures**; ARM64 debug build passed.
- On macOS 26.6.2, native read-only captures reproduced the empty-reservation gate:
  `CoreDockGetRect` returned zero height while the Dock's AX list was on screen.
  Main and utility threads agreed. A harness compiled from the production detector
  correctly suppressed Bottom only across 15 repeated samples of that live state.
- The host's auto-hide preference was temporarily enabled and restored through
  System Settings. No screen-recording access is used by the detector.
- Claude Fable 5 and agy Gemini 3.8 Flash High independently reviewed the fix.
  Follow-up changes removed unnecessary geometry/allocation work and added a
  regression for native orientation taking precedence at an ambiguous corner.
- Full-app interactive reveal/hide and physical multi-display checks remain pending.
  The Mac relocked before a side-Dock capture. This check does not install or publish a release.

### Previous local check (2026-09-19)

- Swift 6.2.4: **954 tests, 7 opt-in skips, 0 failures**; ARM64 debug app and CLI build passed.
- AppKit render checks cover bottom/right magnified pixels and hit geometry, every
  icon with crowded footer controls, upright expansion, and single-owner drag targets.
- Claude Fable 5 and agy Gemini 3.8 Flash High independently reviewed the code;
  accepted findings added stale-read/delayed-setter recovery (including restore after disable), idle polling limits,
  accurate initial hit regions, minute-boundary clock updates, monotonic visibility timers,
  and cross-edge handling.
- Interactive native Dock reveal, live auto-hide setter/restore, physical multi-display,
  and display frame-pacing checks remain pending; the Mac was locked during this pass.
  Automated rendering and injected preference tests do not establish those results.
