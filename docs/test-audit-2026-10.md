# Code and test audit — October 2026

Audited fork `main` at `fc234d7b` with three subsystem agents and a separate harness/dependency pass. The clean checkout was fast-forwarded from `34d5cd78` after checking fork branches and upstream. No upstream changes were integrated by the audit.

## Removal standard

A low reference count was only a lead. Each removed production symbol had no live caller, no dynamic registration or serialization role, and a traced replacement or an isolated unreachable dependency graph. Tests that still described supported behavior were redirected to the live implementation. Tests were removed only when they exclusively exercised obsolete behavior or duplicated retained live-path coverage.

| Removed code | Proof | Coverage retained |
| --- | --- | --- |
| Unfinished `Shell.swift`, `ShellParserGenerated`, ANTLR dependency/tooling | `parseShell` has no production caller. The entire `ShellTest.swift` was commented out in `44c90e5f`. Config uses `parseCommand` → `splitArgs`; `exec-and-forget` passes the suffix to Bash. No other ANTLR consumer exists. | All active command/config/CLI tests; new raw Bash syntax preservation test. Deleting the comment-only shell test removes zero runnable tests. |
| Draft/internal/display-index workspace allocators | Production callers were replaced by numeric allocation in `3e295044`, `4a25d30c`, and `45f17f52`. Three remaining tests only exercised creation of obsolete draft names. | Current numeric/gap/reservation tests; legacy draft-name display and stale-label cleanup; old internal workspace-name command compatibility. |
| `preferredWorkspace`, `shouldShowWorkspaceInSidebar` | Live callers replaced by `availablePreferredWorkspace` (`c2635b88`) and `userFacingWorkspaces` (`ff1bec16`). | Real project switching and available-workspace assertions; existing persistent-empty-workspace test already exercises live filtering. |
| `pinnedDraggedWindowRect` | Last production use removed in `6520008a`. | Existing window/group geometry test; missing-window fallback test retargeted to `resolvedDraggedWindowAnchorRect`. Removed one redundant wrapper test. |
| `safariExtensionPairs` | Wrapper around `safariExtensionMatches(...).pairs`; all remaining callers were tests. | All 17 call sites migrated to the production matcher. No Safari/browser assertion or test removed. |
| Left-only hover-depth helper | Live panel switched to edge-aware `workspaceSidebarHoverDepth` in `6a296a37`. | Original depth boundary cases now exercise all three Dock edges, gaps, translated display origin and zero thickness. |
| `ClientRequest.command` | Always nil, never read or written, absent from `CodingKeys` and custom decoding. | Exact wire JSON, old/unknown-field decoding, absent versus null fields, and socket protocol compatibility tests unchanged. |
| `assertNotEquals`, `assertFail` | No callers after deleting the comment-only shell file. | All used assertions retained. |

Five runnable tests were removed: three obsolete draft-name allocator tests, one geometry wrapper test, and one sidebar visibility wrapper test. Both wrapper tests duplicate retained live-path coverage. The rest of the existing behavior checks were preserved or migrated.

## Bugs exposed by the audit

- Sidebar config writers failed to recognize commented table headers and could edit a child table's same-named project label. They could also mistake multiline value text for a table/key or end an array at a bracket inside a multiline string. The writer now respects real table/value boundaries and continues refusing unterminated arrays.
- `joinTruncating` appended an ellipsis when the last element fit exactly. Exact fits now remain unmarked; partial/omitted elements still indicate truncation. (The second pass later removed `joinTruncating` with its tests: its only caller built a tray suffix that nothing displays.)
- `parseCommand` and the settings canonicalizer accepted command-name prefixes such as `exec-and-forgetful`. Shared parsing now requires the exact command name followed by whitespace or the end of the string, preserving the Bash suffix verbatim.
- Topic inference could start after the total request deadline, or cache a late answer if timer delivery lagged. Regression tests use a manual clock and a delayed timer to test elapsed time independently of executor scheduling.

## Retained code and remaining audit work

Compatibility remains intentional: Safari v1 negotiation/fallback, old saved workspace names, socket version handling, AX fallback, persisted integration fields, and native test synchronization/reset seams all have current purposes. Release scripts named `ci-*` also support local publication and manual hosted workflows.

