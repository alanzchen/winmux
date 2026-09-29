# Local development

Use macOS, an Apple Silicon Mac, Xcode 27, and **Swift 6.4.0**, pinned in `.swift-version`.
Xcode is required: the tests use XCTest, and SwiftUI builds need the macro plugins in
Xcode's macOS platform.
Verify `swift --version` before building. If you use Swiftly, run commands through
`swiftly run swift …` to select the repository's toolchain.

Read [AGENTS.md](../AGENTS.md) for repository structure, coding conventions,
testing, and review requirements.

## Build, run, and test

Run from the repository root:

```sh
swift build --arch arm64
swift test --arch arm64
swift test --arch arm64 --filter WorkspaceSidebar
```

The first command builds development executables; the next two run the complete
suite or focused Sidebar tests. All local and hosted builds target `arm64` only.

The Makefile generates version metadata and stages debug executables in `.debug/`:

```sh
make build
make run ARGS="--config-path /absolute/path/test.toml"
make cli ARGS="--help"
```

Use an explicit test configuration when trying layout changes. Debug clients
connect to `WinMux-Debug`; use the matching release client with an installed
`WinMux.app`. SwiftPM executables are development builds, not release bundles.

## Build an app and matching CLI

Release bundles use Xcode. Replace `<version>` with the version you want to build:

```sh
make release VERSION=<version>
```

This builds locally without publishing by default. Developer ID signing requires
your certificate and team configuration; see the [release guide](releasing.md).
The output includes the app, its embedded CLI, a DMG, and a portable
`WinMux-<version>-macOS.zip` containing `WinMux.app` and `bin/winmux`.

The app embeds the WinMux Tabs Safari extension (`Sources/SafariExtension`), and only a
Developer ID–signed build with your team can talk to it. To try the extension, build with
`DEVELOPMENT_TEAM` and a Developer ID identity, move the app into `/Applications` (Safari can't
read a bundle elsewhere in your home folder), and open it once so Launch Services registers the
extension. Safari 27.0 lists an extension that isn't notarized only after **Settings › Developer ›
Allow unsigned extensions**, which Safari turns off each time it quits. Don't register the extension with `pluginkit -a` on its own: Safari 27.0 crashes
at launch loading an extension whose app Launch Services doesn't know. The extension's scripts
can be exercised without Safari in `SafariExtensionTest` (JavaScriptCore) and, for the
background script's lifecycle, with a fake `browser` object in Node.

To build only the release CLI:

```sh
make cli-release VERSION=<version>
.release/winmux --version
```

## Install a local build

```sh
make install VERSION=<version>
```

The installer builds the matching app/client pair, keeps versioned copies under
`.local/install/releases/`, updates `.local/install/current`, and installs the app
in `/Applications`. The CLI launcher is available at:

```text
.local/install/current/bin/winmux
```

That launcher targets the installed app's embedded client, so later app updates
also update the CLI it runs. A previous installed app is preserved beside
`/Applications/WinMux.app` until the new pair is verified.

For a local ad-hoc build without a Developer ID certificate:

```sh
make install VERSION=<version> CODESIGN_IDENTITY=- CODESIGN_STYLE=Manual \
  DEVELOPMENT_TEAM= EXPECTED_CODESIGN_AUTHORITY_PREFIX=
```

Changing an ad-hoc signature can require renewed Accessibility approval. The
installer opens the relevant settings when needed. Enable WinMux, relaunch it,
and run `make verify-installed` to check the app/client pair.

Add `LAUNCH_AFTER_INSTALL=0` to install without launching the app or opening System
Settings. This performs offline checks only; after launching later, run:

```sh
make verify-installed
```

## Publish a release

Publication is a separate step. The [release guide](releasing.md) covers
`make prerelease-local`, saved headless signing credentials, notarization, and
update-feed verification. GitHub builds are manual-only; pushes do not start CI.
