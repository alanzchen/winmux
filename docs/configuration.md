# Configuration examples

Most options are available in **Settings**. These examples are for users who
prefer editing TOML in **Settings → Advanced → TOML Editor** or a text editor.
The default file is `~/.config/winmux/winmux.toml`; `XDG_CONFIG_HOME` and an explicit
`--config-path` can select another location. With the CLI installed, locate it with:

```sh
winmux config --config-path
```

Edit matching keys in existing sections; do not append duplicate section headers.
Root-level options go before the first `[section]`. Valid saved edits reload
automatically by default. To check a file before applying it:

```sh
winmux reload-config --dry-run
winmux reload-config
```

The [default configuration](../resources/default-config.toml) lists the available
starting values. See the [Settings guide](settings-ux.md) for saving and recovery.

## Dock, Sidebar, or Tabs

```toml
[workspace-sidebar]
mode = 'dock' # 'dock', 'sidebar', or 'tabs'
dock-position = 'left' # Dock only: 'left', 'bottom', or 'right'
dock-icon-size = 48 # Maximum; icons shrink together when space is tight.
dock-left-gap = 2 # Gap at the selected edge; closes when expanded.
dock-magnification = true
dock-magnification-amount = 0.5 # 0 = no growth, 0.5 = 1.5×, 1 = 2×.
show-app-badges = true
dock-identity-labels = 'auto' # auto (repeated apps), always, or off.
show-workspace-tooltips = true
show-app-tooltips = true
```

The default mode is Dock; set `mode = 'sidebar'` to use Sidebar instead.
Legacy `show-app-icons` settings still apply when `mode` is absent, including
`show-app-icons = false` for Sidebar. Each mode retains its saved appearance options.
See [appearance](sidebar-appearance.md) for glass, solid colors, and blur, and
[Dock placement](dock-placement.md) for position and native Dock behavior.

### Tabs

`mode = 'tabs'` opens a full-height browser-style sidebar. It stays open by default,
independently of the other modes:

```toml
[workspace-sidebar]
mode = 'tabs'
tabs-always-expanded = true
```

- Each workspace is a tab row. One window shows its icon and title; tiled windows
  share the row side by side. Click a segment to focus that window. Renaming or
  saving a row keeps that same presentation.
- Tabs start ungrouped. Right-click one and choose **Add to Group → New Group…**
  to name an optional group. Select a color or emoji in the editor. Group membership
  only organizes the sidebar; it does not tile the group's windows together.
- Drag a row onto a group header to add it, or use **Add to Group**. A split moves
  into the group as one row. Collapse groups with the chevron; the active tab stays
  visible. Searching expands matching groups and also matches group names.
- Right-click a group to move it to another project, create a tab in it, or **Ungroup
  Tabs**, which keeps its tabs and windows. **Remove from Group** removes just one row.
- Shift-click tabs to choose a range, or Command-click to add or remove one; a plain
  click goes back to one tab. Right-click a chosen tab to group, pin, or close them all.
  Drag a chosen tab to move every chosen tab together, whole and in order: between tabs, on
  this display or in another display's list, into a group, or onto the pins. They go only
  where all of them can, Undo puts them all back, and the choice ends once they've moved.
  Dragging a tab that isn't chosen moves only that tab. Chosen tabs don't split with another
  tab, open a New Tab, or drop onto the screen, and pinned and unpinned tabs chosen together
  go nowhere.
