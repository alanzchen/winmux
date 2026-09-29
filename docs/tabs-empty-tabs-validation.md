# No empty tabs in Tabs mode — September 28, 2026

Tabs mode no longer keeps empty tabs.

- A tab whose last window goes closes, however the window went: closed, moved to another
  tab or display with the CLI or a drag, or closed on a display that isn't focused. Before,
  only closing the focused tab's last window moved on; every other way left an **Empty
  Tab** on screen. Its display shows the next tab in the sidebar's order, or the previous
  one, preferring tabs with windows over empty pins.
- Moving the last window of the tab on screen into another tab follows the window there.
- A new tab stays until something opens in it or you leave it, and the tab the launcher is
  open for is listed as a new tab. When a display has no other tab, it keeps showing the
  empty one, which the list leaves out, including a new tab closed with nothing in it.
- Pinned and saved tabs still stay when their last window closes. They now show their
  apps' icons, greyed, instead of an empty tile or an **Empty Tab** row. Clicking one
  selects it and opens its apps: an app that quit relaunches and its windows return to
  their saved places, that tab's first; a running app, or one whose saved windows have
  expired, is asked for a new window in the tab, as the launcher asks. The apps are saved
  with the tab (`launchApps` in `saved-workspaces.json`), so they survive a restart and
  Undo restores them. Shift- or Command-clicking only chooses the tab.
- Dock and Sidebar modes are unchanged.

## Checks

- Swift 6.4, ARM64, worktree based on `947c092f`.
- `WorkspaceTabsLeftEmptyTest` (23 tests) covers replacement order, tabs with windows
  first, the only tab on a display, pinned, saved and new tabs, following a moved window,
  another display, a configuration reload that reassigns displays, Undo, saved apps after
  slot expiry and across a restart, records saved before tabs kept their apps, a window
  closed before the first checkpoint, a background checkpoint during Undo, an unrelated
  Undo, two tabs of one app (both restored, or the clicked one without a waiting window),
  relaunching into the clicked tab, asking a running app, and activation. Each fix was reverted in turn and a test failed; with the replacement
  run before display repair, the configuration-reload test crashes on the invariant check.
- Full host suite: 1702 tests, 7 skipped, 0 failures. ARM64 build passes.
- Native, in the `winmux-tests` Tart VM (macOS 27, unsigned candidate of the first
  revision): moving a tab's windows out with `move-node-to-workspace` closed the tab and
  showed the previous one with no Empty Tab row; a pinned Calculator tab turned into a
  greyed Calculator tile when Calculator quit, and clicking it relaunched Calculator into
  the pin. Another session started using the same VM partway through, so later native
  checks (the reviewed fixes, a title-bar drag that empties the tab on screen, a running
  app asked for a window, the launcher) were not run; one early run lost its TextEdit
  windows to that session's activity.
- Not verified natively: multiple displays, projects, native Spaces, and apps without a
  new-window adapter while running (the menu fallback is off by default).

## Review

Astra xhigh (`codex/gpt-6-astra`, via Paseo) and agy (`gemini-3.8-flash-high`) reviewed
the change independently, with a follow-up after each round of fixes. Astra's first round
found that replacing an empty tab before display repair could crash on a configuration
reload, that a greyed tab did nothing when its app was still running, that relaunching
could fill another tab of the same app, that Shift- and Command-clicks launched apps, and
that Undo didn't restore the new state. agy found that the reconcile at the end of a
refresh skipped the cleanup, and cases where the launcher's tab or an abandoned new tab
showed as an Empty Tab. Later rounds found that a tab's apps were only remembered in memory
and until its saved windows expired, that background checkpoints cancelled Undo and Undo
reset untouched tabs, that closing before the first checkpoint lost the apps, that one app
of a two-app tab could vanish, that a launch from a tab without a waiting window could fill
another tab, and a routing bypass that was too broad. All were fixed with regression tests.
agy's claims of a focus and display mismatch after a close, and of a new tab being skipped
as a replacement, didn't hold up against the code. Astra's final verdict was ship; agy's was
ship once `ensureSavedWorkspaceRecord` returned the record it saved, which is fixed. Reports
are under ignored `.local/reviews/empty-tabs-20260928/`.

Known limitations: a running app without a new-window adapter can't be asked for a window
unless the launcher's menu fallback is on, so clicking its greyed tab only selects it (the
error is shown). Tabs whose windows are only minimized or hidden still show as Empty Tab
rows, as before.
