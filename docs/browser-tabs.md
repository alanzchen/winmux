# Browser tabs in Tabs mode

The expanded Tabs sidebar can list the tabs inside a Safari or compatible Chrome,
Chromium, Brave, or Edge window. A window with two or more readable tabs becomes a
browser group. Selecting a child switches the browser tab and focuses its owning
window. A real split keeps its side-by-side window row, with browser children below.
Search matches browser tab titles; arrow keys and Enter select the matching child.

![A browser window with individual tab rows](images/browser-tabs-single.png)

![Browser tabs beneath a physical split](images/browser-tabs-split.png)

The browser remains one managed window. Browser children do not create workspaces
or change tiling, projects, pins, or saved layouts. The active group stays expanded.
Pinned tiles and the compact rail continue representing whole windows; browser
children appear in the expanded list and search.

`workspace-sidebar.browser-tabs` defaults to `true`. Turn off **Show browser tabs**
in Settings to restore ordinary window rows. This uses the Accessibility permission
WinMux already needs; it does not request Automation or require an extension.

## Website icons

**Website icons for Chrome-family tabs** (`workspace-sidebar.browser-tab-icons`) is off by
default. When enabled, icons appear as tabs are selected in listed windows. Unvisited tabs, unsupported
addresses, and failed downloads use the browser's app icon. Safari uses its app icon.

WinMux reads the window's document address and keeps only its HTTPS
origin, after two consistent observations. It requests `/favicon.ico`, then
`/apple-touch-icon.png`, directly from that origin. It never requests the page URL
or uses a third-party icon service. Downloads use no cookies or saved credentials,
stay on the same origin, and have time, byte, concurrency, and image-size limits.
Tab metadata and icons remain in memory and are cleared when the feature is disabled.

These requests include Incognito windows and do not use browser proxy settings,
VPN extensions, or secure DNS. Obvious local addresses are excluded; a domain that
resolves to a local device could still trigger macOS's Local Network prompt. Safari
website icons are excluded because a direct request could bypass iCloud Private Relay.
Background navigation can leave the previous site's icon until the tab is visited.
Selecting an ineligible address replaces a known website icon with the app icon
after the address is confirmed.

## Current boundaries

- The sidebar selects browser tabs. Close, drag, reorder, detach, and browser-native
  tab-group editing remain in the browser. Header actions still apply to the window.
- WinMux's next/previous and numbered workspace commands continue navigating real
  windows and splits. Search can navigate browser children.
- Arc, Dia, Opera, Vivaldi, Safari Technology Preview, and custom tab-strip layouts
  are not enabled. A hidden or unrecognized tab strip, including some native browser
  groups and multi-selected tabs, falls back to the ordinary window row.
- Transient Accessibility failures retain the last complete snapshot. Repeated
  failures fall back after ten seconds and retries back off to thirty seconds.
  Hidden sidebars do no browser reads and keep their last snapshot to preserve the
  reveal animation; revealing the sidebar refreshes it. No action guesses by title
  or tab position.

## Validation

Regression tests cover browser-control discovery, Safari's separate tab strip,
duplicate titles, stable identity during reorder, stale/moved controls, incomplete
reads, cancellation, cache lifetime, search/scroll order, origin association, image
bounds, retry backoff, hidden-panel scheduling, redirect rules, configuration, and
native SwiftUI renderings with text recognition. The auto-hide rendering check
repeatedly reveals pinned tiles with animation and no selection changes. It also
passes with the previous lazy grid, so it does not reproduce the reported live
hover-reveal failure; that check still needs the unlocked desktop.

Native Safari 27 and Chrome 154 probes verified enumeration and tab selection with
disposable pages. Production scanner discovery for two-tab windows took 9–14 ms
on the development Mac. A bounded icon request and 32-pixel thumbnail decode passed.
Brave, Edge, Chromium, native vertical tabs, multiple browser profiles, 100+ live
tabs, and multi-display browser selection have not been exercised on hardware.

The full arm64 suite completed 1,548 tests with 7 existing skips and no failures;
`swift build --arch arm64` also passed. The Mac locked during additional live checks,
so notification delivery, typing an uncommitted address, and the full sidebar-to-
browser selection flow remain pending desktop validation.