Further candidates needed a separate coverage migration before removal: `dockMagnificationPointer`, `closeWorkspaceSidebarSplitWindows`, `showsProjectName`, and `bestNewWindowMenuItemIndex` have test-only callers but their tests protect meaningful interaction or matching policy. The second pass migrated the first three; see below.

The opt-in real Apple Intelligence evaluation is observational: it prints expected groups without asserting them. It must not be counted as accuracy or latency acceptance coverage. Deterministic fake-provider policy/coordinator tests remain the automated behavioral checks. (The second pass made unavailable or zero-inference runs skip with a reason instead of passing.)

Static searches and successful tests do not prove the whole repository is free of unused code. This report claims only the scoped removals above.

## Validation

- Original baseline: `swift test --arch arm64` passed **2,825 tests, 10 skipped, zero failures**; Python discovery passed **134 tests**.
- New regressions against original production code: **40 tests with 20 assertion failures** across the four bug areas. Isolating the topic coordinator from retained singleton occupancy made both deadline defects fail deterministically (**2 tests, 2 failures**).
- Fixed-code focused run: **658 tests, zero failures**. Python discovery rerun: **134 passed**. Shell syntax checks and `git diff --check` passed.
- SwiftPM dependency graph contains no ANTLR or generated shell parser, and no other dependency versions changed. A before/after source-reference capture found 105 original references to removed symbols and none remaining.
- Final `swift test --arch arm64`: **2,832 tests, 10 skipped, zero failures**. `swift build --arch arm64` passed; `lipo -archs` reports only `arm64` for both app and CLI. CLI `--help` smoke check passed.
- Independent agy CLI review (`gemini-3.8-flash-high`) completed on the supplied diff/source bundle with **no actionable findings**. The source diff remained unchanged after review. Its general push/release recommendation does not satisfy the missing required Opus review or authorize a release.
- Required Opus 5.5 review through the `paseo-advisor` skill could not authenticate: its OAuth session expired and could not be refreshed. No review occurred and no substitute model was used. The repository requires this review before pushing substantive changes, so pushing the commits remains blocked until authentication is renewed and the review is completed.

Raw audit reports, red/green outputs, full logs, and reviewer reports are retained under ignored `.local/reviews/test-audit/`.

Native physical multi-monitor drag/focus, browser interaction, Liquid Glass composition, and actual Apple Intelligence model accuracy/latency require separate desktop checks. No release or GitHub CI run is part of this audit.

The 10 skips are unchanged from baseline: two native appearance previews, four opt-in Dock performance/input benchmarks, one Liquid Glass composition check, two opt-in real-model evaluations, and one focus-restoration check because this session cannot make its test windows key. No skip was added to hide an audit failure.

## Second pass — compiler-index audit (2026-10-19/20)

The first pass relied on text searches. The second pass started from the Swift compiler's own index store, which SwiftPM's debug build writes to `.build/out`. It covered every SwiftPM target, including the tests. Each definition was classified by exact symbol identity: overloads are distinct, and every reference records the symbol that contains it. Four categories came out: no references (with references from other dead code discounted transitively); referenced only by tests; stored properties written but never read; and test helpers nobody calls. Protocol witnesses whose conformance is declared in another file were mapped back to their requirements. The tooling (`indexdump.py`, `classify.py`, `refs.py`) is kept under ignored `.local/audit/` in the audit worktree.

The index produced 162 dead, 111 test-only and 43 write-only candidates, plus 4 dead test helpers. Ten read-only agents checked them: seven by subsystem, plus sweeps of test health, non-Swift code and assets, and the config/CLI surface. Each proposed removal or bug then went to two adversarial agents, one asking whether the code is still reachable or needed for compatibility, the other whether coverage would be lost or the fix is wrong. Of 155 proposals, one was refuted: the first `dockMagnificationPointer` migration targeted a path live input never takes. Eight more were declined by judgment (listed below). Implementation ran in nine isolated worktrees. Each group was built, tested on the focused classes it touched (test runs serialized under a lock), and reviewed by an independent agent before integration.

Removal standard: unchanged from the first pass, plus the blind spots the index cannot see. Those are string and selector lookups, synthesized Codable/Equatable/Hashable reads, `@State` read only through `$` bindings, code used only in release builds (`#if !DEBUG`), and the Xcode-only Safari appex. Examples of candidates kept for these reasons: `Command`'s default `==` (an Equatable witness), `FrozenTreeNode`'s Codable members, drop-target state bindings, and Sparkle's `AutomaticUpdates`, which the debug build doesn't reach.

