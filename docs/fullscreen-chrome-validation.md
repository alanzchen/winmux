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
