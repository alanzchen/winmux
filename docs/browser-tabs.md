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

## Sound

A speaker on a tab's row or pinned tile shows that its window is playing sound. macOS reports
sound only per app, so WinMux asks the browser's tabs which window it comes from:

- **Safari:** a tab playing sound shows a mute button, and a window without a tab bar shows a
  speaker in its address field. WinMux reads both along with the tabs it already reads. Only a
  window with such a tab shows the speaker. The address field's speaker also appears on a silent
  page, to mute a tab playing elsewhere, and only its English words say which, so in another
  language a window without a tab bar says nothing about its sound. With the [WinMux Tabs extension](#safari-extension),
  what the extension says about a tab wins while it describes the window, and windows it describes
  as silent show none, even while Safari plays elsewhere, such as in a Private Browsing window.
  Safari's words tell a muted tab from a playing one only in English; in other languages a muted
  tab shows the plain speaker.
- **Chrome, Chromium, Brave, and Edge:** a tab playing sound has "Audio playing" (or "Audio
  muted") at the end of its accessible name, in the browser's language. WinMux knows the
  wording in every language Chrome 154 ships, and takes it off the title it shows.
- **Other apps**, including Firefox and Arc, show their sound on every window, as before. For an
  app with one window, that's already exact.

When a tab says it plays, only its window shows the speaker; the app's other windows show none.
A tab that doesn't may still be playing: a camera recording or picture in picture replaces
Chromium's label, and a window WinMux hasn't read says nothing. So while no tab says it plays,
every window of the app shows its sound, except windows the Safari extension describes as silent.
When a browser starts or stops playing, WinMux reads its listed windows again right away.

A muted tab, and its window, show a speaker with a slash. Chrome labels a tab muted only while
it's trying to play; the extension reports every muted Safari tab. Pinned tiles are read like
listed windows so they can show this too. A window the sidebar stops listing keeps its tabs'
sound for ten seconds at most.

## Website icons

**Website icons for Chrome-family tabs** (`workspace-sidebar.browser-tab-icons`) is off by
default. When enabled, icons appear as tabs are selected in listed windows. Unvisited tabs, unsupported
addresses, and failed downloads use the browser's app icon. Safari tabs get their icons from
the [WinMux Tabs extension](#safari-extension) instead; this setting doesn't affect them.

A browser window with one tab isn't a group, so its row and pinned tile show that tab's
website icon in place of the browser's, at the same size, once the icon is known. A window
with more tabs keeps the browser's icon on its row, above its tabs' own icons.

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

The extension changes nothing in your pages or tabs; it only titles its own toolbar button
(below). Selecting and closing tabs still use Accessibility, as above. The extension only
describes tabs, and WinMux trusts a description only when it agrees with the tab strip it read:

- A Safari window takes the extension's details only when it has the same tabs, in the same
  order, with the same tab selected, and no other window matches as well. A match must hold
  across two Accessibility reads 0.75 seconds apart.
- The extension's toolbar button in each window names that window: WinMux reads its title along
  with the tab bar, and a window whose button names a window of the latest report is that one,
  wherever it is, even among twins in the same place. The title must come from that report's
  extension session, name the tab the report says is active there, and the window's tabs must
  agree. A tab keeps its title when it moves to another window, until the extension titles it
  again, so a title counts only once a report Safari measured after the read that saw it still
  agrees, with no tab moved, opened or closed in between; WinMux's answer asks Safari for that
  report, so this takes a few seconds. A title naming anything else (the button hasn't caught up
  with a switch, a tab moved, or the extension reloaded) names nothing, nor does one two windows
  show at once. Those windows, and windows without the button, are matched by the rules below.
  The button is only ever read: selecting, closing and moving never depend on it.
- Two windows with the same tabs, such as two one-tab windows on the same page, are told apart
  by where they were when Safari reported. WinMux notes where Safari's windows are a few times
  a second, and compares the bounds in each report only with where windows were when that
  report arrived, never with where they are now: WinMux moves windows (switching tabs parks one
  in a corner) and Safari doesn't report that. The extension notes when it begins measuring,
  and a window that moved, resized or reopened since just before then, or while the report was
  on its way, counts as unknown. The one paired must have been where Safari says, and every
  other twin seen elsewhere; an unknown twin could have been anywhere. If the report doesn't
  settle which twin is which, both keep Safari's icon and no sound, and WinMux asks Safari to
  report again when a newer report could settle it: in its answer to a report, which has the
  extension report again two seconds later (at once, then less often while the wait lasts, down to once a minute), as Safari 27.0 didn't
  wake the extension for a separate request. Twins that are
  in the same place in every report stay that way, and so do twins described by an extension
  from before this, whose reports don't say when it measured.
- While some Safari window hasn't been read (one the sidebar doesn't show, or one whose tab
  strip couldn't be read yet), a new match also needs the window, and no unread window, to
  have been where Safari says, since the unread window could be the real twin.
- Once made, a match holds as long as its tabs agree and Safari still reports that window,
  however WinMux moves it, and no other window can take its report. Only a window's button
  naming another report, or a later report that pairs the window, or that report, with another
  by where they were, replaces it. A window that
  closes, and a later one that gets its number, start over, and a window that opened after
  Safari measured a report isn't matched by that report.
- Within a matched window, each tab is matched with Safari's tab by Safari's id for it. A read
  made after a report pairs a tab with the one in its place; after that it keeps that tab while
  the tab bar is reordered, so tabs with the same title don't trade icons or sound. Among tabs
  with the same title, a read only proposes a pairing (it may have caught a reorder Safari
  hadn't reported yet). It counts once a report Safari measured after that read, and a read
  begun after the report arrived, still agree, and Safari's next report says no tab was moved,
  opened or closed in between. WinMux's answers ask Safari for those reports, so their sound
  follows their icons by seconds rather than waiting for Safari's once-a-minute check-in. A tab whose Safari tab is gone, or whose title no longer matches it,
  shows nothing from the extension until a read pairs it again. An extension from before tab
  ids matches them by position.
- A window that briefly stops matching, such as while a title changes, keeps its icons for up
  to ten seconds. It hides sound at once.
- A tab whose title Safari withholds from the extension (a start page, or a site without
  access) can differ, as long as the window has at least as many matching titles.
- Safari hides the tab bar of a window with one tab. WinMux reads such a window as that one
  tab, named by the window's title, and matches it with the extension's one-tab window of that
  title, by the rules above. To keep reads light, it reads just the window's title, and walks
  its controls again only when the title changes (as it does when a tab opens), when Safari
  starts or stops playing sound, and at least every 30 seconds.

What leaves Safari: for each tab in a normal window, its id (a number Safari gives it until
Safari quits), title, host name (never the path or query), whether it's active, pinned,
playing sound or muted, and its icon as a 32-pixel PNG; each window's id and place on screen; and
how many times tabs were moved, opened or closed since Safari started, with when the extension
began measuring.
Private Browsing windows are left out entirely, even when the extension is allowed in them.
The extension sends these reports to WinMux on this Mac when tabs change, a second after a
Safari window gains focus (once WinMux has moved its windows), and when WinMux's answer asks
for another, leaving out one that would say nothing new; and once a minute regardless. WinMux
keeps them in memory, with up to 512 icons; it never drops one a tab shows. It forgets a Safari profile that stops reporting after two
and a half minutes, and forgets everything when Safari quits or browser tabs are turned off.

### The toolbar button's title

So WinMux can tell which Safari window is which, the extension titles its toolbar button in
each normal window, through the title of that window's active tab: **WinMux Tabs ·** followed
by the first 8 characters of the extension's session (a random identifier it makes each time
Safari starts it), Safari's id for the window and its id for the tab, such as
`WinMux Tabs · 3f2a9c1e-1401-1402`. The title holds no page titles or addresses, and Private
Browsing windows keep the plain name. It's the button's tooltip, and VoiceOver reads it as the
button's name, so you'll see and hear those numbers there. A new tab shows the plain name until
the extension titles it, a moment after it becomes active. The title is visible in the
tooltip and readable by any app with Accessibility access, like the rest of Safari's window.

Without the button (removed with **View › Customize Toolbar**, or moved into the toolbar's
overflow menu in a narrow window), WinMux matches windows only by their tabs and where they
were, as above, and twins in the same place keep Safari's icon.

### How often WinMux reads Safari's tabs

WinMux reads a listed browser window's tab bar every second while it's focused and every four
seconds otherwise, and soon after an Accessibility notification. A Safari window the extension
describes in full, by a report from the last minute and a half, with access to every website,
is read only every 15 seconds, and within a second of an Accessibility notification: the
extension reports when its tabs change, and a report that no longer agrees with the last read
reads the window again at once. Any other window, and every
window while the extension is off, waiting, stale or without access to every website, is read
as before.

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

When WinMux updates, Safari reloads the extension, which starts with no icons. In testing
(Safari 27.0, a Developer ID–signed build), Safari also reloaded it each time WinMux started,
with a new session and new window and tab ids. The reloaded extension's first report can come
before WinMux listens, so a report WinMux doesn't take is tried again five seconds later, then
less often, up to once a minute: the extension reports, and titles its buttons, soon after
WinMux starts. Icons of pages open since before still wait until those pages reload. Pages opened
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
- Safari can leave tabs of a crowded tab bar without a parent, or piled up without a title.
  WinMux still lists them from the tab bar that lists them, naming piled-up tabs by their
  description; the selected tab, which always shows, must name its tab bar. A tab is scrolled
  into view before it's selected or closed. Safari ignores both on a tab that still names no
  parent, so WinMux then leaves it and brings its window forward as it is. Such tabs work
  again once any tab in the bar is selected, in Safari or from the sidebar. In Safari 27,
  tabs created by script (AppleScript `make new tab`) end up in this state; tabs opened
  with ⌘T didn't.
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