### Bugs found and fixed

Each fix has a regression test, and each was shown to fail before the fix. Where the defect only appears in an environment this Mac doesn't have, a fault was injected temporarily to produce the failure, and the injection was not committed.

- **Shortcut recorder never cleaned up.** `ShortcutRecorderView.dismantleNSView` took `coordinator: ()` while the view declares a `Coordinator` class, so SwiftUI called the protocol's no-op default instead. Switching Settings panes while recording left MASShortcut's key monitor installed, kept global hotkeys suspended, and let the next keystroke rebind the shortcut. The fix makes it the real witness, stops recording, detaches the callbacks, and resumes hotkeys only if this recorder had suspended them.
- **"Menu bar style" did nothing.** Since 887e6177 the status item renders `MenuBarAppIcon`, which ignores this setting. The setting is removed, together with the unreferenced `MenuBarLabel` text label and the tray model that fed it. The binding-mode letter that label showed is not restored.
- **"Rectangle" shortcut preset could never be saved.** The preset itself was removed in 5708f8bf, so choosing it always failed with a "Not saved" error and blocked later Settings edits. The row is removed from Settings. The `shortcuts-preset` TOML key is still accepted, and `'rectangle'` still reports one targeted removal error, without the extra "specify 'main' mode" error it used to add. A new test saves every file-backed choice option.
- **Config error details stayed open after a fix.** The successful-reload path cleared a property nothing observes. A `.config` message type now marks config diagnostics, and a successful reload closes only those detail windows. Launcher, sidebar and Settings error details are left alone and no longer show the Reload/Open config buttons, which never applied to them. Settings' own save errors keep their Retry/Revert actions.
- **Rebrand left broken links.** The rebrand rewrote upstream AeroSpace links into `nikitabobko/WinMux` URLs that return 404, and version numbers WinMux never shipped. This affected the crash report link, the implicit-stdin CLI error, the floating-window resize error, and two deprecated-config errors. Upstream history now points at `nikitabobko/AeroSpace`, and crash reports point at this fork's issue tracker. A source-scan test prevents the bad link from coming back.
- **Inverted config error.** The split/flatten-containers error said split has no effect when normalization is *disabled*; it is the other way round.
- **Opt-in model evaluation passed without running.** It passed even when no inference ran (model unavailable or every call failing). It now skips with the reason. A real-model run on this Mac still executes and passes.
- **Core Audio permission test could not fail.** It passed even if the permission-free Core Audio read was refused. Production now reads the process list through a helper that returns the HAL status, and the test asserts `noErr` (skipping only when the audio HAL is not running).

### Removed or migrated

75 commits: 238 files changed, 843 insertions, 3,061 deletions. Production sources lost about 2,350 lines net. Highlights:

- Whole dead views and clusters: `MenuBarLabel` and its tray model, inline sidebar rename fields and state, unused marketing mockups, transient tab-group resize chrome, the tab-stack drop-destination search, the chrome group drag gesture, the drag cursor label path, project focus hold, and the launcher's unreachable failure state.
- Callbacks and parameters that were never invoked or read: project menu and rename callbacks, `isDestructive` menu flags, `focusedWorkspace` on the user-facing workspace checks, tab presentation parameters, Settings model state, write-only fields (`siteOrigin`/`pageRevision`, `PinPageExpectation.url`, Hookmark script traits, topic binding token, switcher focus flag, sidebar `showsStatusPills`). The `show-status-pills` TOML key is still accepted.
- Unused utilities: collection/sequence extensions, JSON/AX-dump helpers, `throwT`, `orAsync`, `sponsorshipPrompts`, a CLI-only branch in the diagnostic writer, and leftover AeroSpace build-tooling options in `script/install-dep.sh` and `script/setup.sh`.
- The Chrome extension's unused `storage` permission (extension version 1.1.1). The Safari extension, which uses session storage, is unchanged.
- Production helpers only tests used were removed, and their tests retargeted to the live API. Tests that need a fixture got it moved into the test target (`WorkspaceSidebarSnapshot.empty`, `ParsedCmd.cmdOrNil`, `WinMuxAny.apply`, `MonitorDescription.caseSensitivePattern`, a durable-workspace fixture). The three deferred first-pass candidates now go through live code: split closing through `closeWorkspaceSidebarTabs`, pager naming through `usesProjectChips`, and the Dock hit test through `workspaceSidebarDockContainsPointer`. That last one is the exact predicate native pointer input evaluates, extracted from the Dock host unchanged.

