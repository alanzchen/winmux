# Repository Guidelines

## Project Structure & Module Organization

- `Sources/AppBundle/`: window management, commands, configuration, and sidebar/settings UI.
- `Sources/WinMuxApp/`: application entry point; `Sources/Cli/`: command-line client; `Sources/Common/`: shared types and protocol.
- `Sources/PrivateApi/` and `Sources/SparkleSupport/`: native accessibility bridge and updates.
- `Sources/AppBundleTests/`: tests grouped by subsystem. `test-fixtures/accessibility/` holds anonymized native regression captures.
- `resources/`: default TOML configuration, asset catalogs, and bundle metadata. `docs/` contains CLI and validation guides; `script/` contains build tooling. `ShellParserGenerated/` contains the generated parser package.

## Build, Test, and Development Commands

Develop on macOS with Swift **6.2.4**, pinned in `.swift-version`. Verify `swift --version`; use `swiftly run swift …` when managing toolchains with Swiftly.

- `swift build`: build the debug app and CLI.
- `swift test`: run the complete `AppBundleTests` suite.
- `swift test --filter WorkspaceSidebar`: run focused sidebar regressions.
- `make build`: generate version metadata and stage debug executables in `.debug/`.
- `make run ARGS="--config-path /absolute/path/test.toml"`: build and launch with an explicit configuration.
- `make cli ARGS="--help"`: build and inspect CLI usage.
- `python3 -B script/test_validate_appcast.py`: test appcast validation.

Release builds use Xcode via `make release VERSION=<version>`; SwiftPM executables are development builds.

## Coding Style & Naming Conventions

Follow surrounding Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Match subsystem filenames, including existing lowercase utility files. Preserve actor isolation, particularly `@MainActor` around UI and window state. Avoid unrelated formatting and generated-file changes.

`script/install-dep.sh` provides optional pinned SwiftFormat and SwiftLint binaries; no repository formatter/linter configuration is checked in.

## Testing Guidelines

Use XCTest with `*Test.swift` files, `XCTestCase` classes, and descriptive `test…` methods. Add behavior-focused regression coverage for fixes; run focused tests, then the full suite and build. No numeric coverage threshold is configured. For accessibility, focus, or multi-monitor changes, report native macOS smoke checks and any untested hardware scenarios. Anonymize captured fixtures.

## Commit & Pull Request Guidelines

Use concise imperative subjects, following history: `Fix compact sidebar multi-monitor controls (#19)`. Keep unrelated issues in separate commits. PRs should explain the problem, resulting behavior, linked issues, and validation; include screenshots for visible UI changes and disclose remaining native checks.

## Fork Compatibility

Preserve fork features when integrating upstream: sidebar layer settings, settings scroll retention, and CLI automation. Keep TOML and command behavior compatible, and distribute matching app/CLI versions. Check both fork branches and upstream before choosing a base; fork features may live outside `main`.

## Feature Delivery

Push completed feature changes to `codex/issue-fixes` or `main` after validation.
The automatic prerelease workflow tests, signs, notarizes, and publishes the app,
then advances the preview update feed. Check the workflow result and link the
prerelease when delivering a feature. Never replace published version assets or
manually move the feed backwards. Documentation-only changes do not trigger releases.
Use `make prerelease-local` for faster local signing and publication when credentials
are available; it keeps hosted CI as the fallback until publication succeeds.
