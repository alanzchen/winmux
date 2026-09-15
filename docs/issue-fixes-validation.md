# Issue fixes validation

Scope: #18, #19, #23, and #21, based on upstream v0.5.4 (`e0ad328e`), combined with all four commits from the fork's `feature/configurable-sidebar-layer` branch through `a1719026`. #20 is deferred.

## Preserved fork features

- `7fdfcf08`: configurable sidebar window level (`workspace-sidebar.stay-on-top`).
- `e96e6fa0`: **Keep sidebar above Dock** settings toggle.
- `1a298626`: settings retain scroll position across reloads.
- `a1719026`: expanded CLI/project automation, explicit agent stdin, stable world IDs, socket protocol negotiation, and matched app/CLI packaging.

The sidebar level applies both when a panel is created and when it refreshes. It coexists with the issue fixes for passive expansion, keyboard ownership, monitor selection, and Override prompts. Upstream's window-pair settings also remain available.

The original issue-fixes-only DMG omitted this feature branch and is superseded by the combined fork build. Use the app and CLI from the same new DMG: the fork's socket protocol v1 rejects incompatible older clients before executing commands. See the [CLI guide](cli.md).

## Reproducible checks

Use Swift **6.2.4**, as pinned in `.swift-version`:

```sh
swift test --filter 'AxTransientWindowTest|TransientNativeFocusTest'
swift test --filter 'NewFloatingWindowPresentationTest|PopupWindowPresentationTest|WorkspaceSidebarInputSessionTest|WorkspaceSidebarMultiMonitorTest|WorkspaceSidebarRenderingTest'
swift test --filter 'WorkspaceSidebar|ConfigTest|Agent|Cli|ProjectLifecycle|SocketProtocol|NewFloatingWindowPresentation|PopupWindowPresentation|AxTransient|TransientNative'
swift test
swift build
python3 -B script/test_validate_appcast.py
```

Validation ran on macOS 26.6.2 (25G83), Apple Silicon.

Final results on September 15, 2026:

- **248 focused fork/issue regression tests passed.**
- **649 tests passed** in the complete `AppBundleTests` suite, with zero failures.
- **`swift build` passed** for the debug application and CLI.
- **5 appcast validation tests passed**, and shell syntax checks passed for the merged release recipes. Both the fork's app/CLI pairing guards and upstream's isolated appcast staging/version checks are retained.
- **`git diff --check` passed.**

Validation used a repository-local Swiftly installation under `.build/issue-fixes-tools`; the system toolchain and shell profile were unchanged. The application build is the SwiftPM debug app and CLI, not a signed release archive.

## Coverage

| Issue | Automated checks |
| --- | --- |
| #18 | Passive versus hover expansion, one editing owner, ownership transfer, inactive/unhandled key passthrough, pointer cancellation, and owner lifetime. |
| #19 | Display scope selection and disconnect fallback, two/three-monitor occupancy, explicit Override, cancellation without reassignment, and native SwiftUI rendering at minimum/default widths. |
| #23 | Real Zen capture replay before/after parent enumeration, repeated transient focus, canonical references, attached controls, service windows, independent dialogs, PiP/fullscreen classification, and refresh focus suppression. |
| #21 | Callback completion and choices made during initial detection, explicit and repeated focus choices, equal native/logical focus, simultaneous detections, a newly focused tiled window, one-time consumption, delayed popup classification, startup/restoration/background/hidden-workspace exclusions, cancellation, and queued native-focus rejection followed by modal dismissal. |

The sidebar rendering checks use native `NSHostingView`/`ImageRenderer` without opening windows. Compact display controls fit 28- and 44-point rails. Override/Cancel controls fit a 96-point card inside the minimum 120-point sidebar, and a 216-point card inside the default 240-point sidebar.

## Zen native reproduction

The native checks below were performed on the issue-fix build before integrating the fork branch. The classification and native presentation implementations are unchanged by that merge; the combined code was rechecked with the full automated suite. Native settings scroll retention was not reverified interactively.

Zen **1.21.16b** ran with an isolated profile and local test page. The actual Save As sheet and service accessibility identities are preserved in the [anonymized fixture](../test-fixtures/accessibility/zen-1.21.16b-save-panel.json); [capture details and integration results](../test-fixtures/accessibility/README.md) explain the failure mechanism.

With the supplied routing rule and WinMux in read-only mode, Save As → Format → Cancel left the browser on workspace `1`, and neither the sheet nor its service acquired a managed-window entry. A new independent Zen window routed to `z`. The browser's native frame stayed unchanged. Read-only mode validates classification and routing but suppresses native window writes.

## Floating-window native smoke

A disposable two-window AppKit helper and a harness linked against the production `AppBundle` objects exercised native AX writes without starting a window-manager refresh over other applications.

- The target was AX focused but behind a covering window. `MacApp.nativeFocus(forceRaise: true)` changed native CG window order from `[cover, target]` to `[target, cover]`, retaining focus on the target. The ordinary activation-only shortcut would have applied because the cached focused ID already matched.
- The awaited presentation path returned acceptance and raised the target.
- A subsequent user-style focus selection stayed in place after 700 ms; no repeated raise occurred.
- A request with a stale expected focus was rejected.
- A request made while the helper was hidden/inactive did not activate it.

The helper was closed after the checks. Automated refresh tests separately verify that rejection leaves logical focus intact through modal dismissal and that callback-selected focus wins.

## Keyboard smoke limitation

A disposable scratch editor accepted app-targeted text while the sidebar was pinned, but this desktop automation sends events directly to the target application. It does not exercise the system-wide event tap or establish actual foreground focus. That result is **not** counted as a pass for #18's live keyboard validation.

Physical typing with the sidebar pinned, clicked/command search, first-keystroke buffering, rename, Escape, outside click, Cmd-Tab, and moving editing between real monitor panels still need an interactive manual pass. The corresponding ownership, activation-policy, and event-dispatch behavior has automated regression coverage.

## Remaining hardware coverage

The host has one physical display. Multi-monitor switching, occupancy, disconnect, and panel ownership use automated model/rendering coverage; physical two/three-monitor and unplug tests remain to be run on suitable hardware. Firefox file pickers, PiP, and fullscreen have classifier regression coverage but were not exercised interactively in Firefox.
