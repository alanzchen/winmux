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
- `joinTruncating` appended an ellipsis when the last element fit exactly. Exact fits now remain unmarked; partial/omitted elements still indicate truncation.
- `parseCommand` and the settings canonicalizer accepted command-name prefixes such as `exec-and-forgetful`. Shared parsing now requires the exact command name followed by whitespace or the end of the string, preserving the Bash suffix verbatim.
- Topic inference could start after the total request deadline, or cache a late answer if timer delivery lagged. Regression tests use a manual clock and a delayed timer to test elapsed time independently of executor scheduling.

## Retained code and remaining audit work

Compatibility remains intentional: Safari v1 negotiation/fallback, old saved workspace names, socket version handling, AX fallback, persisted integration fields, and native test synchronization/reset seams all have current purposes. Release scripts named `ci-*` also support local publication and manual hosted workflows.

Further candidates need a separate coverage migration before removal: `dockMagnificationPointer`, `closeWorkspaceSidebarSplitWindows`, `showsProjectName`, and `bestNewWindowMenuItemIndex` have test-only callers but their tests protect meaningful interaction or matching policy. Unreferenced UI conveniences were recorded locally rather than swept into this change.

The opt-in real Apple Intelligence evaluation is observational: it prints expected groups without asserting them, and unavailable/error runs can finish without meaningful inference. It must not be counted as accuracy or latency acceptance coverage. Deterministic fake-provider policy/coordinator tests remain the automated behavioral checks; future evaluation work should distinguish unavailable/skipped runs and assert that measured inference actually occurred.

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
