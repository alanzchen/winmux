# Sidebar tab transitions

## Reproduced failures

The immediate sidebar focus update rebuilt workspace models without copying
their appearance. Clicking a favorite temporarily cleared its favorite flag,
color, and emoji, moving it out of the favorites grid until the full refresh.

Workspace layout queued incoming frame writes before outgoing parking moves,
but different applications execute those requests on separate accessibility
threads. The outgoing app could finish first, exposing the desktop while the
incoming window was still parked. A controlled delayed-app regression reproduced
this ordering. The two original regressions failed six assertions before fixes.

## Changes

The immediate focus update copies the whole workspace model and changes only
focus and visibility. Workspace appearance and item identity remain intact.
When a layout will park an outgoing window, it waits for queued frame writes in
visible apps on the affected displays. Apps are awaited concurrently, once per
app even for split windows. Unaffected displays and ordinary refreshes with no
outgoing window skip this barrier. If an outgoing app cannot be parked, later
refreshes still skip queue waits for incoming frames already acknowledged.

Overlapping layouts use a generation and a snapshot of display geometry and
active workspaces. An obsolete layout stops before parking windows, including
after asynchronous accessibility reads. Logical parking state is committed only
after those checks. A superseded click also cannot restore native focus to its
old selection.

## Validation

Swift 6.4, arm64 only:

- Focused sidebar, window tab, floating-window, and refresh coverage: 676 tests,
  seven skips, zero failures.
- Review follow-up: 34 focused tests, zero skips or failures.
- Final full suite: 1,456 tests, seven skips, zero failures.
- `swift build --arch arm64`: passed for the app and CLI.
- New regressions cover favorite identity, delayed incoming apps, same-app and
  cross-app splits, overlapping refreshes after logical unhide, cancellation,
  rapid successive selections (including A → B → A), unaffected secondary
  displays, unparkable outgoing windows, and avoiding barriers on ordinary
  refreshes. Completion tracking tests cover writes submitted after an older
  marker and cancellation without acknowledging unfinished frames.

Native AppKit tests ran in the available macOS session. No WinMux process was
running for a live third-party accessibility smoke check. The controlled app
queues exercise the real workspace layout and light-session code, but do not
verify compositor timing, third-party accessibility failures, or physical
multi-monitor behavior.

Manual follow-up: click favorites repeatedly and confirm their tiles, colors,
and emojis stay fixed; switch between windows from different apps and split
tabs; repeat rapidly and with a slow incoming app. The old window should remain
onscreen until the incoming windows are placed, with focus ending on the last
selection. Repeat on each physical display.

Independent read-only review reports and the scoped source bundle are kept
under ignored `.local/reviews/tab-transitions-*`.

Accepted Claude Opus 5 and Gemini 3.8 Flash High findings led to limiting waits
to affected displays, skipping already-completed frame writes, copying sidebar
models, and the additional rapid-return and queue-completion tests. Search and
snapshot construction were checked for appearance preservation. Monitor changes
already schedule immediate and settled refreshes through
`MonitorConfigurationObserver`.

Final targeted reviews reported no blocking findings. Claude withdrew a
submission-order concern after checking the AppBundle target's
`NonisolatedNonsendingByDefault` setting and the main-actor blocking-frame caller.
Frame submission continues to rely on the existing main-actor call sites.

The pre-existing legacy stack switching path in other modes is outside this
change. Browser Tabs mode migrates all such stacks into sidebar workspaces
before layout; the new cross-workspace handoff covers those sidebar tabs and
their split windows. The existing serial outgoing parking and repeated AX frame
reads were left unchanged.
