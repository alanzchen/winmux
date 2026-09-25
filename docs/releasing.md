# Signed fork releases and automatic updates

Fork preview builds check
`https://raw.githubusercontent.com/alanzchen/winmux/updates/prerelease.xml`.
Release archives use this fork's Sparkle Ed25519 key. The application and its embedded
CLI update together; the distributed `bin/winmux` launcher runs the CLI inside the
installed application.

## Supported architecture

New app and CLI builds target **Apple Silicon (`arm64`) only**, both locally and
on GitHub. `make build`, `make cli-release`, and `make release` select arm64
explicitly; release and installation checks reject Intel and universal app/CLI
executables. Sparkle generates an `arm64` hardware requirement in the update feed,
and publication checks require it so Intel Macs are not offered these updates.
Asset names and the preview feed URL stay the same. Earlier universal releases
remain unchanged.

## Local feature prereleases

Build, test, sign, and notarize on the local Mac. GitHub hosts the resulting
**prerelease** and update feed. Branch pushes, pull requests, tag creation, and
release publication must not start GitHub Actions automatically. Use
`make prerelease-local` when publication is authorized; it uploads verified
artifacts and atomically updates `prerelease.xml` on the `updates` branch.

Versions are numeric for Sparkle ordering: `.prerelease-version` supplies the
major/minor prefix, currently `0.6`. Local builds and explicitly requested hosted builds reserve the next patch
number using an atomic GitHub tag creation. Failed or cancelled builds can leave
gaps; their tags are never reused. Reruns never replace signed archives. Older jobs cannot
replace a newer published version or move the feed backwards. Increase the prefix
when starting a new version series.

The feed advances only after GitHub confirms all uploaded asset hashes. Failed
builds leave the previous update available. If publication succeeds but feed
promotion fails, rerun the local command to repair the feed from the verified published
appcast. GitHub's stable
`releases/latest` endpoint excludes prereleases, so it is not used for this channel.

Install a preview-channel build once to migrate from the earlier local `0.5.5`
builds, which point to the stable feed. Subsequent preview updates use Sparkle's
normal background checks and installation behavior; **Check for Updates** requests
an immediate check. User-disabled automatic updates remain respected. Downloading
source with `git pull` is not part of app updates.

## Build and publish locally

With the pinned Swift/Xcode toolchain and saved Developer ID, notarization, and
headless Sparkle credentials configured, run from a clean, committed integration branch:

```sh
make prerelease-local \
  CODESIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=N9YEGD9WDP \
  NOTARYTOOL_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
```

