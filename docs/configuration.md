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

## Dock or Sidebar

```toml
[workspace-sidebar]
mode = 'dock' # 'dock' or 'sidebar'
dock-position = 'left' # Dock only: 'left', 'bottom', or 'right'
dock-icon-size = 48 # Maximum; icons shrink together when space is tight.
dock-left-gap = 2 # Gap at the selected edge; closes when expanded.
dock-magnification = true
dock-magnification-amount = 0.5 # 0 = no growth, 0.5 = 1.5×, 1 = 2×.
show-app-badges = true
```

The default mode is Dock; set `mode = 'sidebar'` to use Sidebar instead.
Legacy `show-app-icons` settings still apply when `mode` is absent, including
`show-app-icons = false` for Sidebar. Each mode retains its saved appearance options.
See [appearance](sidebar-appearance.md) for glass, solid colors, and blur, and
[Dock placement](dock-placement.md) for position and native Dock behavior.

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

## Keep empty workspaces

Persistent workspaces require configuration version 2. Set these at the top level:

```toml
config-version = 2
persistent-workspaces = ['1', '2', '3']
```

You can also edit this list in **Settings → Projects & Workspaces**.

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
