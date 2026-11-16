# Upstream AeroSpace sync

WinMux is a fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace). This document is the procedure and the plan for
merging upstream losslessly: real `git merge`s of upstream history, with WinMux's features coupled to the upstream core
through a small set of marked hooks instead of edits spread through upstream files.

Status (2026-11-15): phase 0 is on `main`, including the history join (`e9012cc0`, merge base `13b35332`). Phase 1 shipped as
v0.6.419 Preview (`8ef3e860`), phase 2 as v0.6.420 Preview (`3d18b9be`, native smoke of the GlobalObserver hooks passed). S1 is in review on `upstream/s1-20261115`. Background analysis (module map, coupling inventory, merge-cost measurements) lives in
`.winmux-diagnostics/upstream-integration-20261115/REPORT.md` outside the repository.

## The model

Every path in the last merged upstream tree has exactly one class in [`script/upstream/manifest.tsv`](../script/upstream/manifest.tsv):

| Class | Meaning | What a merge does |
|---|---|---|
| `pristine` | Byte-identical to upstream. | Merges as is. Any WinMux edit is a guard error. |
| `hooked` | Upstream lines untouched. The only additions are lines marked `// WINMUX-HOOK(name)`, or blocks between `// WINMUX-HOOK-BEGIN(name)` and `// WINMUX-HOOK-END(name)`. | Merges as is unless upstream edits the lines next to a hook. The hook line is then re-applied. |
| `forked` | WinMux owns the file. Budget: at most 10 non-test `Sources/` files at the end of phase 3. | Conflicts are expected. Port the upstream diff by hand and log the decision. |
| `deleted` | WinMux removed it. Globs are allowed, so new upstream files under a dropped tree (docs site, `axDumps/`, `.github/`) are dropped too. A `moved-to=` note means the content lives on elsewhere and must be ported by hand. | Auto-resolved by `resolve-deleted`. |
| `winmux-only` | Not an upstream path. This is the default for anything absent from upstream. | A report entry if upstream ever adds the same path. |

The manifest's `target` column records the class each file should reach by the end of phase 3. The guard prints the
pending transitions as a progress count.

`script/upstream/state.json` records the upstream URL, the fork point, and `upstream_base`: the last upstream commit merged
into WinMux, against which the guard compares.

## Tooling

`script/upstream-sync.py`. Tests: `python3 -B script/test_upstream_sync.py`. These run with the release's
`unittest discover`, use synthetic repositories only, and need no network.

| Command | What it does |
|---|---|
| `fetch` (`make upstream-fetch`) | Fetches upstream `main` into `refs/remotes/aerospace/main`, plus the recorded base, without adding a remote or changing git config. Note that this repository's remote named `upstream` is ZimengXiong's fork, not AeroSpace. |
| `guard [--advisory] [--rev R]` (`make upstream-guard`) | Checks every upstream path against its class at `R` (default `HEAD`; the manifest is read from the same revision). Exits 1 on errors unless `--advisory`. |
| `report [--upstream REF] [--out F]` (`make upstream-report`) | Covers what upstream changed since `upstream_base`: per-file action by class, a dry-run merge (`git merge-tree` with the recorded base), conflicts by class, and the commit list. |
| `merge [TARGET] [--allow-main]` | Writes the report to `.local/upstream-sync/`, then runs `git merge --no-ff --no-commit TARGET` with `rerere.enabled` and `rerere.autoUpdate` on. Auto-resolves deletions and prints the remaining conflicts by class. |
| `resolve-deleted [--dry-run]` | Run during a merge. Drops upstream edits to deleted paths (following upstream renames) and new upstream files under deleted globs. Leaves `moved-to` paths with a `PORT` line. |
| `finish [--no-commit]` | After resolving: records `MERGE_HEAD` as `upstream_base`, adds manifest rows for new upstream files, reclassifies rows whose state changed, then commits with rerere. |
| `manifest [--base REV]` | Adds rows for unclassified upstream paths and refreshes pristine/forked/deleted classes from the tree. |
| `history-join [--execute --allow-main --trailer T]` | Prints, or runs with checks, the one-time history join below. |

**Rerere.** It is enabled per command (`git -c rerere.enabled=true -c rerere.autoUpdate=true`) inside `merge` and `finish`,
not in the shared repository config. Turning it on repo-wide would change merges in every agent's worktree. The resolution
cache lives in the common `.git/rr-cache`, so every worktree that syncs through the tool reuses it.

**CI.** `.github/workflows/upstream-guard.yml` is manual-only, like every hosted workflow here, and advisory
(`continue-on-error`). Locally, `make upstream-guard` is the check. It becomes blocking (drop `--advisory`) at the end of
phase 2, once no forked file is waiting for its hooked transition.

## Phase 0: history join (one time, on `main`)

WinMux's import rewrote upstream's first 1,508 commits. WinMux `bf8c7a95` has the same tree as upstream `13b35332` (tree
`5148fad7`) under a different id, so git computes a 2023 merge base, and a plain merge shows 207 add/add conflicts. A no-op
merge records the true ancestry and changes no files.

Run in the main checkout once the liveness Preview has shipped and the coordinator says go:

```sh
git switch main && git pull --ff-only origin main
python3 -B script/upstream-sync.py fetch
python3 -B script/upstream-sync.py history-join --execute --allow-main \
  --trailer "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
# The script checks: both fork commits present, identical trees, HEAD descends from bf8c7a95,
# clean tree, tree unchanged after the merge, merge base with upstream = 13b35332.
git diff --name-only HEAD^1 HEAD            # must print nothing
git merge-base HEAD refs/remotes/aerospace/main   # 13b35332c9d4dab571e3ceec38c6905cd1a0bb39
git push origin HEAD:main
```

Effects:
- No file and no build output changes. Nothing derives versions from commit counts (`makefile` uses the hash only).
- `git rev-list --count HEAD` grows by 1,509.
- The push uploads upstream's history objects to the fork.
- `git log` and `git blame` on `main` start showing upstream commits.
- GitHub's generated release notes list pull requests, so they are unaffected. A "Full Changelog" compare link spanning the join lists the upstream commits once.

The join does not need its own Preview. The next phase candidate carries it.

Rehearsal in a scratch clone (2026-11-15, WinMux `c676ddac` + AeroSpace `6ed6af62`):
- The join left the tree unchanged, and the merge base became `13b35332`.
- `merge --allow-main` of upstream HEAD hit 316 conflicts and auto-resolved 208 deleted paths: 181 conflicts plus 27 new upstream files under deleted globs.
- 135 conflicts remained: 121 forked, 2 forked files that upstream renamed, 7 deleted-but-moved ports, 3 WinMux copies of moved upstream files, and 2 add/add collisions (`AppBundleTests/command/LayoutCommandTest.swift`, `Common/util/ArrayEx.swift`).
- Rerere recorded 124 preimages. The merge was then aborted.

## Phase 1: noise reduction (behavior-neutral)

Goal: shrink WinMux's diff in upstream files without changing behavior, so later merges and hook extraction work on real
differences. Every item ships only if the full suite stays green, `make upstream-guard` reports no new errors, and the
CLI golden outputs (below) are byte-identical.

1. **Branding by value, not by identifier.** Restore upstream identifiers: `AeroAny`, `AeroObj`,
   `JSONEncoder.aeroSpaceDefault`, `aeroSpaceAppId`/`aeroSpaceAppName`, the `AEROSPACE_*` Swift constant names,
   `duringAeroSpaceStartup`. Keep WinMux values in `Common/appMetadata.swift` plus a new winmux-only `Common/branding.swift`
   (`cliName`, `appDisplayName`, `envPrefix`, `configDirName`, socket path).
   - Restore `Sources/AeroSpaceApp/` as the directory name, with the `WinMuxApp` product name set in `Package.swift`/`project.yml`.
   - Export both `WINMUX_*` and `AEROSPACE_*` to `exec-*` children. This is additive: new environment variables only.
   - Keep `during-winmux-startup` and accept `during-aerospace-startup` as an alias.
2. **Never move upstream code.** Move these back into their upstream files: `relayoutWindow`, `onWindowDetected`/`tryOnWindowDetected`,
   `unbindAndGetBindingData…`, focus-after-close, `hideInCorner`/`unhideFromCorner`, `AxWindow`/`getOrRegisterAxWindow`,
   `MacApp.setFrame`, `keysMap.swift`, the `parseConfig.swift` → `Toml*.swift` split, and the `HotkeyBinding` split. WinMux
   additions stay in WinMux files and are reached through the call sites phase 2 turns into hooks. Restore
   `ui/{MessageView,NSPanelHud,VolumeView,SecureInputView}.swift`, `mouse/resizeWithMouse.swift` and
   `Cli/subcommandDescriptionsGenerated.swift` at their upstream paths. WinMux variants become extensions in winmux-only files.
3. **Registries instead of shared switches.**
   - Revert `cmdManifest.swift` to upstream's kind switch, with WinMux commands added as marked lines.
   - Replace the `canSkipPostCommandRefresh` switch in `Command.swift` with a per-command property (WinMux commands set it in their own files).
   - Move WinMux help strings next to each command's arguments, out of `cmdHelpGenerated.swift`.
4. **One field per config.** Move the WinMux `Config` fields behind `var winmux = WinMuxConfig()`, with parsers in one
   `winmuxConfigParsers` dictionary merged into `configParser` on one marked line.
5. **Hotspot files last.** `tree/MacApp.swift`, `tree/MacWindow.swift`, `layout/refresh.swift` and
   `tree/frozen/closedWindowsCache.swift` are touched only after the liveness fix is on `main`, and only with rebased,
   behavior-neutral moves.

