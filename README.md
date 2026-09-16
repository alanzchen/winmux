
<p align="left">
  <img src="resources/winmux-logo.svg" width="80" alt="WinMux logo">
</p>

# WinMux

<p align="left">A powerful sidebar-first window manager for macOS.</p>

https://github.com/user-attachments/assets/51983568-a168-494f-8ae3-5f50ca1efce1

## Highlights
### Projects
Projects are collection of workspaces. Think of it like a parent/child hiearchy, you can switch between projects. Each project has it's own set of workspaces.

### Sidebar
The sidebar is a more interactively-performant and useful alternative to [Sketchybar](https://github.com/felixkratz/sketchybar) and traditional workspace menu bar dropdowns for most everyday tasks. It provides better visibility into spaces and spatial awareness on the desktop.

You can drag windows in and out of the sidebar from and to the current workspace. You can rearrange windows across all spaces using the sidebar, including tab groups.

By default the sidebar rests as a compact rail and expands when hovered. To hide the rail
completely until the pointer reaches the left display edge, enable auto-hide. On macOS 26 and
newer, native Liquid Glass is enabled by default. Choose an opaque solid color for greater
contrast across the sidebar, tab groups, and switcher:

```toml
[workspace-sidebar]
    auto-hide = true
    stay-on-top = false # Let the Dock appear above the sidebar.
    chrome-style = 'solid'
    solid-chrome-color = 'lavender' # Choose any color shown in Appearance, including custom.
```

To keep the full sidebar visible, reserve its expanded width when laying out tiled windows:

```toml
[workspace-sidebar]
    always-expanded = true
    width = 240
```

`always-expanded` takes precedence over `auto-hide`. The configured `gaps.outer.left` remains
the spacing between the sticky sidebar and tiled windows, and monitor selection continues to
control which displays reserve sidebar space.

The sidebar clock can be configured independently:

```toml
[workspace-sidebar]
    show-clock = true
    show-seconds = true
    show-date = true
    show-weekday = true
```

`show-clock` hides the entire clock card. The other settings independently control seconds,
the month and day, and the weekday; for example, `show-date = false` with
`show-weekday = true` leaves a weekday-only calendar label in the expanded sidebar.

### Workspace app icons and glass opacity

In **Settings → Appearance → Sidebar**, enable **Show workspace app icons** to
show each workspace's number or label together with its apps in the compact rail.
Narrow rails stack the icons below the number; wider rails show them beside it.
Each app appears once, including apps in floating windows and nested tab groups.
An overflow count marks additional apps. The compact rail keeps the configured
**Collapsed width** as its contents change. Expanding smoothly moves the workspace
label and app icons into the individual window list; collapsing restores the same
compact layout. Reduce Motion uses an immediate transition.

Use **Glass opacity** to adjust the sidebar's Liquid Glass background from 0–100%.
Text, app icons, and selection indicators remain readable. This control applies
only to the sidebar and is disabled when the chrome style is **Solid color**.

```toml
[workspace-sidebar]
    show-app-icons = true
    glass-opacity = 0.65
```

Both settings are optional: existing configurations keep their current appearance.

### Window and sidebar spacing

The `[gaps]` settings control the visible borders around tiled windows. `inner.horizontal`
and `inner.vertical` set the space between neighboring windows. The outer gaps set the space
at each display edge; when the sidebar is enabled, `outer.left` is the space between the
sidebar and the tiled windows. Any of these values can be reduced or set to zero independently.

For borderless tiling, including no border beside the sidebar:

```toml
[gaps]
    inner.horizontal = 0
    inner.vertical = 0
    outer.left = 0
    outer.bottom = 0
    outer.top = 0
    outer.right = 0
```
### Tab Groups
![](resources/screenshots/tab-groups.png)
Tab groups allow you to have many windows occupy the same footprint, similar to Yabai stacks but with browser-like tab behavior. This is useful when you want to have multiple pieces of reference information next to an editor, multiple tabs in different browser profiles, or, when you simply want multiple fullscreen views without the additional friction and overhead of creating a new workspace.

Unlike stack-only layouts, WinMux tab groups behave more intuitively like you would expect tabs to in browsers, and don't need a keyboard shortcut to activate. You can drag tabs from tab groups into another window's [intent zone](#managed-tiling-mode), or in between workspaces. You can also rearrange tab order within a tab group, and navigate through them with relative and absolute keybindings.

### Philosophy

#### Automatic tiling

WinMux tiles newly discovered windows by default. To keep their existing macOS size and position while still using WinMux's sidebar, workspaces, and manual layout commands, disable automatic tiling:

```toml
automatically-tile-new-windows = false
```

This applies to windows discovered when WinMux starts and windows opened later. You can still tile an individual floating window with `winmux layout tiling` or the configured `layout floating tiling` shortcut.

While dragging a window by its title bar, shake it horizontally to toggle between floating and tiling. The gesture requires several deliberate direction changes in quick succession, and does not activate during resize, sidebar, tab-strip, or tab-group drags. Disable it with:

```toml
enable-shake-to-toggle-tiling = false
```

#### Workspaces
You can NOT create workspaces that have no windows in them. Workspaces with no windows are automatically destroyed.

### Multi-Monitors
Monitors share the global project/workspace state. Each monitor can be treated as *independent* from each other. They each just use the sidebar to browse through projects and 'select' a workspace to view. 

Monitors can not be attached to the same workspace at the same time. They can be on the same project at the same time.

#### App Launching
WinMux supports single-modifer keybindings (e.g. triggering an action on press of `⌘`)

I highly recommend that you configure the apps you use every day to be launch with Left/Right Option+Command, or similar shortcuts, otherwise it might be hard to launch common things into the current workspace (and instead, take you to the other workspace where the app is currently active). Here is some of the apps that I have keybinded:

```toml
[mode.main.binding-tap]
    left-alt = 'exec-and-forget /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --profile-directory="Default"'
    right-cmd = 'exec-and-forget /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --profile-directory="Profile 1"'

[mode.main.binding]
    # Disable the native "Hide App" shortcut.
    cmd-h = []

    cmd-d = 'exec-and-forget osascript ~/Documents/scripts/launchTerminalWindow.scpt'
    cmd-e = 'exec-and-forget osascript ~/Documents/scripts/launchFinderWindow.scpt'
```

```applescript
# ~/Documents/scripts/launchTerminalWindow.scpt
tell application "cmux"
    if it is running
        tell application "System Events" to tell process "cmux"
            click menu item "New Window" of menu "File" of menu bar 1
        end tell
    else
        activate
    end if
end tell

# ~/Documents/scripts/launchFinderWindow.scpt
tell application "Finder"
    if it is running
        tell application "System Events" to tell process "Finder"
            click menu item "New Finder Window" of menu "File" of menu bar 1
        end tell
    else
        activate
    end if
end tell

```

## Installation
Download a published fork build from [alanzchen/winmux releases](https://github.com/alanzchen/winmux/releases).
Open its DMG and copy `WinMux.app` to `/Applications`. Install the included `bin/winmux`
launcher on your PATH for CLI access. The upstream Homebrew tap distributes upstream builds.

The fork release workflow requires your Developer ID Application certificate and Apple
notarization credentials; it publishes only after signature and notarization checks pass.
Older debug/ad-hoc DMGs are development builds and do not have this distribution signature.

Fork release builds use this repository's signed update feed. Automatic checks and installation
on quit are enabled by default; existing update preferences are respected. You can also select
**Check for Updates…** from the menu bar. The first migration from upstream or an older debug
build requires a manual installation to establish the fork's signing keys and paired CLI.

### Command-line client

WinMux includes an AeroSpace-style `winmux` client. The client and app communicate over a
local Unix socket and should normally come from the same installation. An incompatible socket
protocol is rejected before a command runs; differing app versions or Git revisions remain
diagnostic information rather than a protocol gate. A debug client talks only to
`WinMux-Debug`; use a release client with the installed `WinMux.app`.

For everyday commands, shell automation, project workflows, and the complete command index,
see the [CLI usage guide](docs/cli.md).

Build a universal release client without installing it:

```shell
make cli-release VERSION=<version>
.release/winmux --version
```

`make install VERSION=<version>` builds and installs the app and client as one versioned
pair under `.local/install/releases/`, updates `.local/install/current`, installs the app in
`/Applications`, and makes a launcher for that app's embedded client available at:

```text
.local/install/current/bin/winmux
```

Release builds also produce `WinMux-<version>-macOS.zip`, containing `WinMux.app`
and the `bin/winmux` launcher. The app contains the signed CLI, so the Sparkle app ZIP
updates both executables together. A local ad-hoc
build can be installed without the publishing key using:

```shell
make install VERSION=<version> CODESIGN_IDENTITY=- CODESIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= EXPECTED_CODESIGN_AUTHORITY_PREFIX=
```

To install the matched pair without launching WinMux or opening System Settings, add
`LAUNCH_AFTER_INSTALL=0`. This performs only the offline signature, architecture, archive,
and pair checks; run `make verify-installed` after a later launch.

macOS invalidates Accessibility approval when an ad-hoc signature changes. The installer
opens Privacy & Security > Accessibility when reapproval is required; enable WinMux there,
then relaunch the app and run `make verify-installed`. Until that command succeeds, the
installer reports the pair as installed but unverified rather than treating every launch
failure as an Accessibility problem. A previous app is preserved beside
`/Applications/WinMux.app` until the new client/server pair has been verified.

The command surface follows AeroSpace conventions, including `--help`, `--version`, query
commands with `--json`, explicit `--window-id` targeting, and nonzero exit status on command
errors. WinMux-specific commands add projects, tab groups, the sidebar, and the structured
agent workflow:

```shell
winmux list-windows --all --json
winmux list-workspaces --all --json
winmux agent skill
winmux agent query --path /tmp/winmux-agent.json
```

`agent check` and `agent apply` accept either `--path <path>` or explicit `--stdin`,
so deterministic shell transforms can keep the full freshness-guarded snapshot in a pipe:

```shell
winmux agent query | jq '<edit transformation>' | winmux agent apply --stdin
```

Implicit stdin is never consumed.

#### Socket protocol

Release builds listen on `/tmp/com.zimengxiong.winmux-${USER}.sock`; debug builds use
`/tmp/com.zimengxiong.winmux.debug-${USER}.sock`. All integers are four-byte unsigned values
in host byte order (little-endian on supported Macs).

Immediately after connecting, the client sends `SOCKET_PROTOCOL_VERSION` and the server
answers with its own `SOCKET_PROTOCOL_VERSION`. The current value is `1`. Either side stops
before processing a command when the versions differ. Once negotiation succeeds, each message
is a four-byte JSON byte length followed by that many UTF-8 JSON bytes. Ordinary commands send
one `ClientRequest` and receive one `ServerAnswer`; `subscribe` receives a stream of framed
events after its initial request.

Incoming JSON frames are limited to 128 MiB and are rejected from their length prefix before
payload storage is allocated. This is above the roughly 96 MiB worst-case JSON expansion of the
official CLI's 16 MiB UTF-8 stdin limit, with additional room for the request envelope.

The handshake is intentionally incompatible with the legacy pre-handshake socket. Upgrade or
roll back `WinMux.app` and `winmux` together. The client bounds negotiation so accidentally
connecting a new CLI to a legacy server reports an upgrade error instead of waiting forever.

### Release updates

Pushing a stable `vMAJOR.MINOR.PATCH` tag runs the signed release workflow. It builds a universal
app and embedded CLI with the pinned compiler, notarizes the app and DMG, signs the final
update archive with the fork's Sparkle key, and publishes all verified assets together.

The update feed is
`https://github.com/alanzchen/winmux/releases/latest/download/appcast.xml`.
The fork does not update the upstream Homebrew tap. See [release setup](docs/releasing.md)
for Apple account secrets, local build commands, and the one-time migration steps.
`make release VERSION=<version>` still builds locally by default; publishing requires explicit
`NOTARIZE=1 GENERATE_APPCAST=1 PUBLISH=1` and an existing version tag.

## Migrating
### From AeroSpace
If `~/.config/winmux/winmux.toml` already exists, WinMux uses it as-is.

If you have an AeroSpace config but no WinMux config yet, WinMux creates one for you on first launch. It copies over your AeroSpace shortcuts/key mapping and fills in the rest with WinMux defaults, including the sidebar and window tabs.

You do not need to edit anything to get started. After import, WinMux uses `~/.config/winmux/winmux.toml` and leaves your AeroSpace config alone.

If neither exists, WinMux creates a new WinMux config with the bundled defaults.

## Credits
[Aerospace](https://github.com/nikitabobko/AeroSpace)
