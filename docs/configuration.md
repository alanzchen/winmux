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

`mode = 'tabs'` turns the expanded Sidebar into a list of vertical tabs, like a
browser sidebar. It works well kept open:

```toml
[workspace-sidebar]
mode = 'tabs'
always-expanded = true
```

- Workspaces work like a browser's tabs. **New Tab**, at the top of the list, opens an
  empty workspace right after the current one with the [launcher](#open-a-new-window-from-new-workspace),
  so you pick an app for it. Press Esc or click away without picking one, and the empty
  workspace closes again and you're back where you were.
- A window you open gets its own workspace right after the one it opened from, as
  [`open-new-windows-in-new-workspace`](#open-each-new-window-in-its-own-workspace)
  does. In Tabs mode that's on unless you set it to `false`.
- Close a workspace's last window and WinMux switches to the next workspace with windows,
  or the previous one if it was the last. A saved workspace stays, like a pinned tab.
- A workspace with one window is one tab, showing the app icon and window title. Two
  windows share a tab, split in halves; click a half to switch to that window. An empty
  workspace shows as **Empty Tab**; closing it moves to the next tab. Click a tab to switch to that window,
  even on another workspace. The focused window is highlighted. As in the Sidebar, tabs
  of a project you are only browsing don't switch, and a workspace shown on another
  display asks before it moves to this one.
- Hover a tab and click **×**, or middle-click it, to close the window; on a split tab
  that closes one half. Right-click a tab for the workspace's menu. On a split tab or a
  folder it includes **Separate into Tabs**, which gives each window but the one in use,
  including windows in a stack, a tab of its own.
- A workspace with a name you gave it, a saved workspace, or one with three or more
  windows or a stack is a folder. Click the chevron to collapse one; a collapsed folder
  still shows the window you are using, and a search shows every match. Click a folder's
  name to switch to that workspace, or right-click it to rename, save, or delete it.
- A stack of tabbed windows appears as an indented group.
- Drag a tab onto another folder to move the window there, or onto **New Tab** to
  give it its own workspace right after the one it came from.
- The emoji project switcher sits at the bottom.

Tabs mode uses the Sidebar's placement, collapsed rail, auto-hide, and edge resizing.

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

`always-expanded` takes precedence over `auto-hide`. In Sidebar mode,
`stay-on-top = false` allows system UI such as the macOS Dock to appear above it.

## Clock and calendar

```toml
[workspace-sidebar]
show-clock = true
show-seconds = false
show-date = true
show-weekday = true
```

`show-clock = false` hides the whole clock card. The other options control its
parts independently; a weekday label can remain visible without the date.

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