- **Pin Tab** places a row in the shortcut tiles at the top; so does dragging it onto
  them, or, with nothing pinned yet, onto **Drop to Pin** there. Dropped beside a tile,
  it's pinned in that place; a line between the tiles marks the spot. A pinned tile drags
  as its whole tab, split or empty: beside another tile to rearrange the pins, between
  two tabs in the list to unpin it there, onto a group to unpin it into the group, or
  onto **New Tab** to unpin it in place. A pin with one window is the entry to that
  window alone, and no split turns it into a pinned split. Dragged over a tab in the list
  and held there for a moment, its window splits with that tab: the half under the
  pointer is highlighted and chooses the side, and the tab stays an ordinary tab. Moving
  across a tab without the pause does nothing. Drag a tab onto the middle of a pinned
  tile and pause for a moment to split its window with the pin's, the half under the
  pointer choosing the side: the split goes to the dragged tab, or to a new ordinary tab
  when the window came out of a split. Nearer a tile's sides, the tab is pinned beside it
  however long it rests there. A pinned tile held over another pin's middle splits with
  it the same way, in a new ordinary tab, and a window dragged in from the screen onto a
  pin, or onto its window, splits with it too, as does `move-node-to-workspace` (or
  `-to-monitor`, `-to-project`) naming the pin. Moving a pin's window out, by any of these,
  lends it the same way. The pin keeps its place and turns grey while its window is in
  the split; it still clicks, and a click brings that same window back to it, alone,
  leaving the rest of the split where it is. A minimized window is restored first; a
  hidden app's or full-screen window is shown where it is, with a notice. An ordinary tab
  it leaves empty closes. An empty pin still takes in one window, or, dragged over a tab
  with one window, that tab (labelled **Tile into Pin**), never more than one. A split is
  pinned only from its tab's menu, with **Pin Tab**; dragging it onto the pins, or chosen
  tabs with one among them, pins nothing. A pinned split stays one whatever windows it
  has now, and remembers where each was. It shares a window with that window's own pin:
  a click on the pin brings the window back alone, and a click on the pinned split brings
  back those of its windows that are back in their pins, each to its place. While any of
  its windows is open elsewhere, an empty pinned split never opens its apps again; a
  notice says where they are. A grey pin and a pinned split take no other window in, and a
  pinned split splits with nothing. A tab pinned from its menu goes after the
  pins already arranged. Pins, their order, group membership,
  colors and emoji are saved in `sidebar-organization.json` beside the saved-workspace
  file. Customizing, pinning or grouping a workspace saves its identity and layout for
  restoration; unpinning or ungrouping leaves that saved workspace intact. **Forget
  Saved Workspace** clears its saved identity, pin, appearance and group membership.
  A pinned split shows all its windows in one joined tile; click a segment to focus
  that window.
- Pins come in two sections. **Pin Tab** pins a tab in its project, in the lower section.
  **Pin to All Projects** pins it in the upper section, which every project's sidebar
  shows, above that project's own pins, with a thin line between them. Each section wraps
  onto more rows as it fills. Drag a pin between the sections to move it: it stays pinned,
  with its tab, windows and split, and Undo puts it back. A pin dragged down, or pinned
  with **Pin to “Project” Only**, joins the pins of the project the sidebar shows. While
  dragging, a section with no pins offers **Pin to All Projects** over the project's name,
  or **Drop to Pin** over the search field, so nothing moves under the pointer. Showing a
  pin in All Projects keeps the sidebar in the project it was showing, and switching
  project keeps it on screen: only the project below it changes. New Tab, and windows
  opened from it, open in that project, first among its tabs. Unpinned, or forgotten, it
  becomes a tab of the project shown. It keeps a project of its own, where builds before
  this one, the Dock and the command line list it; deleting that project moves it to
  Default and keeps it, with its windows. A build before this one shows it as a pin of
  that project, and its next change to the pins makes it one.
