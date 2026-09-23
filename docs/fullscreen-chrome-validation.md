# Fullscreen Sidebar and Dock validation

## Behavior

Both modes hide on a display showing a native macOS fullscreen window and restore
their configured compact, auto-hidden, or pinned width when it leaves fullscreen.
Other displays stay available. A fullscreen window on an inactive macOS Space
does not hide the current desktop's panel. Ordinary maximized windows and WinMux's
in-desktop `fullscreen` layout retain their previous behavior.

The detector combines event-invalidated AX fullscreen state with on-screen
WindowServer IDs and bounds. It does not capture pixels, read window titles,
request Screen Recording, or poll on pointer/magnification ticks. Fullscreen-only
reads populate a generation-checked cache; cancelled or invalidated observations
preserve the previous visibility decision until the next refresh.

Presentation windows that never enter native fullscreen hide chrome the same way.
PowerPoint's slide show is a buttonless `AXUnknown` window with `AXFullScreen = 0`
that covers the whole display, so WinMux classifies it as a popup. A popup counts
when its on-screen WindowServer frame covers a display and its window level is
normal or above but below the Sidebar. Desktop-level wallpapers and overlays drawn
above the chrome, such as screenshot selection, keep it visible. The popup's
event-invalidated AX frame gates the WindowServer query, so tooltips, menus, and
ordinary popups never trigger one.

Hiding releases search/rename input, cancels queued expansion, and clears command
buffering. Commands cannot reopen a suppressed panel. Disconnected command targets
fall back to a currently configured display. Tab chrome uses the same per-display
visibility decision.

## Automated checks — September 18, 2026

Pinned Swift 6.2.4, Apple Silicon:

- 11 focused `WorkspaceSidebarFullscreenTest` regressions passed.
- Complete suite: **810 tests, three expected skips, zero failures**.
- Application and CLI build passed; both executables are `arm64`.
- `git diff --check` passed.

Coverage includes two-display focus/transient changes, negative display origins,
inactive fullscreen Spaces, fullscreen exit, cache invalidation and reuse,
cancellation, command ordering, display disconnect fallback, and preserving a drop
preview on another display. Native panel tests cover both modes with all four
auto-hide/pinned combinations, input cleanup, blocked reopening, and restoration.

## Native Tart check

A disposable AppKit fixture in the macOS 26.6.2 VM compiled the production
fullscreen detector with Swift 6.2.4 and exercised actual fullscreen transitions
and the production WindowServer metadata parser. Its window-state adapter supplied
AppKit's fullscreen flag in place of cross-process AX. Observed results:

| Phase | Detector suppresses | Guarded panel on screen |
| --- | --- | --- |
| Desktop | No | Yes |
| Native fullscreen | Yes | No |
| Desktop restored | No | Yes |

The unguarded control panel could still be ordered over fullscreen content.
Consequently, `.fullScreenNone` is not treated as a guarantee; the explicit
visibility gate prevents later refresh/search calls from revealing the panel.
Raw reports and fixture source are under ignored `.local/reviews/fullscreen-20260918/`
and `.local/vm-share/`.

## Review and remaining checks

Independent Claude (`claude-fable-5`) and agy (`gemini-3.8-flash-high`) reviews,
including follow-ups, reported no remaining confirmed blockers. Supported findings
led to cache write-back, invalidation handling, command fallback/ordering, and
multi-display cleanup fixes.

Physical two/three-display fullscreen transitions, Split View, and real-app
cross-process AX transitions remain manual checks. A concurrent AX invalidation
can defer restoration until a coherent follow-up refresh. No app was installed,
release published, or GitHub workflow run for this change.

## Presentation windows — September 23, 2026

PowerPoint's slide show kept the Sidebar and Dock over the slides because it never
reports AX fullscreen. The native AX capture in
[AeroSpace #697](https://github.com/nikitabobko/AeroSpace/issues/697) shows a
buttonless `AXUnknown` window with `AXFullScreen = 0`, sized to the whole display,
classified as a popup. Presenter view adds a second such window on the other display.

Candidates are popups of regular (Dock) apps whose event-invalidated AX frame covers a
display. The WindowServer frame and level then decide, as described above. When a
popup's frame cannot be read, it keeps its previous decision. Only the focused app is
asked to re-read a moved popup, as with the existing AX fullscreen reads. A busy
presenting app therefore cannot reveal chrome over its slides, and busy background
apps cannot stall refreshes.

Pinned Swift 6.2.4, Apple Silicon:

- 17 focused `WorkspaceSidebarFullscreenTest` regressions passed, including single
  and presenter-view slide shows across focus changes, level and visibility filters,
  resampling after a resize, unreadable frames, and background apps.
- Two consecutive complete runs of the final change: **1066 tests, seven expected
  skips**, and one or two native animation or pointer timing flakes per run. These
  were `WorkspaceSidebarAutoHideTest` hide timing, whose repeated-hide case also fails
  on unmodified `main`, and the Native Dock scroll-recovery test.
- Application and CLI build passed; both executables are `arm64`.

Shared test setup now clears the default `on-focused-monitor-changed` callback and
leftover popups. On unmodified `main`, each complete run started five detached
callback sessions, and four finished inside a later test. Such a session could
focus-sync a window that the next setup had removed.

No native slide-show check was possible. The session was locked, and PowerPoint
16.113.2 did not start a `.ppsx` show while locked. Its real window level, Keynote,
other presentation apps, and the menu-bar-utility filter against real apps remain
manual checks; unit tests cover only the activation-policy rule. A hung focused app
with an unreadable moved popup is re-read on every session, like invalidated
fullscreen reads.

Independent Claude (`claude-opus-5`) and agy (`gemini-3.8-flash-high`) reviews and two
rounds of targeted follow-ups found no remaining blockers. Accepted findings added the
unknown-frame fallback, the focused-app read gate, the regular-app filter, the
stay-on-top level bound, and stronger tests. They also led to removing a negative cache
that could stop detection after one AX timeout. Raw reports are under ignored
`.local/reviews/powerpoint-fullscreen-20260923/`.
