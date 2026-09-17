# Repository Guidelines

## Project Structure & Module Organization

- `Sources/AppBundle/`: window management, commands, configuration, and sidebar/settings UI.
- `Sources/WinMuxApp/`: application entry point; `Sources/Cli/`: command-line client; `Sources/Common/`: shared types and protocol.
- `Sources/PrivateApi/` and `Sources/SparkleSupport/`: native accessibility bridge and updates.
- `Sources/AppBundleTests/`: tests grouped by subsystem. `test-fixtures/accessibility/` holds anonymized native regression captures.
- `resources/`: default TOML configuration, asset catalogs, and bundle metadata. `docs/` contains CLI and validation guides; `script/` contains build tooling. `ShellParserGenerated/` contains the generated parser package.

## Build, Test, and Development Commands

Develop on macOS with Swift **6.2.4**, pinned in `.swift-version`. Verify `swift --version`; use `swiftly run swift …` when managing toolchains with Swiftly.

- `swift build --arch arm64`: build the debug app and CLI.
- `swift test --arch arm64`: run the complete `AppBundleTests` suite.
- `swift test --arch arm64 --filter WorkspaceSidebar`: run focused sidebar regressions.
- `make build`: generate version metadata and stage debug executables in `.debug/`.
- `make run ARGS="--config-path /absolute/path/test.toml"`: build and launch with an explicit configuration.
- `make cli ARGS="--help"`: build and inspect CLI usage.
- `python3 -B script/test_validate_appcast.py`: test appcast validation.

Build only for Apple Silicon (`arm64`), locally and on GitHub runners. Release builds use Xcode via `make release VERSION=<version>`; SwiftPM executables are development builds. App and CLI architecture checks must reject Intel and universal binaries.

## Coding Style & Naming Conventions

Follow surrounding Swift style: four-space indentation, `UpperCamelCase` types, and `lowerCamelCase` members. Match subsystem filenames, including existing lowercase utility files. Preserve actor isolation, particularly `@MainActor` around UI and window state. Avoid unrelated formatting and generated-file changes.

`script/install-dep.sh` provides optional pinned SwiftFormat and SwiftLint binaries; no repository formatter/linter configuration is checked in.

## Testing Guidelines

Use XCTest with `*Test.swift` files, `XCTestCase` classes, and descriptive `test…` methods. Add behavior-focused regression coverage for fixes; run focused tests, then the full suite and build. No numeric coverage threshold is configured. For accessibility, focus, or multi-monitor changes, report native macOS smoke checks and any untested hardware scenarios. Anonymize captured fixtures.

## Commit & Pull Request Guidelines

Use concise imperative subjects, following history: `Fix compact sidebar multi-monitor controls (#19)`. Keep unrelated issues in separate commits. PRs should explain the problem, resulting behavior, linked issues, and validation; include screenshots for visible UI changes and disclose remaining native checks.

## Code Review Workflow

Before pushing substantive code changes, run independent, read-only reviews with
**Claude CLI (`claude-fable-5`)** and **agy CLI (`gemini-3.8-flash-high`)**. Provide
the diff, relevant surrounding code, requirements, and validation results. Ask for
concrete correctness, regression, performance, and test-coverage findings.
If headless file reads are denied, pass a scoped source bundle directly to the
reviewer instead of enabling unrestricted tool permissions.

Verify each finding against the code; fix supported defects and rerun affected
checks. Obtain targeted follow-up reviews for substantive fixes. Keep raw reports
under ignored `.local/reviews/` and summarize accepted findings and remaining
limitations in the delivery notes. Reviews supplement tests. If either reviewer
fails or is unavailable, disclose that before delivery; do not claim approval or
silently substitute a model. Documentation-only edits do not require both reviews.

Reviewers must not edit, publish, access signing credentials, or launch other
reviewers. Review completion does not authorize a release or GitHub CI run.

## Fork Compatibility

Preserve fork features when integrating upstream: sidebar layer settings, settings scroll retention, and CLI automation. Keep TOML and command behavior compatible, and distribute matching app/CLI versions. Check both fork branches and upstream before choosing a base; fork features may live outside `main`.

## Feature Delivery

Default to local builds and releases. Do not invoke GitHub CI automatically. Hosted workflows
are manual-only and disabled in the fork's settings; enable or dispatch them only
when the user explicitly requests a GitHub run.

Work directly on `main` unless the user explicitly specifies another branch.
After validation, push completed changes to that branch.
For authorized publication, use `make prerelease-local` to test, build, sign,
notarize, upload, and advance the preview feed from this Mac. A failed local build
must not trigger a hosted fallback. Verify the published assets and update feed,
and link the prerelease when delivering it. Never replace published version assets
or move the feed backwards.

## Headless Signing

Routine local releases must build, sign, and notarize without Keychain prompts.
Reuse the existing Developer ID certificate, `winmux` notarization profile, and
Sparkle signing key; credential provisioning is a separate one-time setup.

- The default Sparkle key is `~/Library/Application Support/WinMux/ReleaseCredentials/sparkle-ed25519.key`, outside Git. Keep it owned by the current user with mode `600` or `400`.
- Override with `SPARKLE_PRIVATE_KEY_FILE` or inject `SPARKLE_PRIVATE_KEY`; never set both. Never print secrets, put them in command-line arguments, or commit them.
- Preflight with `python3 -B script/sign-sparkle-update.py --check-credentials` and `python3 -B script/check-signing-keychain.py`.
- Missing credentials or a locked/unavailable signing Keychain must fail clearly. Do not fall back to interactive prompts or export keys during routine builds.

See [Headless local signing](docs/releasing.md#headless-local-signing) for setup and troubleshooting.
