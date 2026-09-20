<p align="left">
  <img src="resources/winmux-logo.svg" width="80" alt="WinMux logo">
</p>

# WinMux

Organize your Mac's windows into workspaces, with a visual Dock or Sidebar,
automatic tiling, and draggable window tabs.

**[Download](https://github.com/alanzchen/winmux/releases)** ·
[Get started](#get-started) · [Customize](#make-it-yours) ·
[CLI guide](docs/cli.md) · [Report an issue](https://github.com/alanzchen/winmux/issues)

This is the **alanzchen fork** of [WinMux](https://github.com/ZimengXiong/winmux),
with a customizable app-icon Dock, expanded settings, and its own signed updates.

![WinMux Sidebar showing workspaces beside tiled windows and tab groups](resources/screenshots/winmux-overview.png)

*Sidebar mode with tiled windows and tab groups.*

## Get started

**Requirements:** an Apple Silicon Mac running macOS 13 or later. Native Liquid
Glass requires macOS 26 or later; older systems use a blurred background.

1. Open [Releases](https://github.com/alanzchen/winmux/releases) and choose the
   newest **Preview** release. Download its `.dmg` file.
2. Open the DMG, drag **WinMux.app** into **Applications**, and launch it.
3. Allow **WinMux** in **System Settings → Privacy & Security → Accessibility**
   so it can arrange and focus windows.
4. Open **Settings** from WinMux's menu-bar menu. Under **Dock & Sidebar**, choose
   your preferred mode and position.

WinMux starts in **Dock** mode and tiles windows automatically. To keep windows
at their existing size and position, turn off **Windows & Layout → Tile new windows
automatically**. You can still use workspaces and tile individual windows later.

Screen Recording is optional and enables the double-sided window animation.
It is not needed for normal tiling, the Dock, or the Sidebar.

### Updates and existing installations

Preview builds check this fork's update feed automatically. Use **Check for
Updates…** in the menu-bar menu to check now. The app and its bundled CLI update
together; existing automatic-update preferences are respected.

If you are using upstream WinMux or an older development build, install a fork
Preview manually once to switch to this update channel. The upstream Homebrew tap
installs upstream builds.

## Choose your view

| Feature | Dock | Sidebar |
| --- | --- | --- |
| Workspace view | Workspace tiles followed by app icons | Compact rail that expands into a window list and search |
| Position | Left, bottom, or right | Left |
| Appearance | Liquid Glass or a solid color; adjustable opacity | Dark, blurred background with adjustable darkness |
| Hover behavior | Optional icon magnification with adjustable strength | Expand to browse windows |
| Best for | Switching visually between apps and workspaces | Searching and managing individual windows |

Set a maximum icon size; the Dock shrinks icons together when space is tight.
Very crowded Docks scroll. Use the expand arrow or **Control–F** for search and
individual window details. The expanded view uses the Sidebar's separate
appearance settings.

Both modes support auto-hide, keeping the expanded panel open, and hiding during
native macOS fullscreen. Bottom placement temporarily enables the macOS Dock's
auto-hide setting and restores your previous setting afterward. See
[Dock placement](docs/dock-placement.md) for how the two Docks share a display.

## Everyday use

- **Switch workspaces:** click a workspace tile. In Dock mode, click an app icon
  to focus one of its windows in that workspace.
- **Move a window:** drag an app icon or an expanded window row onto another
  workspace. Expand the Dock to pick a specific window when an app has several.
- **Search:** click the search button in the expanded view or press **Control–F**.
  Keeping the Sidebar expanded does not capture typing until you start searching.
- **Group windows:** tab groups let several windows share one area. Click a tab
  to switch, or drag tabs to reorder them or move them between workspaces.
- **Separate projects:** a project holds a set of workspaces—for example, Work and
  Personal. Use the project indicators to switch between them.
- **Use multiple displays:** each display can show a different workspace. Each
  Dock initially filters to its own display. Moving a workspace already shown
  elsewhere requires confirming **Override**.

Empty workspaces normally disappear. Add names under **Settings → Projects &
Workspaces → Persistent workspaces** to keep them available.

### Handy shortcuts

These are the defaults for a new configuration. Imported or customized bindings
may differ; edit them in **Settings → Shortcuts**.

| Shortcut | Action |
| --- | --- |
| Control–F | Open Sidebar search |
| Control–1 … 9 | Switch to workspace 1 … 9 |
| Option–H / J / K / L | Focus left / down / up / right |
| Option–Shift–T | Toggle the focused window between floating and tiled |
| Option–Tab | Switch to the next window tab |

## Make it yours

Start in **Settings**—no configuration file editing is required. Search for a
setting by name, preview Dock appearance changes, and adjust:

- **Dock & Sidebar:** position, auto-hide, icon size, magnification, app badges,
  clock, and separate compact Dock and expanded-panel backgrounds.
- **Windows & Layout:** automatic tiling, window tabs, and spacing between windows.
- **Projects & Workspaces:** persistent workspaces and workspace shortcuts.

Right-click a project indicator to give it an [emoji](docs/dock-project-emojis.md).
WinMux also picks up [replacement app icons](docs/replacement-app-icons.md) exposed
by macOS, including icons set through Finder's Get Info. Custom animated Dock
artwork is not always available. Optional badges show the labels apps expose in
the native Dock.

For file-based setup, edit `~/.config/winmux/winmux.toml`, or use **Settings →
Advanced → TOML Editor**. Valid saved edits reload automatically by default.
For example, edit the existing section:

```toml
[workspace-sidebar]
mode = 'dock'
dock-position = 'left'
dock-magnification = true
show-app-badges = true
```

See [configuration examples](docs/configuration.md), the
[default configuration](resources/default-config.toml), and the
[Settings guide](docs/settings-ux.md) for more options.

**Coming from AeroSpace?** On first launch, if no WinMux configuration exists,
WinMux imports your AeroSpace shortcuts and key mapping and fills in the remaining
settings with WinMux defaults. Your AeroSpace file is left untouched. An existing
WinMux configuration is kept.

## Command-line control

The optional `winmux` command controls the running app and supports shell scripts,
JSON queries, projects, and layout automation.

Install the included `bin/winmux` launcher using the
[CLI setup guide](docs/cli.md#quick-start), then try:

```sh
winmux list-workspaces --all --json
winmux list-windows --all --json
winmux open-sidebar
winmux --help
```

Use the launcher from the same fork installation so app updates keep the client
in sync. See the [full CLI guide](docs/cli.md) for commands and examples.

## Help and documentation

| Looking for… | Start here |
| --- | --- |
| Glass, blur, colors, and opacity | [Appearance guide](docs/sidebar-appearance.md) |
| Dock position and macOS Dock behavior | [Dock placement](docs/dock-placement.md) |
| Configuration recipes | [Configuration guide](docs/configuration.md) |
| Stutter or an unresponsive Dock | [Record a performance report](docs/dock-performance-debugging.md) |
| Build or contribute | [Local development](docs/development.md) · [Contributor guidelines](AGENTS.md) |
| Signing and publishing releases | [Release guide](docs/releasing.md) |

For a bug report, include your WinMux version, macOS version, display arrangement,
and steps to reproduce it in [this fork's issue tracker](https://github.com/alanzchen/winmux/issues).

## Credits and license

Built on [WinMux by Zimeng Xiong](https://github.com/ZimengXiong/winmux) and
[AeroSpace](https://github.com/nikitabobko/AeroSpace).
Released under the [MIT License](LICENSE.txt); see [third-party notices](legal/README.md).