New tests:
- **CLI golden outputs.** Add `Sources/AppBundleTests/upstream/CliGoldenTest.swift`, a deterministic test world (existing
  `TestWindow` fixtures). It records `list-windows/workspaces/monitors/apps/projects --format/--json`, `config`, `--help`
  and error texts and exit codes, and compares them against checked-in golden files.
- **Persisted-state round trips.** Add tests over the frozen world, saved workspaces, sidebar pins and window rules,
  loaded from fixtures written by the current release.
- **Config corpus.** Parse `resources/default-config.toml`, `resources/default-window-rules.toml` and new synthetic
  configs in `test-fixtures/config/` with the same diagnostics.

User-visible risk: none intended. Possible regressions are a wrong brand string (caught by golden outputs) or the new
`AEROSPACE_*` variables appearing in `list-exec-env-vars` (documented).

Exit: one reviewed candidate, approved by both Astra and Carbon, shipped as a Preview.

### Phase 1 outcome (candidate on `upstream/phase1-20261115`)

Done:
- Golden outputs (`Sources/AppBundleTests/upstream/UpstreamSyncGoldenTest.swift`, fixtures in `test-fixtures/upstream-sync/`, recorded on `e9012cc0`).
- Branding by value: items 1 and 3, plus the `Config.winmux` field (item 4).
- Relocated files and functions restored (item 2 in part: `relayoutWindow`, the window-detected callbacks, `AxWindow` and its registry, eight files at their upstream paths).
- WINMUX-HOOK markers on the 14 upstream files whose WinMux diff was purely additive.

Manifest:

| | Before | After |
|---|---|---|
| pristine | 93 | 97 |
| hooked | 0 | 14 |
| forked | 151 | 143 |
| forked non-test `Sources/` | 119 | 111 |

Conflicts in a dry-run merge of upstream HEAD (`6ed6af62`): 317 → 311 overall, and 7 → 1 moved files needing a hand port. Content conflicts in `Sources/` stay at 114 files, with 340 → 337 hunks; the remaining ones come from behavioral changes, which phase 2's hooks address.

Deferred, because each is not behavior-neutral or belongs with a later slice:
- Exporting `AEROSPACE_*` alongside `WINMUX_*`, and the `during-aerospace-startup` alias: adds environment variables and accepts a new config key. Moved to S5 with D3.
- Undoing the `parseConfig.swift` → `Toml*.swift` and `HotkeyBinding` splits: S2 ports the config parsers to TOMLDecoder anyway.
- Restoring `Sources/AeroSpaceApp/` as the app directory: the release Xcode project (`project.yml`) names `Sources/WinMuxApp`. Done with phase 2 so the release build can be exercised on a candidate.
- `NewWindowBinding`, focus-after-close and corner parking: these are WinMux logic replacing upstream bodies, so they become phase 2 hooks (`newWindowBinding`, `focusAfterClose`, `hide`/`unhide`), not moves.

## Phase 2: hooks

Goal: every WinMux insertion in an upstream file becomes a named hook call, and every upstream file reaches its target
class. The guard becomes blocking at the end.

### Layout

WinMux's hook code lives in `Sources/AppBundle/WinMux/` (winmux-only, same module). The module boundary is not the unit of
isolation: moving WinMux into its own target would need `package`/`public` on hundreds of upstream declarations, which is
far more diff in upstream files than hooks. Each hook call site in an upstream file is one marked line, or a marked block
when it has to return early:

```swift
WinMuxHooks.didSetEnabled(newState) // WINMUX-HOOK(didSetEnabled)
// WINMUX-HOOK-BEGIN(frameWrite)
if case .skip = WinMuxHooks.frameWrite(self, rect: rect, kind: .layout) { return }
// WINMUX-HOOK-END(frameWrite)
```

Hooks are static functions on `enum WinMuxHooks` (`Sources/AppBundle/WinMux/Hooks/WinMuxHooks.swift`). A call site runs exactly
the code that stood there before, so nothing is installed at startup or in tests. This replaces the swappable
`WinMux.hooks` registry first planned: the registry's only extra was running upstream's own tests against upstream
behavior, and it cost an install step that could be forgotten. A *replacement hook* answers instead of an upstream body
and is marked `WINMUX-HOOK-REPLACES(name)`:

```swift
// WINMUX-HOOK-REPLACES(runCmdSeq)
if true { return try await WinMuxHooks.runCmdSeq(self, env, io) } // WINMUX-HOOK(runCmdSeq)
<upstream body, unchanged and not executed>
```

Upstream edits to such a body merge without conflict but don't take effect. The sync report therefore lists every upstream
change to a file with a replacement hook as **REVIEW**, so it gets ported into `WinMuxHooks`.

### Per-object extension state

Instead of more stored properties on upstream classes, each core class gets one marked field:

```swift
var winmux = WindowMeta() // WINMUX-HOOK(windowMeta)        in Window
var winmux = WorkspaceMeta() // WINMUX-HOOK(workspaceMeta)  in Workspace
var winmux = MonitorMeta() // WINMUX-HOOK(monitorMeta)      in Monitor (tree node, after slice 7)
var winmux = AppMeta() // WINMUX-HOOK(appMeta)              in MacApp
var winmux = AxWindowMeta() // WINMUX-HOOK(axWindowMeta)    in AxWindow (AX-thread confined)
```

The structs live in winmux-only files and hold:

| Struct | Contents |
|---|---|
| `WindowMeta` | frame-fit state, native-state cache and its token, placement stamp, first-seen time, liveness absences |
| `WorkspaceMeta` | §Side tables below |
| `MonitorMeta` | §Side tables below |
| `AppMeta` | frame-write barrier and ledger, fast-timeout handle, transient-focus flag |
| `AxWindowMeta` | browser tab scanner and observation, `WindowFrameFit` |

### Hook list

All hooks are `@MainActor` unless noted. "Policy" hooks return a decision and are mutation-checked: each one gets a test
that fails when the WinMux implementation is replaced by the default.

Lifecycle events (fire-and-forget):

| Hook | Call site (upstream file: function) | Replaces WinMux code at |
|---|---|---|
| `startup(_ phase: StartupPhase)` (`.beforeConfig`, `.afterConfig`, `.beforeFirstRefresh`, `.didFinish`) | `initAppBundle.swift: initAppBundle` | saved store/sidebar/link loaders, `MonitorConfigurationObserver`, `MCPServer.appDidStart`, saved app relaunch |
| `configDidReload(_ config: Config)` | `ReloadConfigCommand.swift: reloadConfig` | sidebar/tab strip/MCP/window rules fan-out |
| `appActivated(pid: pid_t)` | `GlobalObserver.swift: onNotif` | aux-window activation, wake re-park |
| `installEventMonitors()` | `GlobalObserver.swift: initObserver` | drag/key/wake monitors, sequence bindings |
| `appWillDestroy(_ app: MacApp)` | `MacApp.swift: destroy` | saved runtime and pin cleanup |
| `workspaceWillGarbageCollect(_ workspace: Workspace)` | upstream's unused-workspace GC | drop `WorkspaceMeta` indexes; empty-tab and project retention rules via `keepsWorkspace` below |
| `windowDidRegister(_ window: Window)` | `MacWindow.swift: getOrRegister` | lifecycle log, aux recording, floating presentation |
| `windowWillUnregister(_ window: Window)` | `MacWindow.swift: garbageCollect` | pin sync/forget, aux registry, lifecycle log |
| `nodeDidBind(_ node: TreeNode, oldParent: NonLeafTreeNodeObject?)` / `nodeDidUnbind(_ node: TreeNode, from: NonLeafTreeNodeObject)` | `TreeNode.swift: bind`, `unbindIfBound` | frame-fit relation, placement stamp, empty-tab lifecycle, move log |
| `focusDidChange(_ focus: LiveFocus)` | `focus.swift: setFocus` | focus generation, aux focus note |
| `workspaceDidActivate(_ workspace: Workspace)` | `focus.swift: focusWorkspace` | sidebar edge-trap suppression |
| `sessionWillBegin(_ event: RefreshSessionEvent) -> RefreshSessionScope` / `sessionDidEnd(_ event: RefreshSessionEvent)` | `refresh.swift`: session entry/exit | perf recorder, focus snapshot, floating presentation task-locals |
| `modelDidNormalize()` | `refresh.swift: refreshModel` | stack→tab migration, pin compositions, workspace reconciliation |
| `windowsDidEnumerate()` | `refresh.swift: refresh` | saved listing end, persisted frozen world, aux link recovery |
| `layoutWillBegin()` / `layoutDidEnd()` | `refresh.swift`: around `layoutWorkspaces` | sidebar/tray/launcher/tab strip model updates (post-layout snapshot bus) |
| `axNotification(_ name: String, app: MacApp, windowId: UInt32?)` | `refresh.swift: refreshObs` | native-state cache invalidation, focus-event counter |

Policy hooks:

