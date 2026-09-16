# Signed fork releases and automatic updates

WinMux checks `https://github.com/alanzchen/winmux/releases/latest/download/appcast.xml`.
Release archives use this fork's Sparkle Ed25519 key. The application and its embedded
CLI update together; the distributed `bin/winmux` launcher runs the CLI inside the
installed application.

## Automated builds

`.github/workflows/ci.yml` tests and builds pushes to `main` and `codex/issue-fixes`
and pull requests. It has no signing credentials.

`.github/workflows/release.yml` runs on a pushed stable tag such as `v0.6.0`.
It runs all Swift tests and release-tool regressions, builds universal arm64/x86_64
executables, signs with Developer ID, notarizes and staples the app and DMG, then
signs the final update ZIP with Sparkle. The workflow validates signatures, bundle
metadata, architectures, archive checksums, and uploaded asset digests before
publishing a complete draft as the latest release.

Both workflows pin Xcode 26.3 on `macos-26` and check its compiler against
`.swift-version` (6.2.4). A missing Xcode version or compiler mismatch fails the run;
the workflow never silently switches toolchains.

## One-time account setup

In [repository environments](https://github.com/alanzchen/winmux/settings/environments),
configure the `release` environment to allow **tags matching `v*`**. Store credentials
there, not in the repository. Only release jobs use this environment.

| Kind | Name | Value |
| --- | --- | --- |
| Secret | `BUILD_CERTIFICATE_BASE64` | Base64 export of a **Developer ID Application** certificate and its private key (`.p12`). |
| Secret | `P12_PASSWORD` | Password protecting that `.p12` export. |
| Secret | `APPLE_ID` | Apple ID authorized to notarize for your developer team. |
| Secret | `APPLE_APP_SPECIFIC_PASSWORD` | App-specific Apple ID password for `notarytool`. |
| Secret | `SPARKLE_PRIVATE_KEY` | Text exported by Sparkle `generate_keys`, for the existing fork key. |
| Variable | `APPLE_TEAM_ID` | Your ten-character Apple Developer Team ID. |
| Variable | `SPARKLE_PUBLIC_KEY` | Base64 public key matching both the private key and the app's `SUPublicEDKey`. |

For example, upload an exported certificate directly without putting it in shell history:

```sh
base64 -i /absolute/path/DeveloperID.p12 | \
  gh secret set BUILD_CERTIFICATE_BASE64 --env release --repo alanzchen/winmux
gh secret set P12_PASSWORD --env release --repo alanzchen/winmux
```

The certificate must be a valid **Developer ID Application** identity for
`APPLE_TEAM_ID`; an Apple Development identity cannot replace it. The workflow
imports it into a temporary keychain, validates notarization credentials, and
removes credentials after the run. Do not add certificates, exported private keys,
or passwords to Git, build artifacts, issue comments, or chat messages.

The fork Sparkle key is stored locally under the Keychain account
`winmux-alanzchen`. Back up this key securely and retain it across releases.
Generating a new key for each build would break installed clients' update trust.
The `release` environment, Developer ID certificate, Apple notarization credentials,
and Sparkle key are configured. Local notarization uses the Keychain profile `winmux`.
Creating/exporting credentials and entering the app-specific password are one-time
setup. Tagged GitHub releases reuse these secrets without desktop prompts; renew
credentials when they expire or are revoked. Retain the existing Sparkle key.

## Publish a version

Choose a reviewed commit containing the fork features, issue fixes, and release
workflow. Use a new `vMAJOR.MINOR.PATCH` tag greater than every published stable
version; prerelease and noncanonical tags are rejected.

```sh
git tag -a v0.6.0 -m "WinMux 0.6.0"
git push origin v0.6.0
```

The tag push publishes automatically when validation succeeds. For a failed run,
rerun it in Actions. Once the workflow is on the default branch, manual dispatch
also works, but its selected ref and input must both identify the same existing tag:

```sh
gh workflow run release.yml --repo alanzchen/winmux --ref v0.6.0 -f tag=v0.6.0
```

A retry can replace an incomplete draft's assets. It cannot overwrite a published
release, move a tag, or make an older stable version the latest update.

Each release contains `WinMux-VERSION.zip` (Sparkle app archive),
`WinMux-VERSION-macOS.zip` (app, CLI launcher, and docs), `WinMux-VERSION.dmg`,
`appcast.xml`, and `SHA256SUMS`. No release is created merely by merging a branch.

## Local signing and first installation

With the same Developer ID identity and Sparkle key installed locally, save the
notarization profile **once** in the login Keychain:

```sh
xcrun notarytool store-credentials winmux \
  --keychain "$HOME/Library/Keychains/login.keychain-db"
```

For later builds, reuse that profile and its exact Keychain path:

```sh
make release VERSION=0.6.0 \
  CODESIGN_IDENTITY='Developer ID Application: Your Name (YOURTEAMID)' \
  EXPECTED_CODESIGN_AUTHORITY_PREFIX='Authority=Developer ID Application:' \
  DEVELOPMENT_TEAM=YOURTEAMID CODESIGN_STYLE=Manual \
  NOTARIZE=1 NOTARYTOOL_PROFILE=winmux \
  NOTARYTOOL_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
  GENERATE_APPCAST=1 PUBLISH=0
```

The default key account is `winmux-alanzchen`. CI instead supplies
`SPARKLE_PRIVATE_KEY_FILE` and `NOTARYTOOL_KEYCHAIN`. Keep `PUBLISH=0` for local
verification; `PUBLISH=1` uses the same existing-tag and publication checks as CI.
Local macOS Keychain access may still prompt for approval or unlocking. These
desktop prompts do not apply to the temporary Keychain and secret files used in CI.
For an existing profile in another Keychain, pass its original path; omit
`NOTARYTOOL_KEYCHAIN` for a profile saved in the default data protection Keychain.

Install the first signed fork build manually: quit WinMux, copy `WinMux.app` from
the DMG into `/Applications`, and replace any old standalone CLI with the supplied
`bin/winmux` launcher. From the mounted DMG or extracted distribution, **copy** the
launcher into a directory on your `PATH`:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 bin/winmux "$HOME/.local/bin/winmux"
```

Do not symlink the launcher into the extracted distribution: its adjacent app is
intentionally preferred for portable use and would remain separate from the
installed copy. For a custom app location set `WINMUX_APP_PATH` to the absolute
`.app` path. Subsequent Sparkle updates replace the installed app and embedded CLI together.
Upstream releases trust a different key/feed; old ad-hoc development DMGs do not
establish this fork's release trust. They cannot migrate automatically through this
new feed. Recheck macOS Accessibility permission after changing signing identities.

Validate local Developer ID signing and notarization before publishing. The first
tagged release must also pass the GitHub workflow. Before calling the installed
update path verified, install that build and update to a second signed version,
then compare the app and `winmux --version`.

## Validation of the release tooling

Local checks on September 15, 2026 passed: 649 application tests, 34 release-tool
tests, workflow lint, and shell syntax checks. The initial ad-hoc package passed
signature and metadata checks, but later native validation exposed a packaging
error: `Contents/MacOS/WinMux` and `Contents/MacOS/winmux` refer to the same file
on case-insensitive volumes. Those packages are superseded and must not be installed.
The CLI now lives in `Contents/Helpers/winmux`; packaging verifies distinct app/CLI
files and validates the CLI signature again after copying it outside the bundle.

Application sources used Swift 6.2.4. On the local Xcode 26.5 host, only package
manifest evaluation used Xcode's compiler through `SWIFT_EXEC_MANIFEST`, because
the standalone toolchain could not locate the linker during manifest evaluation.
CI uses Xcode 26.3's bundled Swift 6.2.4 throughout. A tagged GitHub signing run and
an installed version-to-version update remain separate validation steps.

### Developer ID validation — September 16, 2026

Local WinMux **0.5.5**, built from `8ea1daad`, passed distribution validation:

- Universal arm64/x86_64 app and separate embedded CLI signed with Developer ID
  Application for team `N9YEGD9WDP`; nested signatures and build metadata verified.
- Apple accepted the app and DMG; stapling and Gatekeeper assessment passed.
- The final Sparkle ZIP signature verified against the app's embedded public key.
- Both ZIPs and the mounted DMG passed app/CLI signature, architecture, version,
  notarization-ticket, launcher, and checksum checks. The DMG's Applications
  shortcut was also verified.
- The application suite passed **692 tests**, release tooling passed **42 tests**,
  and [CI passed for the build commit](https://github.com/alanzchen/winmux/actions/runs/35131911843).

Artifacts are in `.build/developer-id-validation-8ea1daad/`. No release was
published and no app was installed. The first tagged GitHub signing job and an
installed version-to-version Sparkle update remain untested. Native sidebar and
multi-monitor interaction checks are tracked separately in
[sidebar appearance validation](sidebar-appearance-validation.md).

### Dock-style sidebar build — September 16, 2026

Local WinMux **0.5.5**, built from `a75368c9`, includes the Dock-style workspace
number tiles and separators. It passed the same Developer ID, notarization,
stapling, Gatekeeper, Sparkle signature, universal app/CLI, ZIP, mounted-DMG, and
checksum checks listed above. Signing reused the saved credentials without a new
approval prompt. All **692 application tests** and the debug build passed;
[CI also passed for this commit](https://github.com/alanzchen/winmux/actions/runs/35149181819).

The previous local package is
`.build/developer-id-validation-a75368c9/WinMux-0.5.5.dmg`. It supersedes the
earlier local preview. It has not been published or installed; the tagged CI and
installed-update checks above remain outstanding.

### Dockset reference build — September 16, 2026

Local WinMux **0.5.5**, built from `fe0962ab`, adds the fixed 64-point Dockset-inspired
rail, centered content-fitting height, rounded glass, and running-app indicators.
The app and embedded CLI are universal. All **698 application tests**, the debug
build, independent code review, and [CI](https://github.com/alanzchen/winmux/actions/runs/35155610377)
passed. Real native preview captures and comparison details are in the
[sidebar validation guide](sidebar-appearance-validation.md#dockset-reference-comparison).

Developer ID signing reused the existing credentials without another approval
prompt. Apple accepted the app (`1dffc480-d9bf-4afd-be9f-e959b88abe75`) and DMG
(`e7ca3f8c-809e-469c-b88e-22b536e05269`). Stapling, Gatekeeper, Sparkle signature,
both ZIPs, the read-only mounted DMG, matching app/CLI metadata, launcher, and
checksums passed verification.

The current local package is
`.build/developer-id-validation-fe0962ab/WinMux-0.5.5.dmg`; it supersedes `a75368c9`.
It has not been published or installed. Live multi-monitor interaction, tagged CI
signing, and installed version-to-version updates remain unverified as described above.

## References

- [GitHub: importing Apple signing certificates](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Sparkle: publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Swift 6.2.4 and Xcode 26.3](https://forums.swift.org/t/announcing-swift-6-2-4/85050)
