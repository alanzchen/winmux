# Display filter defaults — September 27, 2026

Every Dock, Sidebar, and Tabs panel now lists only the workspaces on its own
display. Before, only the Dock did ([Dock monitor-filter defaults](dock-monitor-filter-validation.md));
Sidebar and Tabs started on **Default**, which meant every display.
`[workspace-sidebar] display-filter = 'all-displays'` (Settings → Position &
visibility → Show workspaces from) restores the all-displays list.

- The display menu lists **This Display**, **All Displays**, **Focused** (with
  `enable-focus`), then the other displays by their own names. The main display
  is no longer labelled "Main", and identical displays are numbered.
- A menu choice applies to its panel only. It lasts until WinMux quits, the chosen
  display disconnects, or `display-filter` changes. A temporarily empty display
  list (disabled sidebar, discovery) keeps the choice.
- When `monitor` leaves a connected display without a panel, panels list every
  display so that display's workspaces stay reachable.
- This Display is clickable in every mode. Before, Sidebar and Tabs rows were
  read-only with any display chosen, including the panel's own.
- Tabs hides its display menu when there's nothing to choose (one display, no
  Focused filter).
- Search keys always read the panel's current workspaces and filter. Before, the
  panel kept the key handler a search began with, so arrow keys and Enter used the
  workspaces and filter from that moment. Enter now opens only a listed result, and
  a filter or workspace change that hides the selection selects the first listed
  match.
- The tray menu's GitHub Repository item opens github.com/alanzchen/winmux.
  **File an issue…** opened the upstream tracker until issues were enabled on the
  fork (September 28); it now opens the fork's new-issue page.

## Checks

- Swift 6.4, ARM64, detached worktree based on `6dcd8ddd`.
- 18 display-default regressions cover own-display defaults in every mode, the
  All Displays setting, coverage fallback (including legacy `main` and an
  unmatched list), choice lifetime across setting changes, disconnects, mode and
  focus changes, activation policy, menu names and order, the Tabs menu
  condition, hidden search results, and native NSPanel sync. A hosted view test
  sends search keys through the relay after the filter changes, in Dock, Sidebar,
  and Tabs; without the fix it opened the hidden result in all six cases. It
  drives the relay directly, not a native editing session.
- Config parsing and the Settings round trip cover `display-filter`.
- Full host suite: 1595 tests, 7 skipped, 0 failures. ARM64 build passes.
- Not verified natively: the screen was locked, so no click-through, and no
  physical two-display connect/disconnect check.

## Review

Astra xhigh (`codex/gpt-6-astra`, via Paseo) and agy (`gemini-3.8-flash-high`)
reviewed the diff independently. Astra found that Enter could open a search result
hidden by a filter change. Its follow-up found the first fix incomplete, because
the panel's stored key handler read the snapshot from when the search began; the
key relay and the hosted key test address it. SwiftUI's `onChange` also runs with
the previous view, so the relay is refreshed from a copy holding the new
snapshot, and the handler is cleared when the view disappears to break the
relay-view reference cycle. Astra also caught inaccurate Settings help and a
broken link. agy found no blocking defects in any round and suggested the extra
naming, choice, and trigger checks. Both reviewers' final verdict was ship.
Reports are under ignored `.local/reviews/display-filter-20260927/`.

Astra noted a pre-existing inconsistency that this change leaves as is: with
another display chosen, Tabs favorites, compact tabs, and search results still
open workspaces, while ordinary rows don't.