| Hook | Call site | Default | WinMux policy |
|---|---|---|---|
| `newWindowBinding(_ window: MacWindow, default: BindingData) async -> BindingData` | `MacWindow.swift: getOrRegister` | `default` | intents, pin-page wait, aux float, open in new workspace, tab-group MRU |
| `windowDetected(_ window: Window) async -> WindowDetection` (`.runCallbacks` / `.handled`) | before `onWindowDetected` | `.runCallbacks` | persisted world restore, saved-workspace routing, empty pin |
| `liveness(_ evidence: WindowLivenessEvidence) -> WindowLifeStatusDecision` | `MacApp.swift: refreshAndGetAliveWindowIds` | upstream's status | the liveness evidence table (§Liveness) |
| `isWindow(app: MacApp, windowId: UInt32, subrole: String?) -> Bool?` | `AxUiElementWindowType.swift: isWindowHeuristic` | `nil` (upstream heuristic) | open/save panel, attached transient, Mail aux role |
| `reservedInsets(_ monitor: MonitorInfo) -> EdgeInsets` | `MonitorEx.swift: visibleRectPaddedByOuterGaps` | `.zero` | sidebar width per display side |
| `layoutContainer(_ container: TilingContainer, _ rect: Rect, _ context: inout LayoutContext) async -> Bool` | `layoutRecursive.swift`: `.accordion` case | `false` (upstream accordion) | tab groups: tab-bar inset, active child, park the rest |
| `layoutWorkspace(_ workspace: Workspace, _ context: inout LayoutContext) async -> Bool` | `layoutRecursive.swift: layoutWorkspace` | `false` | fullscreen tab |
| `rootLayout(_ workspace: Workspace) -> Layout?` | `WorkspaceEx.swift: rootTilingContainer` | `nil` | Tabs mode → `.tiles` |
| `frameWrite(_ window: Window, rect: Rect, kind: FrameWriteKind) -> FrameWriteDecision` (`.write(Rect)` / `.skip`) | `Window.setAxFrame`, `layoutRecursive` window case | `.write(rect)` | frame-fit target, reuse skip, drag gate, ledger |
| `didWriteFrame(_ window: Window, requested: Rect, kind: FrameWriteKind)` | after the AX write | none | frame-fit follow-ups |
| `hide(_ window: MacWindow, corner: OptimalHideCorner) async -> Bool` / `unhide(_ window: MacWindow) async -> Bool` | `MacWindow.swift: hideInCorner/unhideFromCorner` | `false` | confirmed-park state machine |
| `keepsWorkspace(_ workspace: Workspace) -> Bool` | upstream's unused-workspace GC | `false` | durable, saved, pinned, and retained-after-project-move workspaces |
| `focusAfterClose(_ window: Window, parent: NonLeafTreeNodeObject) -> LiveFocus?` | `MacWindow.swift: garbageCollect` | `nil` | multi-candidate focus, close tab with last window |
| `workspaceForMonitor(_ monitor: Monitor, candidates: [Workspace]) -> Workspace?` | `Monitor.swift`/`WorkspacesContainerEx.swift`: visible workspace choice and stub creation | `nil` | project-preserving per-display choice |
| `matchMonitors(old: [Monitor], new: [MonitorInfo]) -> [Int: Int]?` | `Monitor.swift: rearrangeMonitors` | `nil` (closest point) | display identity keys |
| `mouseMoved(_ window: Window) -> Bool` / `mouseResized(_ window: Window) -> Bool` / `mouseUp() -> Bool` | `moveWithMouse.swift: movedObs`, `resizeWithMouse.swift: resizedObs`, `resetManipulatedWithMouseIfPossible` | `false` | drag/resize engine |

Registries (one marked line each in upstream files):
- **Commands:** `cmdArgsManifest.swift` and `cmdManifest.swift`, one line per WinMux command.
- **Config sections:** `winmuxConfigParsers`.
- **Format variables:** `format.swift` stays forked until upstream's format refactors settle.
- **`ServerEventType` additions:** project and tab events for `subscribe`.
- **AX jobs:** `runAxJob(_ app: MacApp, windowId: UInt32, _ body: @Sendable (AXUIElement, inout AxWindowMeta) -> T) async -> T?` covers browser tabs, close button, New Window menu, pin-page reads and the MCP debug read.

Expected forked set after phase 2 (non-test `Sources/`; listed in the manifest `target` column):

| File | Why it stays forked |
|---|---|
| `layout/refresh.swift` | coalescing scheduler and requirement-gated session |
| `layout/layoutRecursive.swift` | parking and staleness inside the layout pass |
| `normalizeLayoutReason.swift` | native-state cache |
| `config/HotkeyBinding.swift`, `config/Mode.swift` | tap and sequence bindings |
| `Common/cmdHelpGenerated.swift` | help for WinMux flags |
| `Common/util/NWConnectionEx.swift` | socket timeouts and frame cap |
| `Common/util/commonUtil.swift` | refresh events and requirements |
| `command/format.swift` | project and workspace format variables |

Coalescing and the socket timeouts are candidates to propose upstream; if accepted, those files drop out of the forked set.

Tests: the full suite stays green after every step. Each policy hook gets a mutation check. The guard runs strictly
(`guard` without `--advisory`) and must pass. The CLI golden outputs stay identical.

User-visible risk: low to medium. Hooks change call order in a few places: sidebar model updates, focus side effects, and
startup phase boundaries. Timing-sensitive behavior (sidebar flicker, focus after close, parking) gets a Golden Gate VM
smoke pass with synthetic windows, and the VM is stopped afterwards.

Exit: guard strict and green, one reviewed candidate (Astra and Carbon approve), Preview.

### Phase 2 as implemented (candidate on `upstream/phase2-20261115`)

**Hooks and their behavior-preservation arguments.** Each hook's body is the WinMux code that stood at the call site before,
moved verbatim; any exception is stated below.

