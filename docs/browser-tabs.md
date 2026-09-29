# Browser tabs in Tabs mode

The expanded Tabs sidebar can list the tabs inside a Safari or compatible Chrome,
Chromium, Brave, or Edge window. A window with two or more readable tabs becomes a
browser group, drawn like the sidebar's other groups: the window's row heads it, and
its tabs are listed beneath. Selecting a child switches the browser tab and focuses
its owning window. Middle-click a child, hover it and click **×**, or choose **Close
Tab** from its menu to close that browser tab. A real split keeps its side-by-side
window row, with browser children below. Search matches browser tab titles; arrow
keys and Enter select the matching child.

![A browser window with individual tab rows](images/browser-tabs-single.png)

![Browser tabs beneath a physical split](images/browser-tabs-split.png)

The browser remains one managed window. Browser children do not create workspaces
or change tiling, projects, pins, or saved layouts. The active group stays expanded.
Pinned tiles and the compact rail continue representing whole windows; browser
children appear in the expanded list and search.

`workspace-sidebar.browser-tabs` defaults to `true`. Turn off **Show browser tabs**
in Settings to restore ordinary window rows. This uses the Accessibility permission
WinMux already needs; it does not request Automation or require an extension. The
optional [WinMux Tabs Safari extension](#safari-extension) adds website icons and
sound to Safari's tabs.

## Website icons

**Website icons for Chrome-family tabs** (`workspace-sidebar.browser-tab-icons`) is off by
default. When enabled, icons appear as tabs are selected in listed windows. Unvisited tabs, unsupported
addresses, and failed downloads use the browser's app icon. Safari tabs get their icons from
the [WinMux Tabs extension](#safari-extension) instead; this setting doesn't affect them.

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

## Safari extension

WinMux includes **WinMux Tabs**, a Safari web extension. It shows each Safari tab's website
icon, including tabs you haven't selected since WinMux started, and a speaker on tabs
playing sound or muted. Search also matches a Safari tab's host name. It needs Safari 18.4
or later: turn it on in Safari's **Settings › Extensions** and allow it on every website.
Without that access Safari hides tabs' titles from the extension, and those tabs keep
Safari's icon. Settings › Workspace Panel › Tabs › Content shows whether it's reporting and
opens Safari's extension settings.

The extension changes nothing in Safari. Selecting and closing tabs still use Accessibility,
as above. The extension only describes tabs, and WinMux trusts a description only when it
agrees with the tab strip it read:

- A Safari window takes the extension's details only when it has the same tabs, in the same
  order, with the same tab selected, and no other window matches as well. Two windows with
  the same tabs are told apart by their frames; if the frames don't settle it, both keep
  Safari's icon. A match must hold across two Accessibility reads 0.75 seconds apart.
- While some Safari window hasn't been read (one the sidebar doesn't show, or one whose tab
  strip couldn't be read yet), a new match also needs the window's frame to agree with where
  Safari says it is, and no unread window may be there too, since the unread window could be
  the real twin. A listed window whose last full read, within ten seconds, found no tab strip
  at all, such as Safari's Settings, doesn't count. Once made, a match holds on its tabs alone: Safari's reported
  frame is stale after WinMux moves a window, until its next report.
- A window that briefly stops matching, such as while a title changes, keeps its icons for up
  to ten seconds. It hides sound at once.
- A tab whose title Safari withholds from the extension (a start page, or a site without
  access) can differ, as long as the window has at least as many matching titles.

What leaves Safari: for each tab in a normal window, its title, host name (never the path or
query), whether it's active, pinned, playing sound or muted, and its icon as a 32-pixel PNG.
Private Browsing windows are left out entirely, even when the extension is allowed in them.
The extension sends these reports to WinMux on this Mac when tabs change and once a minute,
and WinMux keeps them in memory, with up to 512 icons; it never drops one a tab shows. It forgets a Safari profile that stops reporting after two
and a half minutes, and forgets everything when Safari quits or browser tabs are turned off.

Icons come from each page's own icon links, best near 32 pixels, then its `/favicon.ico`.
The extension fetches them inside Safari without cookies or a referrer, from the page's own
origin or a public HTTPS address; a page can't point it at a local network device. It doesn't
follow redirects, so an icon that redirects isn't used. Images above 256 KB or 1,024 pixels are
refused before they're decoded, and at most three fetches run at once. While WinMux isn't
running it fetches nothing; pages' icon links wait, and their icons are made once WinMux
answers again. Safari performs these requests itself, not WinMux, but they come from the extension
rather than the page, so they may not follow every setting Safari applies to browsing. The
icons stay in Safari's session storage, which it clears when it quits. A tab that hasn't
loaded since the extension started, such as one restored when Safari reopened, shows its
site's icon once any tab from the same site has loaded, and Safari's icon until then.

The extension reaches WinMux through its native part, which Safari runs in a sandbox. That
part connects to a socket in the app group container WinMux and the extension share. Since
macOS 15, apps outside the group can't use that folder without asking you. WinMux checks
that each connecting process is signed as WinMux Tabs by WinMux's own team before it reads
anything. On macOS 13 and 14, another program running as you could
take the socket's place while WinMux isn't running and receive the extension's reports.

When WinMux updates, Safari reloads the extension, which starts with no icons. Pages opened
after that report theirs as usual, and a tab whose page hasn't reported shows the icon last
made for its site. A page that was already open may keep Safari's icon until it reloads:
the extension asks such pages to report again, but in testing Safari 27.0 didn't deliver their
reports.

Safari 27.0 treated a Developer ID–signed build that wasn't notarized as unsigned, and listed it
only with unsigned extensions allowed; WinMux's releases are notarized. Development
builds from `swift build` or `make run` don't include the extension; only the Xcode-built app
(`make release`, `make install`) embeds it, and then only with a Developer ID signature and
team. See [Local development](development.md#build-an-app-and-matching-cli) to try one.

## Current boundaries

- The sidebar selects and closes browser tabs. Closing uses that exact tab's own close
  control, found without relying on localized names: Safari's close action for the tab,
  which works while its close button is hidden, or a Chrome-family tab's close button.
  A tab without either stays open and WinMux says so. Drag, reorder, detach, and
  browser-native tab-group editing remain in the browser. Header actions still apply
  to the window.
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

The Safari extension was checked natively in the macOS 27.0 test VM with Safari 27.0, using a
Developer ID–signed build that wasn't notarized (so with unsigned extensions allowed) and local
test pages. Safari listed and ran it, and asked for website access; its native part reached
WinMux through the app group socket and passed WinMux's signature check; and Settings showed
it reporting. Titles, including Safari's "Start Page", matched the tab strip exactly, and
Safari's window frames used WinMux's coordinates, including hidden windows'. Browser groups
showed each page's icon, and searching a host found its tabs. That run found and fixed three
defects: Settings crashed on SafariServices' callback, Safari's repeated address updates
discarded every icon, and a newly opened, unmeasured window blocked all pairings. Not checked
natively: a notarized build, sound and mute, Private Browsing, several profiles, Sparkle
replacing the extension while Safari runs, real websites, and macOS 13 through 15.

The full arm64 suite completed 1,548 tests with 7 existing skips and no failures;
`swift build --arch arm64` also passed. The Mac locked during additional live checks,
so notification delivery, typing an uncommitted address, and the full sidebar-to-
browser selection flow remain pending desktop validation.