Tests removed (all others were kept, retargeted, or renamed with the same assertions):

| Test | Why obsolete | Coverage retained |
| --- | --- | --- |
| `StringExTest` (5 `joinTruncating` tests) | The function lost its only caller, an undisplayed tray suffix, and was deleted | none needed |
| `WorkspaceNamingTest.testTrayItemDisablesRawWorkspaceIconWhenDisplayNameIsCustom` | Asserted an icon only the deleted `MenuBarLabel` rendered | display-name tests remain |
| `MenuTrackingPointerMonitorTest.testStopDuringTracking…` and two `stop()` lines | `stop()` had no production caller; the monitor lives for the app's lifetime | live tracking, nesting and recovery tests; a new check that a restored monitor is removed by the next menu |
| `WorkspaceSidebarDragTest.testWorkspaceSidebarActivationBlocksWhileAnyWorkspaceIsEditing` | Tested a wrapper with no production caller | `testWorkspaceSidebarActivationRequiresNoEditAndNoDrag` asserts both cases on the live overload |
| `ShortcutSettingsConfigEditsTest.testReadModeBindingEntriesReadsSimpleScalarBindings` | Reader had no production caller | replaced by a live `updateModeBindingConfig` quoted-key test |
| `WorkspaceNamingTest.testProjectFocusHoldIgnoresNativeFocusFromOtherProject` | The hold was never set after 421ef341 | renamed `testNativeFocusFromAnotherProjectMovesLogicalFocus`, live assertions kept |
| `WindowTabsTestDragGeometry.testTabGroupResizeChromeFrameDerivesFromActiveWindowContentFrame` | Tested the inverse of a deleted resize-chrome helper | `testTabBarRectSpansTopOfGroupFrame` on the live tab-bar geometry |

### Kept deliberately (declined or retained)

- **`shouldHideOtherWindowsDuringMove`:** a parked switch that always returns false. Kept so move-time hiding can be turned back on in one line.
- **`bestNewWindowMenuItemIndex`:** its priority tests mirror the AX menu loop in `MacApp.pressNewWindowMenuItem`, which unit tests can't reach without a menu fake or refactor.
- **Low-value cleanups:** the config-bootstrap candidate list entry, the `updateModeBindingConfig` constant parameters, the optional `periphery` installer, the empty `AccentColor` colorset, AeroSpace-era `.gitignore` lines, and the unreferenced README media and marketing captures (upstream still references some of them).
- **Everything the first pass retained for compatibility is unchanged.**

### Second-pass validation

- Baseline at `c07080ee`: `swift test --arch arm64` passed **2,832 tests, 10 skipped, zero failures**; Python discovery passed **134 tests**.
- Bug red/green: each regression test failed before its fix and passed after it. The model-evaluation and Core Audio defects can't occur on a healthy Mac, so they were made to fail with temporary, uncommitted injected faults (an unavailable model; an invalid Core Audio selector). With a real model, the opt-in evaluation still runs and passes.
- Integrated `swift test --arch arm64`: **2,833 tests, 10 skipped, zero failures**. The 10 skipped tests are exactly the baseline's. Python discovery: **134 passed**.
- `swift build --arch arm64 --build-tests` produced the same 43 warnings as the baseline, with none new. `swift build -c release --arch arm64` passed, which also compiles the `#if !DEBUG` code the debug index can't see. `lipo -archs` reports only `arm64` for the app and CLI in both configurations. The CLI `--help` smoke check passed. `git diff --check` passed.
- Re-indexing the integrated tree found no new dead or test-only symbols. Every remaining dead candidate (16) has a recorded reason to keep it.
- Not covered by automated tests: native Settings shortcut recording while switching panes, the menu bar menu, Dock magnification on physical displays, and the Chrome extension 1.1.1 reload. Config-error details closing after a real reload is covered only at the seam: the regression test calls `closeConfigErrorDetails()` directly, so nothing pins the call in `reloadConfig`'s success branch. A non-dry reload in tests would run `syncStartAtLogin()`, which deletes plists under the user's `~/Library/LaunchAgents` and unregisters the login item, so it needs an isolation seam first (follow-up).