| Hook | Call site | Kind | Why behavior is unchanged | Check |
|---|---|---|---|---|
| `runCmdSeq` | `Command.swift` `[Command].runCmdSeq(_:_:)` | replacement | The hook body is the previous WinMux body. The only edit is that the cache test calls `syncsClosedWindowsCache(after:)` instead of reading `shouldResetClosedWindowsCache` (next row). The replacement line returns on every call, so upstream's body never runs. `io` is passed as the same object. | Mutation (hook line removed): `WinMuxHooksTest.testCommandSequenceSeesTheTabsShownWhenItStarted` fails |
| `syncsClosedWindowsCache(after:)` | read by `runCmdSeq` | policy | Seven upstream commands had been flipped to `shouldResetClosedWindowsCache = true` (BalanceSizes, FocusBackAndForth, Fullscreen, MacosNativeFullscreen, MacosNativeMinimize, WorkspaceBackAndForth, Workspace). They declare upstream's `false` again, and the hook returns `true` for exactly those types or any command declaring `true`. No command flipped the other way (checked against `13b35332`). `runCmdSeq` was the property's only reader. So every command gives the same answer as before. | Golden config dump prints the decision per bound command and is unchanged; `WinMuxHooksTest` covers all seven; mutations (table emptied, one entry removed) fail |
| `didSetEnabled` | `EnableCommand.run`, right after `isEnabled = newState` | event | It ran at that same point before (between setting `isEnabled` and the floating-size loop). Same statements, same order. | Mutation (call removed): `testDisablingEndsSidebarExpansion` fails |
| `globalObserverWillInstall` | first line of `GlobalObserver.initObserver` | guard and event | Same statements in the same order before any observer: the install-once guard, `DoubleSidedWindowGesture.install`, `startSystemFrontWindowWatcher`, frontmost-app activation. | By construction (AppKit observers aren't installable in unit tests) |
| `globalObserverNotification` | `GlobalObserver.onNotif`, before the refresh `Task` | event | Same statements, synchronously on the delivering queue, before the `Task` is created; returns the same `activatedAppPid`. | By construction |
| `installGlobalObserverMonitors` | last line of `GlobalObserver.initObserver` | event | Same monitors with the same handlers, all retained. One ordering change: the *local* mouse-up monitor is now installed after upstream's *global* one. Local monitors see this app's events and global monitors other apps', so no event reaches both and their relative order can't matter. | By construction; native smoke recommended |
| notification observer tokens | `GlobalObserver.initObserver` | upstream lines restored | WinMux kept the tokens returned by `NotificationCenter.addObserver(forName:object:queue:using:)`. Apple documents that the center holds the observer strongly until it is removed, and nothing ever removed them, so dropping the tokens changes nothing. Event-monitor retention ("Keep key listeners alive", `9d693761`) is kept, including for upstream's mouse-up monitor. | — |
| `visibleRectPaddedByOuterGaps` | `MonitorEx.swift` | replacement | The hook body is the previous WinMux body, using the same `workspaceSidebarInset`. | Mutation (back to upstream's formula): 171 failures across the sidebar width and layout tests |

**Code moved or restored without behavior change:**
- WinMux code moved unchanged into WinMux files: the rest of `GlobalObserver`, `mouse.swift`'s drag-session state, `ConfigFile.swift`'s config bootstrap, and `MonitorEx`/`WorkspaceEx` helpers.
- Upstream bodies restored where WinMux had only restyled them: `mouseLocation`, `monitorId_oneBased` (plus a marked `@MainActor`), and `WorkspaceEx`'s container accessors and `forceAssignedMonitor`.
- Dead code restored: helpers WinMux deleted only as unused.
- `transposed()` lives in `StringEx.swift` again, which also removes the add/add collision with upstream's new `ArrayEx.swift`.
- The app entry point is back at `Sources/AeroSpaceApp/`: `Package.swift` and `project.yml` point at it, and the target, product and executable stay `WinMuxApp`.
- From Carbon's phase 1 review: run-time format cases moved to the query test, and `flatten`'s depth no longer counts the elided `winmux` segment. Fixtures were regenerated on `8ef3e860`.

**Manifest:**

| | Phase 1 | Phase 2 |
|---|---|---|
| pristine | 97 | 109 |
| hooked | 14 | 19 |
| forked | 143 | 127 |
| forked non-test `Sources/` | 111 | 95 |

`make upstream-guard` and the manual workflow are now blocking.

**Plan change: convert the rest during its slice.** The other 95 forked non-test source files are mostly files upstream is
rewriting in phase 3. Upstream's lines changed in them since the fork: `MacApp` 393, `parseConfig` 402, `Workspace` 164,
`refresh` 138. Hooking WinMux code into bodies that S2–S10 replace would be done twice, and the second time against new
upstream APIs (`ExitCode`, `CancellationMode`, the Monitor tree, `OpaqueWindowId`). Each file is therefore converted in the
slice that brings most of its upstream changes. Phase 2 hooked the files upstream barely touches (`GlobalObserver`,
`mouse.swift`, `ConfigFile`, `MonitorEx`, `WorkspaceEx`, the command flags), where a conversion lasts. The schedule, by the
slice with the most upstream lines in each file (computed from `git diff --numstat` over each slice's range):

| Slice | Files | Forked files converted with it |
|---|---|---|
| S1 | 1 | `config/ConfigFile.swift` |
| S2 | 8 | `Common/util/StringEx.swift`, `GlobalObserver.swift`, `ListApps/ListMonitors/ListWorkspacesCommand.swift`, `config/startAtLogin.swift`, `getNativeFocusedWindow.swift`, `util/dumpAxRecursive.swift` (`ui/TrayMenuModel.swift` was listed here in error: its manifest target is `forked`, WinMux's tray model replaces upstream's) |
| S3 | 24 | `Cli/_main.swift`, `server.swift`, `initAppBundle.swift`, `config/parseConfig.swift`, `command/format.swift`, `ReloadConfig/Focus/Move/MoveMouse/MoveNodeToMonitor/MoveNodeToWorkspace/MoveWorkspaceToMonitor/Resize/SummonWorkspace/WorkspaceBackAndForth/Config/ListWindowsCommand.swift`, the `Focus/ListApps/ListMonitors/ListWindows` arguments and `parseCmdArgs.swift`, `ui/MessageView.swift`, `util/appBundleUtil.swift` |
| S4 | 4 | `LayoutCmdArgs.swift`, `LayoutCommand.swift`, `tree/WorkspaceEx.swift`, `tree/frozen/FrozenWorld.swift` |
| S5 | 22 | `focus.swift`, `config/Config.swift`, `HotkeyBinding.swift`, `Mode.swift`, `parseOnWindowDetected.swift`, `parseExecEnvVariables.swift`, `parseCommand.swift`, `WorkspaceCommand.swift`, `cmdHelpGenerated.swift`, `NWConnectionEx.swift`, `clientServer.swift`, `AeroSpaceEnvVars.swift`, `AxUiElementWindowType.swift`, `ArgParserInput.swift`, `parseSpecificCmdArgs.swift` and the remaining command arguments |
| S6 | 9 | `layout/refresh.swift`, `tree/MacWindow.swift`, `runLoop.swift`, `normalizeLayoutReason.swift`, `mouse/mouse.swift`, `util/accessibility.swift`, `ui/MenuBar.swift`, `DebugWindowsCommand.swift`, `MacosNativeFullscreenCommand.swift` |
| S7a / S7b | 2 / 6 | `model/Monitor.swift`, `ui/SecureInputView.swift` / `tree/Workspace.swift`, `closedWindowsCache.swift`, `FrozenTreeNode.swift`, `TreeNodeCases.swift`, `windowLevelCache.swift`, `cmdResolveTargetOrReportError.swift` |
| S8 | 8 | `layout/layoutRecursive.swift`, `moveWithMouse.swift`, `resizeWithMouse.swift`, `TilingContainer.swift`, `BalanceSizesCommand.swift`, `commonUtil.swift`, `Orientation.swift`, `ListWorkspacesCmdArgs.swift` |
| S9 | 4 | `tree/MacApp.swift`, `focusCache.swift`, `gitHash/versionGenerated.swift` |
| S10 | 4 | `tree/Window.swift`, `AeroSpaceApp.swift`, `model/Rect.swift`, `ui/ExperimentalUISettings.swift` |

Each slice's exit criterion gains: the files scheduled for it reach their manifest target, and the guard stays strict. The
≤10 forked budget applies at the end of S10.

User-visible risk of this candidate: none intended. The hooks run the same statements at the same points. The one
reordering (local vs global mouse-up monitor) involves monitors that never see the same event.

## Phase 3: merge train

Upstream `main` is linear (`git log --first-parent` and the full log both count 366 commits from `13b35332` to
`6ed6af62`). The train merges it at chronological cut points chosen at series boundaries. Each slice is `merge <cut>`,
then resolve, `finish`, test, review, and its own Preview. Positions (#) count upstream commits after the fork, oldest
first.

| Slice | Cut (last commit) | Upstream range | What arrives | WinMux work |
|---|---|---|---|---|
| S1 | `ff4d9c1d` | #1–6 | Small fixes and cleanups. Proves the train mechanics and deletion resolution. | trivial |
| S2 | `aca3200e` | #7–32 | **TOMLKit → TOMLDecoder** (`16a0b634`), `ConfigParseError` renames, session renames (`scheduleCancellableCompleteRefreshSession`, `runHeavyCompleteRefreshSession`), cancellation made explicit | Port the WinMux config parsers to `OrderedJson` behind a thin adapter. Rename session call sites (27 lines in 13 files). |
| S3 | `90347dbb` | #33–97 | **`ExitCode`** and the `Command.run` signature, `test` command, generic errors exit 2, command-valued `on-window-detected.if`, config diagnostics, `Task.startUnstructured`, `TilingContainerParentCases` | Port 15 WinMux commands to `ExitCodeType`. Re-check the WinMux exit-code contract (WinMux already uses 2 for usage errors). |
| S4 | `43dff5a3` | #98–114 | **`FloatingWindowsContainer`** (`5e37ec0a`). `layout --fail-if-noop` (already ported). | WinMux code that binds floating windows to the workspace: new-window binding, frozen restore, aux windows, `.workspace` switches. |
| S5 | `4e5a4351` | #115–164 | **Handwritten shell** (`f4be7288`). Bindings and callbacks run through it (`790e1222`, breaking). `eval`, `echo`, `true`/`false`. Callbacks run inline (`fdb27c59`). Socket handshake (`8413641c`, already ported). | Drop `runCmdSeq` users. Port `tabsListedAtSequenceStart` and the pointer-keeping task-local onto inline callbacks. Run the binding corpus. |
| S6 | `ae2aa7aa` | #165–194 | Commands and callbacks non-cancellable (`ecfc745c`). **Focus-follows-mouse** (off by default). `_isStartup` removed. `getOrRegister` fixes and kCGNullWindowID (already ported). | Fold `AxAppWorker` guarantees into upstream's run loop with `CancellationMode`. Merge the FFM branch into the light session. |
| S7a | `44444a02` (#224) | #195–224 | `Monitor` → `MonitorInfo` rename, TOML follow-ups, nested config tables | Mechanical renames across WinMux code (about 95 `activeWorkspace`, 135 `workspaceMonitor`, 104 `focus.` lines over S7a–S7b). |
| S7b | `c736e8e3` | #225–251 | **Monitor TreeNode** (`8ba2e4c1`…`c419f4b2`). Frozen world nested under monitors (`b7175354`). Focus on every monitor at startup (`58238ba5`). Idempotent `refreshAndGetAliveWindowIds` (`9fce49a3`). `getWindowLevel` off the main thread (`be3e58df`, `.optionAll` `b686e0f2`). | **The model migration** (§Side tables): remove `winMuxWorkspaceState`'s monitor ownership; viewport state moves to `MonitorMeta`; project-preserving assignment goes through `workspaceForMonitor`/`matchMonitors`. Frozen and saved schema migration. |
| S8 | `80b3ebeb` | #252–280 | **`WindowLifeStatus`** tombstones and native tabs 1–19 (`inhabitedChildren`, accordion and command rewrites). `#myFileId` macro target. `Withable`. | Liveness mapping (§Liveness). Tab groups over `inhabitedChildren`. The new `Macros` target in `Package.swift`/`project.yml`. |
| S9 | `c6a10d5a` | #281–330 | **`OpaqueWindowId`** (`afbac18e`). Native-tab swap heuristic (`9c16cb96`). `kAXMainWindowChangedNotification`. `window-id-native` format variable. | Migrate the `UInt32`-keyed side tables to `OpaqueWindowId`. Persisted state stays keyed by native ids (decision D1). Gate the swap heuristic (decision D2). |
| S10 | `6ed6af62` (HEAD) | #331–366 | **XCTest → swift-testing** for upstream tests. Concurrent native-state and floating-rect queries (`846f1a22`). `CGPoint` → `Point`. `getWindowLevel` follow-ups (`0d498deb`, `7a3f2e34`). | Keep WinMux tests on XCTest (both frameworks run in one target). Keep the native-state cache on top of upstream's query primitive. |

After S10, sync continues at upstream's pace (§Steady state).

### S1 outcome (candidate on `upstream/s1-20261115`)

Merged upstream `ff4d9c1d` (#1–6) with `script/upstream-sync.py merge`. 9 dry-run conflicts:
- 3 deletions auto-resolved;
- 6 forked files resolved by hand, all six recorded by rerere; dispositions are in `docs/upstream-backports.md` (Merge train).
- The S1-scheduled conversion, `config/ConfigFile.swift`, is now hooked (replacement hook `findCustomConfigUrl`).

Folded in Carbon's phase 2 nits:
- `VolumeView`'s `[self]`, which makes that file forked by one line until upstream's `[weak self]` arrives;
- `setUpWorkspacesForTests` focus-history reset;
- a non-vacuous format case. Fixtures were regenerated on v0.6.420.

User-visible change: none intended. Upstream's distance fix affects only which display a point outside every display is
attributed to.

Review fix (Carbon S1-C1): the `a8241641` disposition "already covered" was wrong for the failure path. A summon or
`move-workspace-to-monitor` rejected by `workspace-to-monitor-force-assignment` evicted the workspace from its source display
before failing. `activateWorkspaceOnMonitorPreservingSourceViewport` now refuses before anything moves. User-visible: such a
rejected command now leaves both displays as they were (it already exited 1). Also from that review:
`resetFocusHistoryForTests()` replaces the partial reset in test setup, and a golden case pins `list-workspaces --format
'%{window-id}'` as exit 1. Carbon's Nit 1 (identity-less display matching order) is deferred to S7b.

The earlier "intentionally different" TOMLDecoder decision in `docs/upstream-backports.md` is superseded for S2. S2 must
keep the Settings GUI's TOML edit round trips, which today use TOMLKit; it may keep TOMLKit for editing while parsing
through upstream.

### S2 outcome (candidate on `upstream/s2-20261115`)

Merged upstream `aca3200e` (#7–32) with `script/upstream-sync.py merge`. 38 conflicts:
- 8 deletions auto-resolved (the Xcode project, `MenuBarLabel.swift`, `AxUiElementWindowTypeTest.swift`, `docs/goodies.adoc`, `generate.sh`, the two shell grammar files and their generator script).
- 30 resolved by hand. Dispositions are in `docs/upstream-backports.md` (Merge train).

**Scope: the shell and D3 are not in S2.** The request named S2 as "the TOMLDecoder parser and shell, plus D3". Upstream's handwritten shell (`f4be7288`) and its breaking binding change (`790e1222`) are commits #115–164, which is S5's range. The train merges upstream in order. A merge of the shell commits brings every earlier commit with it, so taking them now would fold S3 (`ExitCode`, the `Command.run` signature) and S4 (`FloatingWindowsContainer`) into this candidate. That breaks "each slice ships separately". S2 therefore stops at `aca3200e`, the end of the TOMLDecoder series. D3 is decided (adopt upstream's shell, warn on bindings whose meaning changes) and ships with S5, together with the binding corpus. **S2 adds no config warnings, and no binding or config key changes meaning.**

**Parser.** Config files are parsed by TOMLDecoder (TOML 1.1), as upstream does, behind WinMux's front end `WinMuxToml` (S2 review fixes, below). The pin is 0.4.5, upstream's own later pin.
- `parseConfig` returns `[String]`, sorted.
- WinMux's section parsers read `Json`:
  - `workspace-sidebar`, `window-tabs`, bindings, tap and sequence bindings, workspace intelligence, MCP;
  - the shortcuts preset.
- `Json` gains one marked case, `.double` (hook `jsonDouble`), because WinMux settings take fractional numbers (for example `workspace-sidebar.glass-opacity`).
- TOMLKit stays a dependency only for `window-rules.toml`, a separate file. Nothing that reads, edits or validates the main config uses it any more (S2 review fixes).

**Settings window and sidebar edits.**
- They still edit the file's text line by line, keeping comments and layout.
- Where a value ends, which lines are headers, and whether the result is valid are all decided by the loader's front end.
- Every write is checked by `validateConfigEdit` and written by `replaceConfigFileOnDisk` (S2 review fixes, S2 delta review fixes).
- Covered by `SettingsEditorTest`, `ShortcutSettingsConfigEditsTest`, the config-edit round trips in `ConfigTestConfigEdits.swift`, `WorkspaceSidebarResizeTest`, `CarbonS2SettingsToml11ReproTest` and `S2TomlFrontEndTest`, all green.

**User-visible changes, all wording or syntax; exact texts:**

Config files (errors appear in the load-failure message and in the Settings window; any error still rejects the whole file, as before):

| What | Before (TOMLKit) | Now (TOMLDecoder) |
|---|---|---|
| TOML syntax error | `Error while parsing key-value pair: expected '=', saw 't' (at line 1, column 5)` (TOMLKit's text, with line and column) | `(Line 1) Syntax error: missing =.` The form is `(Line N) Syntax error: <reason>.`, and the reason comes from TOMLDecoder, for example `invalid or missing key`. |
| Type names in `<key>: Expected type is '<expected>'. But actual type is '<actual>'` | `integer`, `floating-point number`, `date`, `time`, `date-time` | `int`, `double`. Dates and times never reach this message (next row). `string`, `bool`, `array` and `table` are unchanged. Example: `workspace-sidebar.open-saved-workspace-apps-at-startup: Expected type is 'bool'. But actual type is 'int'` |
| A TOML date or time anywhere in the file | an error at that key (`Unknown key`, or `... But actual type is 'date'`), next to the file's other errors | `<key path>: Unsupported TOML type: <type>`, for example `foo.bar: Unsupported TOML type: LocalDate`. It is reported alone, because conversion stops at the first such value. The file was rejected before too. No WinMux setting takes a date. |
| Order of several errors | parse order | sorted by text. For example `key-mapping.key-notation-to-key-code.q: …` now comes before `key-mapping.key-notation-to-key-code: …` |
| Invalid regex (`on-window-detected` `if.app-name-regex-substring` / `if.window-title-regex-substring`, monitor patterns in `gaps` and `workspace-to-monitor-force-assignment`) | `Can't parse 'X' regex. <reason>` | `Can't parse 'X' regex: <reason>`. Matching is still case-insensitive. |
| TOML 1.1 syntax | rejected | accepted. For example, inline tables spanning lines with a trailing comma (upstream's `testParseInlineTables`). |
| Malformed headers TOMLKit tolerated (AeroSpace issue 1064, for example `[[[on-window-detected]]`) | accepted in release builds (a debug-build assertion in TOMLKit's toml++; undefined behavior in release) | rejected: `(Line 1) Syntax error: invalid or missing key.` |
| A carriage return not followed by a line feed (invalid TOML anywhere) | rejected with TOMLKit's text | rejected: `(Line N) Syntax error: carriage return without line feed.` (this also rejects CR CR LF, which TOMLDecoder alone accepted) |
| CRLF files, a leading byte order mark, `\\` before a closing `"""` | read as the spec says | unchanged: read exactly as v0.6.421 read them (S2 review fixes) |

`debug-windows` prints `on-window-detected` matchers with their regex source text (upstream `ac2957bc`). It used to print `Regex` and the misspelled key `appNameRegexSubstrin`.

The effective default config and the WinMux test config (`config-default.txt`, `config-winmux.txt` golden files) parse to the same values as on v0.6.421.

CLI argument errors (exit codes unchanged). Upstream reworded value flags. WinMux's own commands now use the same helpers, so a flag's message is the same in every command:

| Case | Before | Now |
|---|---|---|
| `--window-id` with no value (all commands, including `stack-with`, `move-node-to-project`) | `'--window-id' must be followed by mandatory UInt32` | `'--window-id' must be followed by '<window-id>'` |
| `--window-id abc` | `Can't parse 'abc'. It must be a positive number` | `Failed to parse 'abc' CLI argument: Can't convert 'abc' to UInt32` |
| `focus --dfs-index` | same two messages as `--window-id` | `'--dfs-index' must be followed by '<dfs-index>'` / `Failed to parse 'x' CLI argument: Can't convert 'x' to UInt32` |
| `focus --tab-index` / `focus --tab-index 0` | `'--tab-index' must be followed by mandatory UInt32` / `'--tab-index' must be followed by UInt32 greater than zero` | `'--tab-index' must be followed by '<tab-index>'` / `Failed to parse '0' CLI argument: It must be greater than zero` |
| `delete-project … --if-window-count` with no value / `x` | `'--if-window-count' must be followed by mandatory UInt32` / `Can't parse 'x'. It must be a positive number` | `'--if-window-count' must be followed by '<count>'` / `Failed to parse 'x' CLI argument: Can't convert 'x' to UInt32` |
| `--workspace` with no value (`balance-sizes`, `flatten-workspace-tree`, `layout`, `move-workspace-to-monitor`, `save-workspace`, `forget-workspace`) | `'--workspace' must be followed by mandatory workspace name` | `'--workspace' must be followed by '<workspace>'` |
| `--workspace <invalid name>` | the name error alone | `Failed to parse '<name>' CLI argument: <the name error>` |
| `config --get`, `trigger-binding --mode`, `list-windows --pid` / `--app-bundle-id`, `save-workspace --name`, `create-project --name` / `--color`, `agent --path` with no value | `'<name>' is mandatory` (the placeholder) | `'--get' must be followed by '<name>'` (the flag, then the placeholder; likewise `<mode-id>`, `<pid>`, `<app-bundle-id>`, `<name>`, `<project-name>`, `<#RRGGBB>`, `<path>`) |
| `list-windows --pid x` | `Failed to convert 'x' to 'Int32'` | `Failed to parse 'x' CLI argument: Can't convert to Int32` |

`cli-parse-errors.txt` now pins all of these.

**Conversions** (schedule above): `StringEx`, `GlobalObserver`, `ListWorkspacesCommand`, `startAtLogin`, `getNativeFocusedWindow`, `dumpAxRecursive` and `Json` are hooked. `ListAppsCommand` and `ListMonitorsCommand` are pristine: WinMux's `writeFormattedOutput` is the same switch upstream inlines. `TrayMenuModel` stays forked (see the schedule row). Forked non-test sources: 95 → 87.

| Hook | Call site | Kind | Why behavior is unchanged | Check |
|---|---|---|---|---|
| `listWorkspaces` | `ListWorkspacesCommand.run` | replacement | The hook body is the previous WinMux `run`, moved verbatim (sidebar order, user-facing workspaces only, `--empty` = no window the sidebar shows). WinMux's `--empty` differs from upstream's `isEffectivelyEmpty` for a workspace whose only window is in native full screen. The replacement line returns on every call. | Mutations: hook line removed fails the order and the new `testEmptyIgnoresNativeFullscreenWindows`; `--empty` swapped to upstream's test fails the latter |
| `cleanupLaunchAgentPlists` | `startAtLogin.swift` `cleanupPlistFromPrevVersions` | replacement | Removes the same two WinMux plists as before. Upstream's body would delete AeroSpace's own `bobko.aerospace.plist`, which WinMux must not touch. | `testLaunchAgentCleanupRemovesOnlyWinMuxPlists` on a temp directory; mutation (list includes AeroSpace's plist) fails. The call site is wired by inspection: it reads the real `~/Library/LaunchAgents`, which tests must not touch. |
| `activatedAppPid` | `GlobalObserver.onNotif`, activation branch | replacement | The same call WinMux made, passing `activatedAppPid`, then `return`. Nothing follows the `if`/`else` in that task. | By construction |
| `installGlobalObserverMonitors` | `GlobalObserver.initObserver`, after the notification observers | replacement (was: event, last line) | It now also installs WinMux's global mouse-up monitor, moved verbatim (drag end, sidebar drop, menu-bar exclusion, retained), first, then the monitors it installed before. That is the same order as before. | By construction; phase 2 native smoke covers these monitors |
| `appName` | `String.interpolate`, missing env variable | rewrite of the failure | The message is WinMux's text (`… isn't presented in WinMux.app env vars, …`), as before. | Mutation (hook removed): `ParseEnvVariablesTest.testCyclicDep` fails |
| `axDumpKeys` | `dumpAxRecursive`, recursion limit and before `return` | replacement and rename | `debug-windows` keeps `WinMux.synthetic`, `WinMux.AxWritable`, `WinMux.AxFailed`, `WinMux.AxIgnored`. AX attribute names never start with `Aero.`, so the rename can't hit a real attribute. | `testAxDumpKeepsWinMuxKeyNames`; mutation (rename skipped) fails |
| `axErrorRepr` | `extension AXError` | addition | `winMuxRepr` forwards to the file-private `repr`, for the two WinMux callers. | — |
| `nativeFocusObservation` | end of `getNativeFocusedWindow.swift` | addition | Upstream's `getNativeFocusedWindow` body is back. It reads the same `focusedApp?.getFocusedWindow()` WinMux's version did, minus a stored-property read. | — |
| `jsonDouble` | `Json`, `tomlAnyToParsedConfigRecursive` | addition | TOMLKit gave WinMux floats; this keeps them. | `S2TomlFrontEndTest.testFloatsConvertToJsonDoubles` asserts the conversion directly. Removing the case also traps the test process, because `defaultConfig`'s own parse then fails inside its initializer. |
| `tomlSource` | `parseConfig.swift` `_parseConfig`, before TOMLDecoder | guard and input normalization | See S2 review fixes. Each normalization (contiguous storage, CRLF, byte order mark, final newline) yields the same TOML document; the guard reports only a character that is invalid anywhere in TOML. | Mutations below |

**Build settings.**
- Upstream enables strict memory safety and `NonisolatedNonsendingByDefault` in every module.
- WinMux keeps `NonisolatedNonsendingByDefault` on AppBundle only, as before, and strict memory safety nowhere.
- Upstream's `unsafe` markers compile without strict mode. The one marker in Common that the Cli release build's `-warnings-as-errors` rejected (`NWConnectionEx.swift`, a forked file until S5) keeps WinMux's line.
- Enabling both settings for Common and Cli means annotating about 20 WinMux sites there. It stays deferred to S5, which converts `NWConnectionEx`.
- `.swift-version` stays 6.4.2; upstream's is 6.3.0.

**Toolchain warnings.** Upstream's unassigned `Task { … }` in `GlobalObserver` (two lines, one of them in the replaced, never-run monitor body) warns on Swift 6.4. AppBundle warnings don't fail the release build: `-warnings-as-errors` applies to the Cli product and the app target's own sources. S3 replaces both lines with upstream's `Task.startUnstructured`.

### S2 review fixes (Astra A1–A3, Carbon S2-C1/C2)

Principle: one parser, one truth. Anything that reads, edits or validates the main config agrees with the loader, and no writer skips validation.

**The loader's front end, `WinMuxToml`.** `parseConfig` (hook `tomlSource`), the Settings and sidebar statement scans, and first-launch import all parse through it. It hands TOMLDecoder text that TOMLDecoder reads as the TOML spec, and v0.6.421, do:

| Input | TOMLDecoder alone | Front end | Why |
|---|---|---|---|
| Text bridged from `NSTextStorage` (the TOML Editor) | traps: 0.4.4/0.4.5 force-unwraps contiguous UTF-8 when unpacking values (`Token.swift:105`) | always a new contiguous String | A1 |
| CRLF inside multiline strings | keeps the CR in the value | CRLF → LF before parsing | A2. The spec lets a parser normalize newlines, and v0.6.421 gave LF. An escaped `\r` stays a CR. |
| `\\` just before a closing `"""` | `unterminated triple-d-quote`: the lexer takes any backslash before the quote as escaping it (`Parser.swift:241`, still in 0.4.5) | fixed in the vendored TOMLDecoder (S2 delta review fixes); the first round's textual `\\` → `\u005C` rewrite is gone | A3 |
| A bare value cut off at EOF (`width = -`, `n`, `in`, …) | reads out of bounds. 0.4.5 fixes several of these paths but not all: with the newline guard removed, `CarbonS2EofReproTest` still traps on 0.4.5 | a newline is appended when missing | S2-C2. Pinned 0.4.5 as well (upstream's later pin; it fixes base-prefixed integer unpacking too). |
| A lone CR | CR CR LF accepted | rejected with its line | invalid TOML anywhere; v0.6.421 rejected it |
| A leading byte order mark | `missing =` | dropped | Carbon nit 2; TOMLKit dropped it |

None of these changes the line count, so error lines are the file's.

**Structure scans.**
- Before: `ConfigSettingsViews.updateSettingsScalarConfig`, the sidebar's `tomlMultilineValueContinuations` and project-order check, and `ConfigBootstrap`'s import check asked TOMLKit (TOML 1.0) where a multiline value ends.
- After: they ask the front end, through one helper, `tomlStatementEnd`.
- The shortcut editor (`updateModeBindingConfig`) had no multiline awareness at all. It now skips continuation lines too, and drops a removed binding's continuation lines with it.

**One validated write path.**
- `writeConfigFile(after, replacing: before, at:, changing:)`:
  1. The loader must read `after` without adding an error that `before` didn't have.
  2. Every key outside `changing` must keep its value, comparing the loader's reading of both texts. A key under a listed path counts as inside.
  3. Only then is the file written atomically.
- Writers using it:
  - all six sidebar writers (workspace label, project label, color, emoji, metadata, order), each listing the keys it edits;
  - the shortcut binding writer (`[mode.main.binding]`);
  - the tabs-sidebar toggle.
- `SettingsPersistence` applies the same kept-keys check after its existing zero-errors check:
  - form edits list their section and keys, plus `workspace-sidebar.dock-appearance` when they freeze inherited Dock values;
  - display-width edits list their display;
  - the TOML Editor and undo replace the whole document, so they are validated but not key-checked.
- First-launch import and the starter file write a new file: the front end must read the text first.
- New refusal texts, shown where the edit was made:
  - `WinMux didn't save this change: the configuration would no longer load.` followed by the loader's errors;
  - `WinMux didn't save this change: it would also have changed '<key>'. Edit the file in Advanced → TOML Editor.`;
  - `WinMux didn't save this change: it couldn't read the configuration to check the edit. Fix it in Advanced → TOML Editor.`
- A sidebar edit on a file that doesn't parse is now refused, where v0.6.421 wrote it anyway.

**Results**

Reviewers' reproducers, used unchanged as RED:
- `CarbonS2SettingsToml11ReproTest` (byte-identical copy in `Sources/AppBundleTests/review/`): 3 tests and 7 failures before, 0 failures after.
- `CarbonS2EofReproTest` (method verbatim): it trapped before and passes after.
- Astra's `S2SettingsForeignStringRepro`, `S2CRLFRepro` and `S2EscapedBackslashRepro`, built unchanged against this tree with her build script, retargeted:
  - before: a trap, 0/3, 0/1;
  - after: PASS, 3/3, 1/1.
- Their contracts are also ported into `S2TomlFrontEndTest`.

Differentials against v0.6.421:
- Astra's corpus, 2,246 config inputs and 7,759 distinct CLI texts:
  - configs: 736 accepted by both, 1,483 rejected by both, 0 newly rejected, 5 newly accepted, 0 crashes, 3 dump differences;
  - CLI: 7,759 equal outcomes.
- The 5 newly accepted inputs are TOML 1.1 inline tables (2) and floats below `Double`'s normal range (3: `1e-320`, `1e-999`, `1e-9999` as `glass-opacity`). TOMLKit rejected those; TOMLDecoder reads them as the nearest `Double`.
- The 3 dump differences:
  - two are v1's derived `persistentWorkspaces` order, which already varies between runs within each revision (Astra's control);
  - one is the open item below.
- Carbon's corpus: 204 valid on both, 0 newly failed, 1 newly accepted (TOML 1.1). The only dump difference is the regex wrapper's reflection text, with the same pattern. His TOML 1.1 Settings and sidebar probes keep every key.

Fuzzing:
- In the suite: every character prefix of every line of the default config, window-rules default, starter config and edge snippets, alone and with a stray CR, plus whole-file prefixes at each line. It takes under a second.
- Once, outside the suite: every character prefix of all 2,446 reviewer config texts through the front end. That was 1,687,951 prefixes, 33,460 of them valid TOML, with 0 crashes.

Mutations: each guard is replaced with its absence, and `S2TomlFrontEndTest` and the Carbon tests run.

| Mutation | Caught by |
|---|---|
| The front end hands back the caller's String when nothing needs rewriting | A1 test traps (`Token.swift:105`) |
| CRLF kept | 6 failures: the CRLF contracts and the lone-CR test |
| A lone CR dropped instead of reported | 3 failures in the lone-CR test |
| `\\` not rewritten (first round; the rewrite is replaced by the decoder patch below) | 8 failures in the escaped-backslash test |
| No trailing newline | `CarbonS2EofReproTest` traps on 0.4.5 |
| Byte order mark kept | the byte-order-mark test |
| Kept-keys check off | the two write-refusal tests (4 failures) |
| Added-errors check off | 3 failures in the loader-rejects test |
| The statement scan never ends a multiline value | Carbon's two Settings tests (5 failures) |
| `SettingsPersistence.save` skips the kept-keys check | the Settings refusal test |

**Open item: canonically equal keys.**
- Example: `[exec.env-vars]` with `"é"` written composed (`C3 A9`) and then decomposed (`65 CC 81`).
- TOML treats these as two keys. WinMux's config, keyed by Swift `String`, can't hold both, and neither version is spec-correct.
- v0.6.421 kept `one` (the composed key, written first); S2 keeps `two` (the last).
- Matching v0.6.421 would need TOMLKit's key order, which isn't known to be document order: byte order also gives `one`.
- The alternative is rejecting such a file with an error, which would make a file that loaded before fail.
- Decided in review: S2 keeps last-wins.

### S2 delta review fixes (Astra S2-D-A1/A2, Carbon S2-D1/D2)

Three structural causes, three fixes.

**(a) Editors split and trimmed raw text themselves → `EditableConfigText`.**
- It is the only place config text becomes lines (`Sources/AppBundle/WinMux/EditableConfigText.swift`).
- It records the file's line ending (CRLF if the file uses CRLF anywhere) and its byte order mark, and exposes LF lines with neither.
- On write, `text` restores both.
- All config editors work only on those lines: the sidebar's scalar, key/value-section and project-order editors, the shortcut binding editor, the Settings scalar editor, and the AeroSpace import splitter.
- Their ad-hoc `components(separatedBy: "\n")`, `\r` stripping and string-appended sections are gone. Missing tables are added by `appendTable`.
- A grep of `Sources/AppBundle` for `components(separatedBy: "\n")`, `split(separator: "\n"` and newline splitting finds no config editor. The remaining hits are browser and Hookmark script output, the `workspace` command's stdin list, and the Settings text field that takes one command per line.
- A CRLF file therefore looks to every editor exactly like its LF twin. It is written back with CRLF, with comments and layout kept.
- A file mixing CRLF and LF is written with CRLF throughout. Values don't change: the loader reads a CRLF inside a multiline string as LF.

**(b) Atomic writes renamed over symlinks → `replaceConfigFileOnDisk`.**
- It is the only code that writes the config to disk, used by `writeConfigFile`, `SettingsPersistence`'s default writer, and the first-launch import and starter file.
- It follows the symlink chain one link at a time with `readlink`. A relative destination is taken relative to the link's own directory and left for the OS to resolve, so links inside symlinked directories resolve physically.
- It then replaces the real file atomically through a temporary file in that file's directory. That keeps the link and the file's permissions.
- A dangling link creates its target.
- A chain longer than 32 links is refused as a loop: `WinMux didn't save this change: '<path>' is a symlink loop.`
- `SettingsPersistence` now runs the same `validateConfigEdit` as `writeConfigFile` after its own zero-errors check, then writes with `replaceConfigFileOnDisk`.

**(c) The `\\` → `\` rewrite misread TOMLDecoder's quote counting → patched TOMLDecoder.**
- `Vendor/TOMLDecoder` holds TOMLDecoder 0.4.5's library sources, committed unchanged in its own commit. A second commit adds three marked lines:
  - the lexer counts the backslash run before a `"""`, which is escaped only after an odd run;
  - `\u`/`\U`/`\x` escapes and line-ending backslashes end a quote run, like every other escape.
- `Vendor/TOMLDecoder/WINMUX-PATCH.md` describes both defects with reproducers, ready to report upstream. Drop the copy for a fixed release.
- The front end no longer rewrites text.

**Guard contract (Astra).**
- An empty table is now a value in the kept-keys check: an empty `[exec]` changes `PATH`, and an empty `[mode.service]` defines a mode.
- Only an empty table at an ancestor of an edited key may appear or go, which is what happens when a table's last key is removed.

**Results**

Reproducers, unchanged as RED, built against this tree:

| Reproducer | Before (`f9b15b91`) | After |
|---|---|---|
| `CarbonS2DeltaReproTest` (byte-identical) | 3 tests, 8 failures | 0 failures |
| Astra `S2DeltaWriteProbe` | 11 checks, 6 failures | 0 failures |
| Astra `S2DeltaGuardProbe` | 7 checks, 2 failures | 0 failures |
| Astra `S2DeltaRewriteRepro` | fail | pass |

- Astra's first-round reproducers and Carbon's first-round tests still pass.
- All of these are also ported into `S2DeltaTest`.

String differentials:
- Astra's 80,302-input string corpus against `tomllib`:
  - all 41,010 reference-valid inputs decode equal, with 0 rejections (her run had 4: 2 from the rewrite and 2 pre-existing decoder bugs, which the patch also fixes);
  - the 10 acceptances outside her reference are TOML 1.1 `\e`/`\x` escapes, which her Python 3.12 `tomllib` (TOML 1.0) rejects.
- 60,000 random multiline and basic strings (escaped quotes, escaped backslashes, line-ending backslashes, `"`/`\`, quote runs) against Python 3.15's `tomllib`, which reads TOML 1.1:
  - all 47,380 valid inputs decode equal;
  - all 12,620 invalid inputs are rejected.

Config differentials against v0.6.421:
- Astra's: 2,246 config inputs, 0 newly rejected, 0 crashes, 5 newly accepted and 3 dump differences, the same as the previous round; all 7,759 CLI outcomes equal.
- Carbon's: 0 newly failed. The only dump difference is the regex wrapper's reflection text.

Prefix fuzz, rerun on the patched decoder: every character prefix of all 2,446 reviewer config texts (1,687,951 prefixes) through the front end, with 0 crashes and the same 33,460 valid prefixes as before.

CRLF through every editor:
- Every reviewer corpus text that contains a newline and no CR (2,196 of the 2,446) went through 12 editor operations, as LF and as CRLF:
  - sidebar width, workspace label set and removal, project label, color, emoji and order, display width;
  - the shortcut bindings;
  - Settings gaps, opacity and unset.
- 26,352 runs:
  - editing the CRLF file gave exactly the CRLF form of editing the LF file every time;
  - the validated write decided the same way for both every time.
- 1,999 edits on files that load were refused for both endings. All are files the line editors can't edit:
  - inline-table or quoted-key forms of whole sections (`"workspace-sidebar" = { … }`);
  - top-level dotted keys (`gaps.inner.horizontal = 8`).
- Settings refused these on v0.6.421 too. The sidebar writers used to write a file that then failed to load.

Mutations, against `S2DeltaTest`, `S2TomlFrontEndTest` and the Carbon tests:

| Mutation | Caught |
|---|---|
| Lexer: any backslash escapes the closing quote | yes |
| No quote-run reset after `\u` | yes |
| No quote-run reset after a line-ending backslash | yes |
| `EditableConfigText` always writes LF | yes |
| CRs left in the lines | yes |
| Byte order mark left on the first line | yes |
| Symlinks not followed | yes |
| A relative link resolved against the working directory | yes |
| `SettingsPersistence` writes with its own atomic write | yes |
| Empty tables skipped | yes |
| No empty-table ancestor allowance | yes |
| An explicit permission restore after the write removed | survived: Foundation's atomic write already keeps the mode, so the restore was dropped and the test pins the mode |

### Side tables: projects, pins and workspace identity on upstream's model

Upstream (after S7b and S9):
- `Monitor` is a tree node, with children `WorkspacesContainer` (holding `Workspace` nodes, `visibleWorkspaceNameOrStale`, `prevVisibleWorkspaceName`) and `FloatingWindowsContainer`.
- Workspaces are keyed by name.
- Windows are keyed by `OpaqueWindowId`, mapped per app to native `UInt32` ids through a `BiDictionary`.

WinMux keeps the upstream structure and attaches its semantics:

| WinMux concept | Today | On upstream's model |
|---|---|---|
| Workspace identity | `Workspace.id: WorkspaceId`, equality by object, `name` unique and immutable (renames create new workspaces) | Upstream `Workspace` with its unique name. `WorkspaceMeta.id` keeps WinMux's `WorkspaceId` for side-table keys and persisted references. Equality and hashing stay upstream's (by name). Because WinMux never reuses a live name for a different workspace, name equality and object identity agree. `workspaceWillGarbageCollect` drops the meta and any index entries. |
| Workspace attributes | stored properties: `projectId`, `namingStyle`, `lifecycle`, `hasHadWindows`, `lastWindowClosed`, `retainsEmptyAfterProjectMove`, `preferredMonitorPoint` | `WorkspaceMeta` fields. `preferredMonitorPoint` maps to upstream's force-assigned monitor where configured, otherwise to the `workspaceForMonitor` policy. |
| Workspace registry | `winMuxWorkspaceState.workspaceById` / `workspaceIdByName` | upstream's `Workspace.all`, plus a WinMux index `[WorkspaceId: Workspace]` rebuilt from `WorkspaceMeta` |
| Projects | `projectsById`, workspace `projectId` | Unchanged WinMux registry (`WorkspaceProjects.swift`). Membership via `WorkspaceMeta.projectId`. |
| Per-display state | `MonitorViewport`: active workspace, previous workspace, last active per project, display key, context project | Active → upstream `WorkspacesContainer.visibleWorkspaceNameOrStale` (`setVisibleWorkspace`). Previous → `prevVisibleWorkspaceName`. The other three → `MonitorMeta`. A viewport id becomes the `Monitor` node identity, re-associated by `matchMonitors` using display keys. |
| Workspace ↔ display ownership | side registry; workspaces are tree roots | Upstream ownership: a workspace is a child of one monitor's `WorkspacesContainer`. Moving a project's workspace to another display is a `bindWorkspace` on that monitor. WinMux's project-preserving swaps become `workspaceForMonitor`. |
| Tab members, pins, saved slots, aux links, intents | side tables keyed by `UInt32` window id (+ pid) | Live tables keyed by `OpaqueWindowId`. **Persisted** tables (saved workspaces, frozen world on disk, pin records) stay keyed by native id + pid + app identity, because opaque ids are a per-session counter (`OpaqueWindowId.nextUniqId`). Conversion at load/save via `MacApp.opaqueWindowId(of:)` / `nativeWindowId(of:)`. |
| Tab groups | `Layout.tabGroup = "tab-group"` | Upstream's `.accordion` case, rendered by the `layoutContainer` hook. Config and CLI accept `tab-group`, `h_tab_group`, `v_tab_group` (WinMux) and `accordion`, `h_accordion`, `v_accordion` (upstream). Output keeps printing `tab-group` (format hook), so scripts see no change. Persisted `"tab-group"` decodes to `.accordion`. |
| Floating windows | children of `Workspace` | children of `workspace.floatingWindowsContainer` (S4) |
| Frozen world | top-level workspaces, Codable, project fields | Upstream's monitor-nested `FrozenWorld`, plus an optional Codable WinMux payload per workspace and window (`projectId`, `namingStyle`, `layoutReason` extras), versioned. The on-disk file gets a one-time migration with a fixture test. |

### Liveness: the evidence model on upstream's alive/invisible/dead

The liveness fix now finishing on `main` decides each registered window per refresh from three sources of evidence:
- its own AX answer: alive, busy (timeout) or gone;
- its app's `AXWindows`: names, omits or unread;
- the window server's `.optionAll` list: unusable, absent, or listed with or without `onShownSpace`.

It returns `keep`, `keepUnbound`, `rebind` or `drop`, and nothing is decided behind the lock screen. Upstream (S8) gives each
window a `WindowLifeStatus`:
- `alive`: laid out;
- `invisible`: other Space or background tab; keeps its tree slot, not laid out;
- `dead`: closed, or the locked screen.

The `liveness` hook maps verdicts onto that status:

| Liveness verdict | Window server / app context | Upstream status | Notes |
|---|---|---|---|
| `keep` | listed on the shown Space, or named by `AXWindows` | `.alive` | as upstream |
| `keep` | listed off the shown Space (other Space, minimized, hidden app), or busy and listed | `.invisible` | matches upstream's "invisible macOS Spaces" meaning. Layout skips it and the slot is kept. |
| `keepUnbound` | element stale, no fresh element yet | `.invisible` | no frame writes (upstream doesn't lay out invisible windows). Rebinding is retried every refresh. |
| `rebind` | app lists the id afresh | `.alive`, after the hook swaps the `AxWindow` element under the same native id and keeps the `OpaqueWindowId` | upstream has no rebind. The swap happens in `AxWindowRegistry` before the status is returned. |
| `drop` | positive evidence of closure (rows 4, 5, 7) | `.dead` | upstream then tombstones and garbage-collects as usual |
| no decision | lock screen or suspended session | previous status | **differs from upstream**, which marks windows dead when the screen locks. WinMux never drops on a locked screen. |

Busy absences (`windowServerAbsencesToLetGo = 2`) live in `WindowMeta`. Upstream's idempotent `refreshAndGetAliveWindowIds`
(`9fce49a3`, S7b) is adopted: it cancels `setFrameJobs` for every non-alive id, and `.invisible` counts as non-alive there.
That is consistent with `keepUnbound` doing no writes. Tests: the liveness fix's evidence-table tests run unchanged against
the hook, plus one test per mapping row asserting the upstream status, plus a mutation check of each row.

### Decisions for Alan before the slices that need them

- **D1 (before S9): what `window-id` means in CLI, MCP and `agent` output.**
  - Today it is the native CGWindowID, which is stable while the window lives, survives a WinMux restart, and matches CG tools and screenshots.
  - Upstream changes it to a per-session opaque counter.
  - Recommendation: keep printing the native id as `window-id` in WinMux output (the format hook) and add `window-id-opaque`, so scripts and agents keep working. Internally use `OpaqueWindowId`.
- **D2 (before S9): upstream's native-tab swap heuristic.**
  - Upstream may now treat a background macOS native tab (Finder, Terminal, Safari windows merged into tabs) as the same window as its front tab.
  - Recommendation: keep WinMux's current behavior (each native tab window tracked on its own) by gating the heuristic off, and revisit once upstream's native tabs series is finished.
- **D3 (S5): upstream's shell changes how binding and callback commands parse.** This is upstream's breaking change `790e1222`; it affects quoting, `&&`/`||`, and comments.
  - Recommendation: adopt it (it is what mergeability requires), with a config check that warns on bindings whose meaning changes, and release notes.
  - This is listed here because it changes user configs; no choice is needed unless Alan wants the old parser kept.

### Test strategy per slice

Every slice:
- the full suite with `swift test --arch arm64`;
- the script tests;
- `make upstream-guard` in strict mode, with no pristine or hooked errors;
- a build of the exact candidate commit (`make build`, then the release build through `make ship`);
- the CLI golden outputs, where differences are allowed only where the slice intends them and are listed in the candidate notes;
- the config corpus;
- persisted-state fixtures loading from the previous Preview's formats.

Before every build or test, check `pgrep -fl 'make ship|xctest|swift-test|swift-build'` and wait while another run is active.

| Slice | Extra tests |
|---|---|
| S1 | none beyond the standard set |
| S2 | The config corpus parses identically, including error positions and wording (allowed: upstream's diagnostic wording, listed). Round-trip of WinMux sections. TOML 1.1 syntax cases. |
| S3 | A CLI exit-code table for every command (WinMux and upstream) against the golden file. `on-window-detected` with table and command `if`. |
| S4 | Floating window bind, restore and drag tests over the new container. Golden Gate VM smoke: open, float, unfloat and move synthetic windows across workspaces. |
| S5 | A binding/callback corpus through the new shell, with each parse result compared to the old one (differences reviewed one by one for D3). `exec-and-forget` limits. Sidebar pointer-keeping on callbacks. |
| S6 | Cancellation tests for the AX worker under app termination (existing `AxAppWorkerTest`). FFM off by default: no focus changes on mouse move. |
| S7a | Mechanical: suite plus golden outputs. |
| S7b | Display-model tests: connect and disconnect, display key re-association, project per display, saved-workspace display affinity, stub workspaces, startup focus. Frozen and saved schema migration fixtures. Golden Gate VM with two virtual displays where available, otherwise a recorded hardware check by Alan. Highest-risk slice. |
| S8 | The liveness evidence-table tests through the hook, with status mapping and mutation checks per row. Tab groups over tombstones. Lock-screen no-decision test. |
| S9 | Side-table migration tests (`UInt32` → `OpaqueWindowId`). Persisted native-id tables round trip across restart. Golden output for D1. Heuristic gate for D2. |
| S10 | Both test frameworks run. Concurrent native-state queries with the WinMux cache: cache invalidation tests. `Point` conversions in drag geometry tests. |

User-visible risk per slice:

| Slice | Risk |
|---|---|
| S1 | None. |
| S2 | Config error messages change wording. A config that parsed under TOMLKit might be rejected or accepted differently (corpus test). |
| S3 | Some CLI exit codes change for scripts. `on-window-detected` gains command-valued `if`. |
| S4 | Floating windows: restore position and drag behavior. |
| S5 | Binding and callback parsing (D3). |
| S6 | Callbacks finish even when a refresh is superseded. FFM becomes available (off). |
| S7a | None intended. |
| S7b | Which workspace each display shows after connect/disconnect/wake, project per display, saved workspaces' displays. The most visible slice. Ship it alone with a longer Preview soak. |
| S8 | Windows on other Spaces, minimized, or with stale AX elements: when they are laid out, kept or dropped. Close detection timing. |
| S9 | Window ids in output (D1). Native tabs (D2). |
| S10 | Mostly internal. Native-state query concurrency could change timing of fullscreen and minimize detection. |

## Review and release rules (every phase and slice)

- Behavior-neutral refactors (phases 1 and 2) keep the full suite green at every commit.
- Each phase ends in one candidate commit. Astra and Carbon both review it, and fixes continue until both say SHIP. Build that exact commit, then `make ship` (Preview only, never stable). Phase 3 slices each ship separately.
- Policy hooks carry mutation checks.
- No live apps or personal windows. The Golden Gate VM is used only for explicit hardware-behavior checks, with synthetic data, and is stopped afterwards.

## Steady state

1. Run `make upstream-report` every 2–4 weeks or at each upstream release.
2. Run `script/upstream-sync.py merge` on a branch. Resolve:
   - hooked: re-apply hook lines;
   - forked: port deliberately and log the decision in `docs/upstream-backports.md`;
   - moved: port.
3. Run `script/upstream-sync.py finish`, then the standard tests, then the strict guard.
4. Review, then Preview.
5. Never rebase upstream. Cherry-pick only urgent fixes, with `-x`; the next merge reconciles them.
6. A new WinMux need in an upstream file means a new hook or registry entry, never an in-place edit of upstream logic. The strict guard enforces this from the end of phase 2.