Xcode 27 bundles the pinned Swift 6.4.0, so no toolchain override is needed:
`script/setup.sh` then builds the tests and CLI with Xcode's compiler too, the same one
that builds the app. Remove any `TOOLCHAINS` line left in
`~/Library/Application Support/WinMux/ship.env` from the Xcode 26 setup. When the
selected Xcode bundles a different Swift than `.swift-version`, set `TOOLCHAINS` to the
pinned toolchain's identifier: `xcrun` then resolves that toolchain for the app, the tests,
and the CLI (setup.sh falls back to swiftly only when `xcrun swift` isn't the pin). Also set
`SWIFT_EXEC_MANIFEST=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc`.
This override path is untested since the move to Xcode 27. The standalone toolchain has
no `ld`, so without the manifest compiler `xcodebuild` fails package resolution with
error 74 after the tests pass, and that version number is lost. Application sources still compile with the pinned Swift.

The command pushes the reviewed commit, runs all tests, builds and notarizes
locally, uploads the verified release assets, and advances the
feed. Outputs stay in `.local/prereleases/vVERSION/`. It restores only its own
generated version files and refuses publication if source files change during the
build. Local Sparkle signing reads the protected file
`~/Library/Application Support/WinMux/ReleaseCredentials/sparkle-ed25519.key`
by default. Override it with `SPARKLE_PRIVATE_KEY_FILE`, or supply
`SPARKLE_PRIVATE_KEY` through your secret manager's environment. Do not set both.
The release never falls back to an interactive Sparkle Keychain request.

If a local build fails, fix it and rerun locally. There is no automatic hosted
fallback. Already-published commits reuse their verified release and can repair
its feed; they never replace published artifacts.

### Unattended previews: `make ship`

`make ship` publishes the committed `HEAD` of any checkout without anyone watching
the build. It checks that `HEAD` is `origin/main` or a fast-forward of it, takes a
repository-wide release lock, prepares the dedicated release worktree
(`~/Developer/winmux-worktrees/release`, detached at that commit), runs the signing
and toolchain preflight there, pushes `HEAD` to `main`, and starts
`make prerelease-local` in the background. It returns within seconds; a failed
preflight fails immediately instead.

```sh
make ship-check           # optional: everything up to the push, without releasing
make ship                 # or: make ship COMMIT=origin/main
make ship-wait            # blocks, then prints a short summary
make ship-status          # one line: phase and elapsed time (RUN=<id> for an older run)
```

`make ship-wait` exits 0 when the preview is published and verified, 1 when the
release failed, 2 when it is still running at the timeout (`TIMEOUT=<minutes>`,
default 60), and 3 when it was published but a post-publication check failed or
couldn't run, for example because GitHub was unreachable.

`make ship` pushes the commit to `main` before building, as delivery requires
anyway, so a failed release still leaves `main` advanced. A stopped or killed
release may also leave its version tag without a release; the next run takes the
next number. A release stopped while publishing may leave a draft or a published
release whose feed didn't advance; `make ship` again reuses and repairs it.

The release worktree is never edited by hand and never wiped: a run refuses if it has
changes other than version stamps left by a stopped release, which it restores along
with a stopped release's `.local/prerelease.lock`. It keeps its own build caches, so
its first release is a cold build and later ones are incremental. Other checkouts
and the sessions working in them are not touched. A new release waits until every
process of the previous one, including a killed runner's build, has ended; its error
says which process and how to wait for or stop it. A lock written before the Mac last
started is ignored. If a refusal names a process group that `ps -o pid,command -g <id>`
shows isn't a release, remove `winmux-ship.lock` from the repository's common Git
directory (`git rev-parse --git-common-dir`).

Local previews normally come from a checked-out integration branch. The release
worktree is detached instead and names its branch in `RELEASE_BRANCH`, which is
honored only when no branch is checked out. The non-forced push of `HEAD` to that
branch remains the containment: GitHub rejects anything but a fast-forward.

Each run keeps `status.json` (state, phase timings, tag, URL, checks), `summary.txt`,
and the full `log.txt` in the release worktree's `.local/ship/<run>/`; the last 20
runs are kept. After
publishing, the runner reads the release back from GitHub: a published prerelease,
assets matching the local build, the tag at the released commit, the preview feed
offering the version, and a notarized DMG. A failure names its phase (preflight,
tests, build, notarize, publish, verify) and the relevant log lines. The runner posts
a macOS notification when it ends; set `WINMUX_SHIP_NOTIFY` to also run a command of
your own, which receives the summary on stdin and `SHIP_STATE`, `SHIP_TAG`,
`SHIP_URL`, `SHIP_LOG`, and `SHIP_OK` in an otherwise minimal environment.

The documented signing identity, team, notarization Keychain, and pinned toolchain
are the defaults. Override them in the environment or in
`~/Library/Application Support/WinMux/ship.env` (`KEY=VALUE` lines, never secrets),
for example `TOOLCHAINS`, `WINMUX_RELEASE_WORKTREE`, or `WINMUX_SHIP_NOTIFY`.

Nothing depends on a particular coding agent. An agent starts `make ship`, runs
`make ship-wait` once (in the background if it can), and relays the summary; it
should not stream or poll the release log.

### Faster repeated builds

Reuse the same clean release checkout. Xcode keeps dependency checkouts and
compiler intermediates in `.local/release-cache/arm64/` across versions; it
rebuilds changed inputs. Archives, app/CLI packages, signatures and notarization
remain fresh and version-specific. SwiftPM's CLI build also reuses `.build/`.
This does not change release optimization settings or bypass source checks.

Override `RELEASE_DERIVED_DATA_DIR` for a separate cache or a fresh-build comparison.
Builds sharing a cache are serialized by a lock; a concurrent attempt fails clearly.
After an interrupted process, remove `.winmux-release.lock` inside that cache only
after confirming its build has stopped. To discard cached compilation, remove the
cache directory while no release is running. Moving to a new checkout may require
recompilation. Expected savings depend on the changes; notarization and upload
time are unaffected.

## Optional manual GitHub workflows

The workflow files accept only `workflow_dispatch`. They are also disabled in the
fork's settings, preventing automatic runs from older refs that still contain
event triggers. Enable and dispatch a hosted workflow only when the user explicitly
requests it; leave it disabled otherwise.
Disable the workflow again after dispatching the requested run; the accepted run
continues while new triggers remain disabled.

- `ci.yml`: tests and builds the selected ref, without signing credentials.
- `prerelease.yml`: manually publishes a preview from an integration branch.
- `release.yml`: manually publishes an existing stable tag. Choose a version newer
  than all previews and stable versions in the series. This uses the stable feed,
  `https://github.com/alanzchen/winmux/releases/latest/download/appcast.xml`.
- `update-homebrew-cask.yml`: an upstream-only manual cask update for a published
  stable tag; it is inactive in this fork.

Hosted build workflows use the [Apple Silicon `macos-26` runner](https://docs.github.com/en/actions/reference/runners/github-hosted-runners),
pin Xcode 27.0, and check its compiler against
`.swift-version` (6.4.0; `swift --version` prints it as 6.4). A missing Xcode version or compiler mismatch fails the run;
the workflow never silently switches toolchains.

## One-time account setup

In [repository environments](https://github.com/alanzchen/winmux/settings/environments),
configure the `release` environment to allow **tags matching `v*`** and the exact
branches **`main`** and **`codex/issue-fixes`**. Store credentials
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
setup. Local releases reuse the saved Keychain credentials; optional hosted runs
reuse the repository secrets. Renew expired or revoked credentials and retain the
existing Sparkle key.

### Headless local signing

Export the **existing** Sparkle key once using an authorized `generate_keys`
tool. This setup step can require Keychain approval; release builds do not invoke it:

```sh
credentials="$HOME/Library/Application Support/WinMux/ReleaseCredentials"
mkdir -p "$credentials"
chmod 700 "$credentials"
umask 077
/path/to/Sparkle/bin/generate_keys --account winmux-alanzchen \
  -x "$credentials/sparkle-ed25519.key"
chmod 600 "$credentials/sparkle-ed25519.key"
```

The credential file stays outside Git. Its contents are never passed on the
command line or printed. Release tooling validates permissions and key format,
passes the key to Sparkle over standard input, and suppresses signer error output
that could contain key material. An injected `SPARKLE_PRIVATE_KEY` is supported;
avoid storing the secret itself in shell history or a checked-in `.env` file.

Run `python3 -B script/sign-sparkle-update.py --check-credentials` to check setup.
Missing keys fail before reserving a preview version. Developer ID signing and
notarization reuse the already-authorized certificate and saved profile; their
Keychain must be unlocked before starting. A locked or missing Keychain fails
preflight instead of initiating an interactive unlock. Initial certificate access
authorization remains a one-time setup requirement.

### Background agent sessions

A background agent can report the login Keychain as locked even after the user
unlocks it in their desktop session. Check `launchctl managername`: the release
agent may run in `Background`, with a different audit session from the logged-in
desktop. Repeated desktop unlocks do not necessarily change that agent's access.

Run the **same, unchanged** signing preflight as a temporary, one-shot LaunchAgent
in `gui/<user-id>`. If it passes there, run `make prerelease-local` in that domain
from a clean checkout. Keep the pinned toolchain, signing identity, team, and
notarization profile explicit. This reuses the unlocked desktop session without
opening Terminal or a signing permission dialog.

Keep the temporary plist, runner, logs, and exit status under ignored `.local/`.
Use `RunAtLoad` without `KeepAlive`; do not install a persistent login item. Pass
only necessary environment values—never a Keychain password or private key. For
example, register and later remove the one-shot job with:

```sh
launchctl bootstrap "gui/$(id -u)" /absolute/path/release-job.plist
launchctl bootout "gui/$(id -u)/com.winmux.local-release.example"
```

Remove the job only after its runner has exited and publication has been checked.
If the GUI-domain preflight also fails, stop and request an unlock; never bypass
the checks or weaken Keychain settings. This workflow was verified for local
release 0.6.323 after a background-session preflight continued reporting locked.

## Publish a stable version locally

Choose a reviewed commit containing the fork features, issue fixes, and release
workflow. Use a new `vMAJOR.MINOR.PATCH` tag greater than every published preview or stable
version; prerelease and noncanonical tags are rejected.

```sh
git tag -a v0.7.0 -m "WinMux 0.7.0"
git push origin v0.7.0
make release VERSION=0.7.0 RELEASE_TAG=v0.7.0 \
  CODESIGN_IDENTITY="Developer ID Application" DEVELOPMENT_TEAM=N9YEGD9WDP \
  NOTARYTOOL_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" \
  UPDATE_FEED_URL="https://github.com/alanzchen/winmux/releases/latest/download/appcast.xml" \
  NOTARIZE=1 GENERATE_APPCAST=1 PUBLISH=1
```

Run the full Swift and release-tool tests before publication. Tag creation itself
starts no hosted build. The local publisher verifies signatures, notarization,
the arm64 app/CLI architecture, archive checksums, and uploaded asset digests.

A retry can replace an incomplete draft's assets. It cannot overwrite a published
release, move a tag, or make an older stable version the latest update.

Each release contains `WinMux-VERSION.zip` (Sparkle app archive),
`WinMux-VERSION-macOS.zip` (app, CLI launcher, and docs), `WinMux-VERSION.dmg`,
`appcast.xml`, and `SHA256SUMS`. Publishing requires an explicit local command;
pushes alone never publish a preview or stable release.

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

The setup key account is `winmux-alanzchen`. CI supplies
`SPARKLE_PRIVATE_KEY_FILE` and `NOTARYTOOL_KEYCHAIN`. Keep `PUBLISH=0` for local
verification; `PUBLISH=1` uses the same existing-tag and publication checks as CI.
Complete certificate authorization and unlock the signing Keychain before running
headlessly. Sparkle uses its protected file or environment key, and does not
request Keychain access during a build.
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

Validate local tests, Developer ID signing, and notarization before publishing.
Before calling the installed
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

The previous local package is
`.build/developer-id-validation-fe0962ab/WinMux-0.5.5.dmg`; it supersedes `a75368c9`.
It has not been published or installed. Live multi-monitor interaction, tagged CI
signing, and installed version-to-version updates remain unverified as described above.

### Clickable Dock icons build — September 16, 2026

Local WinMux **0.5.5**, built from `23b55258`, replaces per-app dots with one dot
under the active workspace number. Clicking a compact app icon selects a matching
window and raises it after layout; occupied workspaces keep the explicit Override
prompt and retain the selected app. The current window is preferred, followed by
the workspace's existing tree focus order.

All **176 focused tests**, **715 application tests**, the debug and universal
release builds, independent code review, and [CI](https://github.com/alanzchen/winmux/actions/runs/35163648568)
passed. Saved signing credentials were reused without a new approval prompt.
Apple accepted the app (`dd23f326-5612-4df5-b464-d22f834c9e4e`) and DMG
(`8a939e90-8c7f-45e7-a21a-676b36db797f`). Developer ID signatures, stapling,
Gatekeeper, the Sparkle signature, both ZIPs, the read-only mounted DMG, matching
universal app/CLI metadata, launcher, and checksums passed verification.

The previous local package is
`.build/developer-id-validation-23b55258/WinMux-0.5.5.dmg`; it supersedes `fe0962ab`.
It has not been published or installed. Live pointer/VoiceOver verification is
pending because the Mac was locked; detached rendering tests do not establish
input behavior. See [sidebar validation](sidebar-appearance-validation.md#dock-icon-actions).
The existing multi-monitor, tagged CI signing, and installed-update checks remain
outstanding.

### Local prerelease publication — September 16, 2026

[WinMux 0.6.302](https://github.com/alanzchen/winmux/releases/tag/v0.6.302),
from `8c118b82`, was built and published using `make prerelease-local`.
It includes the left-side active-workspace dot and single-window app-icon dragging.
All **720 application tests**, **64 release-tooling tests**, and the debug and
universal release builds passed. Saved signing credentials required no new prompt.
The first end-to-end local run took approximately **5 minutes 16 seconds** on this
Mac, including tests, notarization, and publication; this is one run, not a benchmark.

The command signed and notarized both the app and DMG, published all five assets,
advanced the public preview feed, then cancelled only the duplicate hosted release
job. Downloaded artifacts passed GitHub digest comparisons, Developer ID and
Gatekeeper checks, notarization-ticket validation, universal app/CLI and version
checks, both ZIPs, and a read-only mounted-DMG check. The downloaded update ZIP's
Ed25519 signature matched the app's embedded Sparkle public key.

A native Sparkle information-only probe discovered the update through the public
feed; the published 0.6.302 bundle also read its own embedded feed and correctly
reported itself up to date. No app was installed or replaced. Live pointer/drag,
VoiceOver, multi-monitor interactions, and an installed version-to-version update
remain unverified; the Mac was locked during this validation.

Local artifacts: `.local/prereleases/v0.6.302/`. Public-download verification logs:
`.build/prerelease-validation/`.

### Hosted fallback and update discovery — September 16, 2026

[GitHub Actions](https://github.com/alanzchen/winmux/actions/runs/35170717482)
independently built and published
[WinMux 0.6.304](https://github.com/alanzchen/winmux/releases/tag/v0.6.304)
from `311b0ceb`, with no local build for that commit. All **720 application tests**,
**64 release-tooling tests**, signing, notarization, packaging, upload verification,
and feed promotion passed. The hosted run took approximately **14 minutes**.

Public downloads passed the same package, checksum, and Sparkle signature checks
as 0.6.302. A native Sparkle information-only probe using the published 0.6.302
bundle's own embedded feed discovered **0.6.304** and its correct GitHub archive.
This verifies cross-version update discovery; actual installed-app replacement
and the live sidebar interaction checks above remain untested.

### Configurable Dock release — September 16, 2026

[WinMux 0.6.305](https://github.com/alanzchen/winmux/releases/tag/v0.6.305)
was locally built from `a1147d4f`, signed and notarized, then published to the
preview feed. Validation passed **731 application tests with one native-glass
rendering skip**, **64 release-tooling tests**, and the debug build. The independent
[build-and-test workflow](https://github.com/alanzchen/winmux/actions/runs/35174957425)
passed. The duplicate hosted prerelease was cancelled only after successful
publication; the stable-release signing job correctly skipped the preview tag.

All five public asset digests matched. Both ZIPs and the mounted DMG passed
Developer ID, notarization, Gatekeeper, universal architecture, app/CLI version,
and launcher checks. The public feed matched the released appcast, and the update
archive's Sparkle signature matched the embedded public key. The published
0.6.302 bundle discovered 0.6.305 through its own preview feed. No installed app
was replaced during verification.

Final native sidebar captures returned blank; live glass, hover, drag, and
multi-monitor checks remain outstanding as detailed in
[sidebar appearance validation](sidebar-appearance-validation.md).

### Dock hover and live settings release — September 16, 2026

[WinMux 0.6.307](https://github.com/alanzchen/winmux/releases/tag/v0.6.307)
was locally built from `08c18df6`, signed, notarized, and published to the preview
feed. It restricts magnification to the Dock, stabilizes workspace-number scaling,
publishes appearance changes immediately, and shows every workspace app icon.
All **733 application tests** passed with **one native-glass skip**; **64 release
tooling tests** and the independent
[CI build and tests](https://github.com/alanzchen/winmux/actions/runs/35176254525)
passed. The duplicate hosted prerelease was cancelled after publication.

Public asset hashes, both ZIPs, the mounted DMG, signing, notarization, universal
app/CLI versions, and the Sparkle archive signature passed verification. A native
Sparkle probe of the published 0.6.302 bundle discovered 0.6.307 using its embedded
preview feed. Native fixture captures confirm inside/outside magnification states;
live flicker, pointer, and settings interaction remain unverified because desktop
control timed out. No installed app was replaced by these checks.

## References

- [GitHub: importing Apple signing certificates](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
- [Apple: notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Sparkle: publishing an update](https://sparkle-project.org/documentation/publishing/)
- [Swift 6.2.4 and Xcode 26.3](https://forums.swift.org/t/announcing-swift-6-2-4/85050)
