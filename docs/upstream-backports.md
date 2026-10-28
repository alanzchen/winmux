# AeroSpace selective backports — issue #1

Implementation and source review dated 2026-10-28. Tracks [issue #1](https://github.com/alanzchen/winmux/issues/1). “Ported” below describes source implementation, not a claim of native validation. Issue #1 remains open pending [native validation and required reviews (#3)](https://github.com/alanzchen/winmux/issues/3).

## Rechecked baseline and fork heads

- WinMux `main`: `641e71d189dc19e4ca5cd44a6ae788d15dc209c8` (same as issue baseline).
- Rechecked inherited WinMux `bf8c7a95` and upstream `13b35332`: both have tree `5148fad70e205661a0a3ed03f1bd341d7ae1d056`, so the review range is appropriate despite different commit identities. Latest reviewed release remains `v0.21.3-Beta` (July 16); ports are selected from source, not release-note feature counts.
- AeroSpace `main`: `74a1bf17e82d70e0a21945ba04bb4f590bf19f83` (same as issue baseline; October 1). `git rev-list --count 13b35332..74a1bf17` is 214. Reviewed commit subjects for the full range, then inspected diffs for correctness/performance/compatibility changes beyond the named ports.
- Fork branches fetched and inspected without switching the worktree: `feature/configurable-sidebar-layer` = `a1719026c689422e040d7ab8f0d9dbfae80bafdb`, `updates` = `cc8bfbb70833cebdc4b47874a65a28ddd40a9f03`, `codex/issue-fixes` = `bb56e56d97361a93d4fb62b85739ad39141c502c`.
- All three branch trees are older/divergent from current main and would delete hundreds of current fork files if substituted wholesale. Main already has configurable `stayOnTop` layer application in `ui/sidebar/WorkspaceSidebarPanel.swift`, settings pane retention in `ui/settings/SettingsScrollRetention.swift`, first-class CLI automation commands (e.g. `TriggerBindingCmdArgs`, agent commands), and matching app/CLI protocol handling. Keep main as the base; do not merge those old trees.

## Reliability and bounded feature dispositions

Upstream links use `https://github.com/nikitabobko/AeroSpace/commit/<hash>`.
Implementation links below refer to the adapted WinMux source and focused regressions.

| Candidate / upstream commit | Disposition | Implementation, regressions, and compatibility notes |
| --- | --- | --- |
| Invalid zero AX window IDs — `0f6b2e78` | Ported | [AX converters](../Sources/AppBundle/util/accessibility.swift), [registry guard](../Sources/AppBundle/tree/AxWindowRegistry.swift), [AxWindowIdentityTest](../Sources/AppBundleTests/util/AxWindowIdentityTest.swift). Preserve original AX errors; only explicit invalid-element results establish death. Successful zero IDs remain unknown and cannot register. |
| Registration latch ordering / bounded wait — `1e6ce27e`, `269dc71b` | Ported | [MacApp](../Sources/AppBundle/tree/MacApp.swift), [latch registry](../Sources/AppBundle/util/AppRegistrationLatches.swift), [regressions](../Sources/AppBundleTests/util/AppRegistrationLatchesTest.swift). Clear PID before waking waiters; one wait returns the attempt result. Retain `attempted`, AX timeouts and fast handle; later calls may retry failures. |
| AX teardown — `dd6b927a` | Ported with adaptation | [Worker queue](../Sources/AppBundle/runLoop.swift) closes admission, cancels pending continuations and requests loop stop. MacApp destroys all four guarded wrappers on the owner after `CFRunLoopRun` returns. Running jobs cancel cooperatively. [AxAppWorkerTest](../Sources/AppBundleTests/util/AxAppWorkerTest.swift) exercises queued/new/running work. Actual app termination remains in #3. |
| Secondary-display menu-bar clicks — `cfd4eab2` | Ported | [GlobalObserver](../Sources/AppBundle/GlobalObserver.swift) requires mouse location inside the clicked monitor's visible rectangle. Sidebar-drop guard and pointer/drag cleanup remain. Native desktop/menu/drop checks with both separate-Spaces settings remain in #3. |
| Config read / UTF-8 errors — `a0f17f88` | Ported | [readConfig](../Sources/AppBundle/config/parseConfig.swift) returns explicit failures; existing reload failure path retains live configuration and URL. No-custom-config bundled defaults remain supported. [ConfigReadTest](../Sources/AppBundleTests/config/ConfigReadTest.swift) covers missing files, directory, invalid UTF-8 and live-state preservation. |
| Outlook reminders — `a60f9630` | Ported | [Popup classification](../Sources/AppBundle/model/AxUiElementWindowType.swift) excludes non-normal Outlook windows. |
| Codex pet windows — `cb347265` | Ported | Same classifier excludes non-normal Codex windows. |
| Emacs child frames — `97897690` | Ported | Same classifier excludes Emacs `AXFloatingWindow` child frames regardless of focus/main status. |
| Wispr Flow overlays — `d56e1637` | Ported | Same classifier excludes non-normal Wispr windows across activation policies. All four app ports retain attached-transient/file-picker protections. [AxAppPopupTest](../Sources/AppBundleTests/model/AxAppPopupTest.swift) and [eight reduced upstream native records](../test-fixtures/accessibility/upstream-app-popups.json) include ordinary-window eligibility; current file-picker fixtures remain. |
| Empty/background workspace layout, root targeting — `bb1e5429`, `11ba9150`, `91064acc` | Ported | [LayoutCommand](../Sources/AppBundle/command/impl/LayoutCommand.swift), [arguments](../Sources/Common/cmdArgs/impl/LayoutCmdArgs.swift), [LayoutCommandTest](../Sources/AppBundleTests/command/LayoutCommandTest.swift). Empty workspaces accept container layout changes. `--workspace NAME --root` changes the background root without focusing it. Window-mode requests still require a window; Browser Tabs still disallows tab groups. |
| Idempotent layout / `--fail-if-noop` — `b5f9e443` | Ported | Unchanged layout now exits 0. One target with `--fail-if-noop` restores failure status 1. Documented in [CLI guide](cli.md#windows-layouts-and-tab-groups). Existing generic CLI error codes retained. |
| Fullscreen focus/move guards — `ea897997` | Ported | [Focus](../Sources/AppBundle/command/impl/FocusCommand.swift), [move/cache helper](../Sources/AppBundle/command/impl/MoveCommand.swift), [FullscreenGuardTest](../Sources/AppBundleTests/command/FullscreenGuardTest.swift). Optional WinMux/native fullscreen guards precede mutation. Directional focus-only flags preserve DFS/tab selector behavior. Explicit move-window targeting checks the selected tab before moving its group. Native queries use event-invalidated cache with observation tokens. |
| Avoid unrequested title reads — `63e0976b`, `25ccedf4` | Ported | [ListWindowsCommand](../Sources/AppBundle/command/impl/ListWindowsCommand.swift), [ListWindowsTest](../Sources/AppBundleTests/command/ListWindowsTest.swift). Title-free text/JSON sorts by app name then numeric ID, making output deterministic without AX title reads. Requested/default titles still read and sort by app/title/ID. Count skips titles. |
| Next-window mode — `d080afe4` | Ported with scoped adaptation | [NewWindowIntents](../Sources/AppBundle/tree/NewWindowIntents.swift), [routing](../Sources/AppBundle/tree/saved/SavedWorkspaceRouting.swift), [regressions](../Sources/AppBundleTests/tree/NewWindowIntentTest.swift). One preference per workspace identity, expires after 8 seconds. A new launch captures it under existing app/PID/expiry/preexisting-window/placement checks. Ordinary new regular windows consume before callbacks, apply mode after callbacks/placement while keeping destination/native state. Saved/restored/auxiliary/startup windows do not consume it. Cancellation discards captured mode. Retargeting refreshes the scope and preserves original first-seen cutoff. This replaces upstream's indefinite global override deliberately. |
| First Accessibility approval — `fb8b1df6` | Ported with adaptation | [Permission waiter](../Sources/AppBundle/util/AccessibilityPermission.swift) runs before config/hotkeys; tray shows waiting state and Settings action, then startup resumes on first grant. Never reset TCC. [Permission tests](../Sources/AppBundleTests/AccessibilityPermissionTest.swift) cover waiting/prompt/cancellation; [termination regressions](../Sources/AppBundleTests/StartupTerminationTest.swift) protect prior session persistence until runtime readiness while restoring partially managed native windows on quit. |
| Automatic config reload | Already covered | [ConfigFileWatcher](../Sources/AppBundle/config/ConfigFileWatcher.swift); preserve existing atomic reload, settings edits and watcher behavior. |
| Event subscriptions | Already covered | [SubscribeCmdArgs](../Sources/Common/cmdArgs/impl/SubscribeCmdArgs.swift) and existing WinMux-specific events; no replacement. |

## Investigated defects and changes made

### Floating restoration — ported, upstream 649301b2875b6eec23abda9b24bc765eecd37bf1

The inherited issue is established by the source despite WinMux's actual-frame preference: first `parkInCorner` reads the resized native frame, then `HiddenWindowParking.park` normally returns `.unconfirmed`, which invalidates `lastKnownActualRect`. Native move events may also invalidate it. An immediate `restoreFromCorner` then clamps using stale `lastFloatingSize`. A floating window resized smaller near the right/bottom edges is moved away from those edges.

Updated only `CornerParking.swift`: capture the just-observed `windowRect.size` into `lastFloatingSize` when the window is floating and the initial unhidden position is recorded. Tiled windows retain their saved floating size. Added `HiddenWindowReparkTest.testResizedFloatingWindowRestoresAtBottomRightWithoutAnActualFrameCache` (repeat park/restore with no actual frame cache) and `testParkingATiledWindowDoesNotReplaceItsSavedFloatingSize`.

### Floating directional focus — ported with adaptation, upstream 8c3efca2650e084945f27c018326579469afcb00

WinMux's `findIn` chooses the tab group's active child. The temporary insertion logic previously put a floating window immediately beside that child, so focusing down from a middle tab could jump to the floating window before later tabs. Adapted the upstream accordion boundary rule to `.tabGroup`: a floating window is inserted before all tabs or after all tabs based on its geometric side. `.tiles` behavior stays unchanged. After navigation it is rebound to the workspace as before.

`FocusCommandTest.testFloatingFocusDoesNotInterruptTabGroupOrder` uses a fixed simulated monitor and native frames: focus the middle tab, then down reaches the last tab before the lower floating window. It also verifies restoration of the group's original children and the floating relation. Coordinated the scoped `FocusCommand.swift` helper edit with the fullscreen agent; their guard changes at the start of `run` are intact.

### Swap MRU — already covered, upstream 19b5999d0dc2105c1e6e6478399a7cb8a7b9d95d

`swapNodes` reads `node2.ownIndex` correctly and explicitly marks `node1` most recent. Ported upstream's useful MRU assertions across existing directional/DFS/wrapping/swap-focus regressions in `SwapCommandTest.swift`; no runtime change required.

## Additional relevant range candidates

| Upstream candidate | Disposition | Evidence / reason |
| --- | --- | --- |
| `6021c13c` rectangle/point distance boundary | Already covered for the reported adjacent-display assignment defect | `CGPoint.monitorApproximation` first selects a display whose half-open `rect.contains(self)` is true, before distance fallback. This avoids choosing the neighboring display at its exclusive right/bottom edge. The general distance helper retains its inherited metric; do not rewrite unrelated floating positioning based on a monitor bug already prevented. |
| `fe039317` monitor rearrangement stability | Intentionally different | WinMux `WorkspaceMonitorAssignment.rearrangeWorkspacesOnMonitors` matches physical display identities first, then exact points for all displays, then proximity, and separately reserves saved workspace homes. The upstream old-to-new nearest assignment must not replace those project/saved-home semantics. Current exact-point reservation already prevents the reported new-screen stealing an exact old match. |
| `a8241641` summoning visible workspace source monitor | Already covered | `activateWorkspaceOnMonitorPreservingSourceViewport` places a project-aware fallback workspace on the source display before moving the workspace. This is stronger than the upstream stub workspace fix. |
| `747e1a97`, `9727340`, `f486beb2`, `987d1bd7`, `b95537f4` focus follows mouse | Intentionally different | WinMux does not expose upstream's new focus-follows-mouse feature. Keep its pointer/drag/sidebar interactions; those upstream feature-specific fixes are not missing fixes for an enabled WinMux mode. |
| `8b236f1b` fatal error termination deadlock | Deferred to [#2](https://github.com/alanzchen/winmux/issues/2) | `dieT` can block a main-thread semaphore while the termination task requires the main actor. Upstream changes the termination protocol to synchronous, adds dedicated blocking AX access, and alters quit/signal handling. Requires separate design preserving WinMux Dock shutdown, saved-state flush, frozen-world restart, and bounded worker shutdown. |
| `dd61a340` workspace callback target environment | Deferred to [#2](https://github.com/alanzchen/winmux/issues/2) | `onWorkspaceChanged` sets `WINMUX_WORKSPACE` while copying configured process environment, so an inherited `WINMUX_WINDOW_ID` may coexist. Adopt upstream's unambiguous window/workspace target selection together with callback/session compatibility tests, not a wholesale focus/session refactor. |
| `b22ecbd8` detected-window callback target | Already covered | `WindowDetectedCallbacks.onWindowDetected` runs callbacks with `.defaultEnv.copy(\.windowId, window.windowId)`, targeting the detected window rather than the focused one. |
| `8413641c` protocol version handshake | Already covered | `Common/util/NWConnectionEx.swift` implements protocol version exchange, a deadline for old servers, bounded payloads, and orderly EOF handling. CLI errors explicitly require matched app/CLI installations. |
| `b8e8dbb9`, `63df921c` explicit stdin handling | Already covered for supported commands | CLI resolves stdin only for opted-in agent requests and relative workspace commands, honoring `--no-stdin`. New eval-only stdin behavior is part of the shell migration decision below. |
| `5ad04a78`, `f99f89ba` parse/usage exit code 2 | Already covered | `Cli/_main.swift` uses `cliUsageOrParseErrorExitCode = 2`; behavior-failure compatibility remains as current WinMux. |
| `4e240fed` startup crash after TaskLocal refactor | Intentionally different / not applicable | WinMux did not adopt the upstream TaskLocal/session refactor that introduced the crash. Keep current startup/session semantics. |
| `6a2a126d`, `310bd8e5` filtered relative workspace navigation | Intentionally different | Preserve current tested project-aware relative navigation (WorkspaceCommandTest and MoveNodeToWorkspaceCommandTest). Changing which end is chosen when the current workspace is absent is a separate CLI compatibility choice. |
| `ecfc7454`, `a085c3d7`, TaskLocal/session refactors | Intentionally different | WinMux has its own refresh coalescing, cancellation, browser/tab presentation and placement confirmation. Do not mechanically replace command/callback cancellation or session state. |
| `3da1831`, `eaa5aeb9`, typed/interpolation/parser refactors, toolchain/CI changes | Intentionally different | These are implementation/tooling changes, not independent missing runtime fixes. Preserve the fork's Swift 6.4/Xcode 27 arm64 build, manual CI policy, command model and generated help pipeline. |

## Explicit compatibility migration decisions

The issue explicitly permits recording a decision instead of creating a follow-up for these larger changes. The following are intentional compatibility decisions for this delivery:

- **Shell/callback language (`790e1222` and dependent `eval`/`echo`/`test`/pipes/boolean operators/callback changes): intentionally different.** Retain WinMux's current config version, command sequences, project/agent commands, custom binding semantics, callback/session behavior and generic exit codes. Adopting a shell runtime changes config execution and requires a versioned migration proposal. Do not advertise upstream shell syntax as supported.
- **TOML 1.1 / TOMLDecoder (`16a0b634`): intentionally different.** Keep TOMLKit for parsing and GUI config editing. A parser-only replacement would not supply GUI edit round trips or preserve all current configurations; a future migration must include both parsers and editors with fixtures for comments, inline tables, arrays and GUI saves.
- **Nonfatal warnings / partially invalid config (`890ec336`, `61f0eac9`): intentionally different.** Keep config reload atomic: errors reject the new configuration and retain the live one. Introducing warnings must not silently adopt upstream's separate partial-invalid-config behavior. Do not add a no-op `--warnings-as-errors` flag without a warning diagnostic model.

## Validation

`git diff --check` passes for the shared working tree at this audit. Native tests were not run: this executor is Linux and has no Swift, Xcode, AppKit, macOS window server, or Accessibility services. The new tests are source-level regressions pending `swift test --arch arm64 --filter 'HiddenWindowReparkTest|FocusCommandTest|SwapCommandTest'`, then the full arm64 suite and build. [#3](https://github.com/alanzchen/winmux/issues/3) tracks native validation, external review availability, and hardware smoke checks. This source audit does not claim native reproduction or cross-provider reviewer approval.

### Checks performed in this environment

- `git diff --check`: passed.
- Popup fixture JSON decoding: passed; 8 anonymized records with upstream provenance.
- Tree-sitter Swift grammar comparison across changed/new Swift files: no new grammar errors relative to baseline. Existing unsupported grammar is ignored; this does **not** type-check Swift or validate concurrency isolation.
- `python3 -B -m unittest discover -s script -p 'test_*.py'`: 134 tests, 127 passed, 5 skipped, 2 failed. Both `test_ship.RunnerTest.test_a_group_that_exits_on_sigterm_is_not_kept_waiting` and `test_stopping_the_release_stops_its_whole_process_group` fail the process-group-alive assertion here. Both failures reproduced on an untouched `git archive` of the baseline scripts; no release script changed. Publication messages in these tests are mocked, not actual releases.
- `swift --version`: unavailable (`swift: command not found`). Focused regressions, full `swift test --arch arm64`, and `swift build --arch arm64` remain unrun. This Linux executor cannot run AppKit/window-server/Accessibility/display smoke checks.
- Supplemental independent read-only source reviews covered AX lifecycle, title/fullscreen paths, config/startup, and layout/launch integration. Accepted findings fixed startup persistence before runtime readiness and retargeted-intent layout scope, observation timing, and native-state preservation; targeted source rechecks followed. Raw reports are retained under ignored `.local/reviews/`.
- Required cross-provider Paseo/Opus 5.5 skill/profile and `agy gemini-3.8-flash-high` CLI are unavailable in this environment. Supplemental agents do not replace those reviews or establish approval; #3 tracks them.

No GitHub CI was dispatched and no release was built or published. Native display/hardware scenarios, queued AX app termination, project/launcher/browser-tab flows, live settings and CLI/agent compatibility remain explicitly unverified under #3.

## Review corrections

The subsequent review found three interactions in the next-window integration:

- Saved-title routing may return without placement while waiting for a title. Those windows now leave the next-window preference untouched; a regression follows the saved placement and checks that the next fresh window receives the mode.
- Native-state reopens now retain their restore exclusion until active frozen restores finish, under the existing claim timeout/cancellation policy. Completion preserves their actual native location without focus, and stale snapshots retain the native state rather than putting them back into the tiling tree. Regressions cover a suspended AX restore, different actual destinations, minimized windows, deferred native transitions, and subsequent restores.
- Cold scripted launches reserve their mode when the launcher accepts the choice, before launch/session settling. The one-use reservation keeps its app/workspace identity and original observation cutoff; cancellation/failure discards it. An empty reservation also prevents capturing a newer preference armed during the wait. Regressions cover slow launch, expiry, unrelated windows, preexisting windows, PID checks and cancellation.

Targeted independent source rechecks and `git diff --check` were performed for these fixes. Swift grammar checks do not replace compilation. Focused `SavedWorkspaceRoutingTest`, `PinReopenRestoreRaceTest` and `NewWindowIntentTest`, the complete arm64 suite/build, native smoke checks, and required external reviewers remain pending under #3 because the implementation environment is still Linux without Swift/macOS or those reviewers.