- Each display's sidebar shows the pins of the tabs on that display. To show every pin
  on every display, set `share-pinned-tabs = true` (**Share pinned tabs across
  displays** in Settings). Each display's sidebar then has the same tiles, in the same
  order, for the project it's showing. Each project keeps its own pins, and each
  display keeps its own tab list, groups and **New Tab**. Pinning, unpinning or
  reordering pins on one display changes every display, and turning the setting off
  gives each display its own pins back. Dragging a tab onto the pins, or rearranging
  them, never moves it to another display; dropping it on a display's tabs, groups,
  list or **New Tab** still brings it there. Without the setting, dropping a tab on
  another display's pins brings it to that display. A pin whose tab is on another display, on
  screen there or kept there while hidden, shows a faint display outline in its
  corner, and its tooltip names that display. Clicking a pin brings its tab to the
  display you clicked it on, whether it was hidden or on screen on another display,
  without asking; that display then shows another of the project's tabs. A tab held to
  its display by `workspace-to-monitor-force-assignment`, or a saved tab [kept on its
  display](#multiple-displays), opens as it always has.
- **New Tab** opens an empty workspace after the current one with the
  [launcher](#open-a-new-window-from-new-workspace). A new window normally gets its own
  tab; [`open-new-windows-in-new-workspace`](#open-each-new-window-in-its-own-workspace)
  can override that default.
- Tabs don't stay empty. When a tab's last window goes, whether it closes, moves to
  another tab or display, or is dragged away, the tab closes and its display shows the
  next tab, or the previous one. Moving the last window of the tab on screen into another
  tab follows it there. A new tab stays until something opens in it or you leave it. When
  a display has no other tab, it keeps showing the empty one, which the list leaves out.
- Pinned and saved tabs stay when their last window closes, greyed and showing their
  apps' icons. A grey pin whose window is in another tab's split is different: clicking it
  brings that window back, and never opens another. Clicking any other selects it and
  opens those apps again: an app that quit
  relaunches and its windows return to their saved places, this tab first; a running app
  is asked for a new window in the tab, as the [launcher](#open-a-new-window-from-new-workspace)
  asks. Shift- or Command-clicking only chooses the tab.
- Hover a tab and click **×**, or middle-click, to close its window. In a split,
  this closes only that segment. **Separate into Tabs** gives each window its own row.
  In a [browser window's tab list](browser-tabs.md), the same closes one browser tab.
- Drag a tab onto another and pause over it for a moment to tile their windows
  side by side; the half under the pointer is highlighted and chooses the side. Drag between rows to reorder,
  or to pull one window out of a split. A line marks where the tab will go, labeled
  **New Tab** when the drop gives a window a tab of its own. Dropping in the empty
  space below the tabs puts the tab last, outside any group. Releasing where nothing
  is marked leaves the tab where it was. There are no window stacks or horizontal
  window-tab strips in this mode. Existing stacks become separate sidebar rows,
  preserving each entry's split. Dock and Sidebar modes continue to support window
  stacks.
- Groups containing an active tab on this sidebar's display stay fully expanded,
  with the disclosure arrow pointing down. Other groups can be collapsed from
  the header or context menu.
- Your groups, a browser window's tabs, and workspace folders share one look: a
  tinted card whose header has the arrow on the tabs' icon column, the group's icon
  and name, and a count; its rows start under the group's icon. Groups open and
  close, and tabs move, with short animations. With Reduce Motion, they change in
  place and only hover and drop highlights fade.
- Apple Music's tab shows what's playing under its row, with its artwork, progress, and
  previous, play/pause and next buttons. Set `music-player-at-bottom = true` (**Keep the
  Music player at the bottom** in Settings) to show the player at the bottom of the
  expanded sidebar instead, above the project switcher, while Music is open. It stays
  there whichever tab or project is showing, even when Music has no window open.
  Clicking the track goes to Music's window. If another display is showing that window,
  focus moves there; with no window open, Music opens one.
- The animated project switcher is at the bottom. Right-click a project, workspace or group in
  any mode for the shared name field, color swatches and searchable emoji picker.
  Appearance edits keep the menu open. Enter commits the name; Escape discards an
  uncommitted name edit. Clicking outside commits and closes the editor.

The header's sidebar button toggles `tabs-always-expanded`. Tabs mode retains
Sidebar placement, edge resizing and display controls. A tab on another display
asks before moving to this one, except a pin shared with `share-pinned-tabs`.
The sidebar's bottom edge follows the same display reservation and outer gap as
the tiled windows. Enable `show-app-badges` to mirror native Dock labels at the
right of tabs and on pinned icons; compact icons show small red dots.

### Topic group suggestions

Tabs mode can suggest groups for a project's tabs with Apple Intelligence's on-device
model. It's off by default; turn on **Suggest topic groups with Apple Intelligence** in
Settings, or:

```toml
[workspace-sidebar.intelligence]
mode = 'manual'      # Default: 'off'
excluded-apps = []   # Bundle IDs whose windows are never analyzed
```

- Right-click the project's name at the top of the Tabs sidebar, or several chosen
  tabs, and choose **Suggest Topic Groups…**. Nothing is read before you do, and nothing
  runs in the background. The model needs macOS 26 or later with Apple Intelligence
  turned on; the preview says why when it isn't available. There's no cloud fallback.
- WinMux reads only the tab titles the sidebar already shows, for the project and
  display list that sidebar shows, or for the chosen tabs. Pinned tabs and tabs already
  in a group are left as they are. A tab with a window of a browser or of an app in
  `excluded-apps` is skipped whole, split and all, even when that window is minimized.
  The preview lists skipped tabs; for a browser tab it shows exactly the text that would
  be analyzed and offers **Include these titles in this suggestion**. That choice lasts
  for that one suggestion and covers only that text. WinMux can't tell whether a
  browser window is private. Browser tabs inside a window are never analyzed.
- The preview proposes groups of at least two tabs, each tab in one group at most, and
  says which words they share. Tabs that don't clearly share a specific topic stay
  where they are; one app alone, or a tab whose windows are about different things, is
  never enough to group. Rename a group, uncheck tabs or whole groups, then **Apply**.
  **What was analyzed** shows the text sent to the model.
- Apply checks every tab again and makes all the groups in one change, as ordinary
  groups you can rename, recolor, drag or ungroup. If any tab changed meanwhile,
  nothing is applied and the preview asks you to suggest again. **Undo Group by Topic**
  removes the groups again without touching layouts, displays or focus. Cancel and the
  preview itself save nothing. With `--read-only`, Apply is unavailable.
- Suggestions and their cached tags live in memory only. Turning the setting off, or
  leaving Tabs mode, stops a suggestion in progress and forgets them. Logs record only
  counts, timings and error categories, never titles.

## Show workspaces from this display or all displays

Each Dock, Sidebar, or Tabs panel lists only the workspaces on the display it's on.
To list every display's workspaces in every panel instead:

```toml
[workspace-sidebar]
display-filter = 'all-displays' # Default: 'this-display'
```

A panel's display menu lists This Display, All Displays, Focused (with
`enable-focus`), and the other displays by name. A choice there applies to that
panel only and lasts until WinMux quits, the chosen display disconnects, or
`display-filter` changes. With This Display or All Displays, workspaces open
from their rows in every mode. When `monitor` leaves a display without a panel,
panels list every display so that display's workspaces stay reachable. In Tabs
mode, [`share-pinned-tabs`](#tabs) shares just the pinned tabs across displays.

## Hide the rail or keep it expanded

To reveal the rail only when the pointer reaches its display edge:

```toml
[workspace-sidebar]
auto-hide = true
```

To keep the full panel visible and reserve space for it beside tiled windows:

```toml
[workspace-sidebar]
always-expanded = true
width = 240
```

To change the width, drag the panel's inner edge, which highlights under the
pointer. Tiled windows follow as you drag. When you let go, WinMux saves the new
`width`, from 120 to 480 points and always greater than `collapsed-width`. A bottom
Dock keeps its fitted height.

Each mode has a minimum width that its content fits: 160 points in Tabs mode and 120 in
Sidebar mode. The edge stops there, and so does the width slider in Settings. A smaller
`width` or display width in your file still loads, but the panel uses the minimum
instead. WinMux doesn't change the file. In Dock mode, WinMux uses `width` as written,
because it also sets the width of each project column in the floating view.

In Sidebar and Tabs modes, each display remembers its own width. Dragging the edge
on one display resizes only that display's panel and saves its width under the
display's name. Displays you haven't resized use `width`. Double-click the edge to
put a display back on `width`. Set `width-per-display = false` (**Remember width
for each display** in Settings) to have every display share `width` again; the saved
widths stay in the file for when you turn it back on:

```toml
[workspace-sidebar]
width = 240
width-per-display = true

[workspace-sidebar.display-widths]
"Built-in Retina Display" = 220
"DELL U3224KB" = 320
```

Widths are saved under each display's name in the panel's display menu, where
identical displays are numbered from left to right, such as `"DELL U3224KB 2"`. Their
widths therefore follow their places in the arrangement. While only one of them is
connected, it goes by its plain name, which keeps a width of its own. Edit the table
in the form shown above: WinMux reports an error instead of saving a dragged width
into an inline `display-widths = { … }` table.

In Dock mode, expanding normally keeps the Dock in place and opens a floating view
with one column per project. With `always-expanded`, the Dock instead becomes a
reserved one-pane panel: at the bottom it lists every project; on the left or right
it shows the current project and can browse a second one.

In the floating view, double-click a project or workspace name to rename it, and
drag a project's header to reorder the projects. WinMux saves the order as project
ids in the `[workspace-sidebar]` table, rewriting the list on one line; projects that
are not listed follow in creation order:

```toml
[workspace-sidebar]
project-order = ["project-2b7e0c4a-1d3f-4e5a-9b8c-7d6e5f4a3b2c", "default"]
```

`always-expanded` (or `tabs-always-expanded` in Tabs mode) takes precedence over `auto-hide`. In every mode,
`stay-on-top = false` allows system UI such as the macOS Dock to appear above the panel.

## Clock and calendar

```toml
[workspace-sidebar]
show-clock = true
show-seconds = false
show-date = true
show-weekday = true
```

`show-clock = false` hides the whole clock card. The other options control its
parts independently; a weekday label can remain visible without the date. Tabs mode
has no clock. A Dock on the left or right shows only the time until it is kept
expanded; a bottom Dock shows the date line when it is tall enough.

`show-status-pills` has no effect. WinMux still accepts it so older configurations load.

## Window spacing

To remove spacing between tiled windows and at display edges:

```toml
[gaps]
inner.horizontal = 0
inner.vertical = 0
outer.left = 0
outer.bottom = 0
outer.top = 0
outer.right = 0
```

With a visible Dock or Sidebar, the corresponding outer gap separates the panel
from tiled windows. The compact Dock's own distance from the screen edge is the
separate `dock-left-gap` option.

## Start with floating windows

Set these at the top of the file, before any section headers:

```toml
automatically-tile-new-windows = false
enable-shake-to-toggle-tiling = false
```

The first option keeps windows at their existing macOS size and position when
WinMux discovers them. You can still tile a window with `winmux layout tiling`.
The second disables the gesture that toggles floating/tiling when you shake a
window by its title bar. Omit it to keep the gesture enabled.

## Open each new window in its own workspace

```toml
open-new-windows-in-new-workspace = true
```

A window you open moves to an empty workspace in the current project, on the same
display; in Tabs mode, right after the workspace it opened from, in the order an app
opens several at once. Unset, this is on in Tabs mode and off otherwise. WinMux switches
to that workspace when the window comes from the app you are using; a window from a
background app moves without taking focus. A window that opens
into an empty workspace stays there. Dialogs, popups, windows already open when WinMux starts,
restored windows, windows claimed by saved workspaces, and windows that
`[[on-window-detected]]` rules move to another workspace keep their place. This option
takes precedence over `auto-add-new-windows-to-tab-group`.

## Open a new window from New Workspace

```toml
[workspace-sidebar]
new-workspace-launcher = true
launcher-menu-fallback = false
```

With `new-workspace-launcher`, clicking **New Workspace** in the sidebar opens a launcher
in the empty workspace, like a browser's new-tab page. Tabs mode's **New Tab** always
opens it. Type to find an app and press
Return. WinMux opens a **new window** of that app in the workspace, even if the app is
already running with windows elsewhere; it doesn't switch you to those windows.

Each result says what choosing it does:

- **New window**: WinMux asks the app for one. This works for Safari, Chrome, Brave,
  Edge, Chromium, Finder, Terminal, iTerm, and TextEdit, whether or not they're running;
  an app that isn't running opens in the background first, restores its windows, and
  then makes the new one. The first time, macOS asks you to allow WinMux to control that
  app; you can change this later in System Settings → Privacy & Security → Automation.
- **Open**: the app isn't running, so WinMux opens it and the launcher closes. Its
  windows follow the usual rules, including `[[on-window-detected]]` and
  `open-new-windows-in-new-workspace`; otherwise they open in the focused workspace.
- **No new window**: WinMux can't make a new window of this running app. Choosing it
  says so instead of switching to the app's existing windows.

`launcher-menu-fallback = true` lets the launcher try other running apps by pressing
their own New Window menu item. It skips apps without one, and never presses New Tab,
New Document, or private-window items.

While a window opens, the launcher says so, with a Cancel button; if nothing arrives
within a few seconds of the app accepting the request, it tells you instead. The first new window that app
opens after you choose it is the one placed in the workspace, so a window the app opens
on its own at the same moment can be taken instead. Windows the app already had,
including ones WinMux is restoring, are never moved. The new window takes focus unless
you have moved on. Saved-workspace slots, `[[on-window-detected]]` rules, and
`open-new-windows-in-new-workspace` don't move a window you opened this way. Press Esc
or click elsewhere to close the launcher and keep the empty workspace; in Tabs mode the
empty workspace closes too and you go back to where you were. Closing the launcher while
a window is opening lets that window follow the usual rules. Dropping a window onto New
Workspace or New Tab never opens the launcher.

`winmux open-launcher` opens the launcher for the focused workspace, and
`winmux open-launcher --new-workspace` creates an empty workspace first; in Tabs mode,
a new tab right after the current one, as New Tab does.

## Close windows with a middle click

Middle-click a window tab, or a window in the expanded sidebar, to close that window.
This presses the window's close button, so an app can still ask to save changes. If
the window was hidden, such as a background tab or a window on another workspace, and
it is still open a moment later, WinMux switches to it so you can see the prompt. To
turn this off, set this at the top of the file:

```toml
middle-click-closes-windows = false
```

## Keep empty workspaces

Persistent workspaces require configuration version 2. Set these at the top level:

```toml
config-version = 2
persistent-workspaces = ['1', '2', '3']
```

You can also edit this list in **Settings → Projects & Workspaces**.

## Saved workspaces

Naming a workspace saves it. A saved workspace keeps its name, project, layout,
app windows, and home display, and comes back after WinMux, an app, or your Mac
restarts. It is never removed when empty. Set these in the `[workspace-sidebar]`
table, or in **Settings → Projects & Workspaces**:

```toml
[workspace-sidebar]
save-named-workspaces = true # Naming a workspace saves it.
open-saved-workspace-apps-at-startup = false
```

With `save-named-workspaces = false`, naming no longer saves; choose
**Save Workspace** in the workspace menu instead. Turning the option off doesn't
forget workspaces that are already saved. **Forget Saved Workspace** stops saving
one: it keeps its windows and name for now, and disappears like any other workspace
once it empties. Deleting a workspace or its project also forgets it. The first
time WinMux runs with saved workspaces, it also saves the named workspaces that
already have windows, unless `save-named-workspaces` is off.

Saved workspaces are stored in
`~/Library/Application Support/WinMux/saved-workspaces.json` (`WinMux-Debug` for
debug builds), not in the TOML file. The copy from before the current session's
first change is kept beside it as `saved-workspaces.previous.json`. A file written
by a newer WinMux is used read-only until you update.

Windows return to their places:

- **WinMux relaunches** (Quit, update, or crash) while apps keep running: every
  window returns to its slot in the saved layout.
- **An app relaunches** after it quit: its first windows within about 45 seconds
  of launching (or of showing its first window, for apps that take up to 10 minutes
  to show one or don't report a launch time) fill the waiting slots, matched by
  title. A window without a title waits up to 10 seconds for one, and stays where
  it is if WinMux couldn't place it within 45 seconds (for example while disabled
  or while the screen is locked). A window whose title
  matches none of them takes a slot only if it is the app's only waiting slot or
  either title is unknown. Windows opened later, for example with Cmd-N, behave
  normally. Places the relaunched app doesn't fill within about 45 seconds of
  launching or showing its first window are dropped about 15 seconds after that
  (60 if none of the workspace's windows came back). Until the app shows a window,
  they keep waiting, as if it hadn't relaunched.
- **Your Mac restarts or you log out:** after you log in, each app works like a
  relaunch. macOS may reopen apps itself; WinMux opens them only when you ask
  (see [Missing apps](#missing-apps)).

Quitting an app with Cmd-Q keeps its windows' places. Closing a window with Cmd-W
while the app keeps running removes its place after about 15 seconds (60 when every
window in the workspace disappears at once); moving a window to another workspace
removes it at once. Minimized, hidden, and native fullscreen windows keep their
places. WinMux pauses saving while the screen is locked, the Mac sleeps, or you
switch users, and during logout, restart, or shutdown, so windows closed as the Mac
shuts down keep their places.

Windows restored into a saved workspace don't run `on-window-detected` callbacks
at all, so no rule moves, resizes, or re-lays them out. Other new windows run the
callbacks as usual.

### Missing apps

A saved workspace waits for apps that aren't running. Choose **Open Missing Apps**
in the workspace menu to open them in the background; their windows then have
about 45 seconds to fill the waiting slots. To open every saved workspace's
missing apps when WinMux starts:

```toml
[workspace-sidebar]
open-saved-workspace-apps-at-startup = true
```

### Multiple displays

Each saved workspace has a home display, identified by the display's UUID (then
its vendor, model, and serial number, then the built-in display), so it survives
rearranging displays or changing the main display. When the home display is
disconnected, its saved workspaces are hidden. When it reconnects, at any
position, it shows the saved workspace most recently visible there. Moving a saved
workspace to another display makes that display its new home; while the home is
disconnected, the move is temporary.

Choose **Keep on “<Display>”** in the workspace menu to pin a workspace to its
current display, saving it if needed. While that display is connected, the
workspace won't move to another display, and when the display reconnects the
workspace returns even if it is showing elsewhere. Pinning again changes nothing,
so a workspace shown elsewhere while its display is disconnected keeps its home;
unpin it first to keep it on another display.
Displays WinMux can't identify can't be pinned to. A
`[workspace-to-monitor-force-assignment]` entry for the workspace wins over both
the home display and Keep on; the menu still lets you remove an older pin.

## Shortcuts and app launching

Edit the existing main binding section to assign commands:

```toml
[mode.main.binding]
ctrl-f = 'open-sidebar'
alt-shift-t = 'layout floating tiling'
cmd-h = [] # Disable the native Hide App shortcut.
```

Single-modifier tap bindings are also supported. For example:

```toml
[mode.main.binding-tap]
right-alt = 'open-sidebar'
```

Use `exec-and-forget` to run your own app-launching command or script. Opening a
new window depends on the app; activating an already-running app can switch to
its existing window on another workspace. See the [CLI guide](cli.md) for WinMux
commands and [default bindings](../resources/default-config.toml) for examples.

### Dock app menus and identity labels

Left-click focuses an app in its workspace; press and drag moves its window.
Right-click or Control-click an app icon opens its window list and actions for the
app's most recent window in that workspace (minimize/restore, move to workspace,
close), Show in Finder, Hide/Show, and Quit. Select a different window from the list
to make it the target of these actions.
Hide and Quit affect the represented application processes across workspaces.
Workspace rename/delete actions remain on workspace tiles. These are WinMux menus;
app-supplied native Dock extensions (such as browser-specific new-window commands)
are not imported.

`workspace-sidebar.dock-identity-labels` defaults to `auto`, labeling apps that
appear in more than one workspace. `always` labels every app and `off` disables
identity labels. Labels use the first four characters of a single window's title,
with the app-name prefix/suffix removed, or the workspace name for multiple windows.
Labels update when the window title changes; focus changes between windows do not
change a multi-window app's workspace label. Collisions within an app receive a numeric suffix. Full titles appear in tooltips and accessibility
labels. Identity labels are independent of red native notification badges.

Workspace and app hover labels can be enabled independently in Settings using
**Show workspace tooltips** and **Show app tooltips**, or through
`workspace-sidebar.show-workspace-tooltips` and `workspace-sidebar.show-app-tooltips`
in TOML. Both default to `true`. Set either to `false` to hide that kind of tooltip;
changes apply without restarting. Workspace tooltip visibility also controls
workspace help in Sidebar mode. Accessibility labels remain available.

Set `workspace-sidebar.show-hidden-workspace-app-reminders = true` (or enable
**Show hidden workspace app reminders** in Settings) to show temporary app reminders
after the Dock clock. This defaults to `false` and works independently of
`show-app-badges`. If the clock is off, reminders still appear at the end of the Dock;
vertical Docks place them at the bottom. The area fits three icons and scrolls to
show additional reminders.

Only apps with a native Dock badge in a workspace outside the current Dock are
included; workspaces already visible on another display are excluded. Click to
focus the app in its workspace, or right-click for the app menu. A short workspace
label and hover title identify the destination. Reminders disappear when the badge
clears, the workspace becomes visible, or it enters the current Dock. Updates use
the existing badge poll (about every two seconds), without requiring mouse movement.
macOS badges apply to the whole application, so the same app can remind in multiple
hidden workspaces; they do not identify which individual window has unread activity.
Reminder destination labels remain visible even when `dock-identity-labels` is
`off`, so reminders for the same app in different hidden workspaces stay identifiable.
