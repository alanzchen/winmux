# Native accessibility regression fixtures

## Zen Save As routing (#23)

`zen-1.21.16b-save-panel.json` contains reduced **actual native AX observations**, captured on September 15, 2026 with Zen **1.21.16b**, bundle build **126.8.28**, and macOS **26.6.2 (25G83)**. Zen came from its official GitHub release and ran from a mounted application with an isolated test profile and a local HTML page. No browsing data was imported, no default-browser change was made, and no file was saved.

Window and process IDs are normalized to stable integers. Titles, page content, user paths, unrelated applications, and unrelated save-panel service processes are omitted. `browserBeforeSave` and `browserWithSavePanel` identify the same native browser window. The service window's AX element belongs to Zen's process while its parent belongs to the save-panel service process; the fixture preserves that distinction.

### Captured behavior

- Before Save As, Zen's focused AX window is its ordinary top-level browser window.
- With Save As open, Zen reports an `AXSheet` with identifier `save-panel` as its focused window. Its parent and `AXWindow` relationship point to the browser. It has its own native window ID at normal window level and is absent from the app's canonical `AXWindows` list.
- Opening Format leaves that focused-window reference unchanged. A native menu window appears at level 101.
- The remote open/save service exposes an `AXWindow` with subrole `AXSystemDialog`, identifier `SavePanel`, and no window buttons.
- The sheet reports `AXFocused = false`, but the application's focused-window reference points to its containing window ID. That reference equality satisfied the former Firefox-family window heuristic and allowed the sheet into routing callbacks. The regression test recreates that exact condition.

The `_NS:8` dialog observed during first-run onboarding was not identified as part of Save As and is **not** used as a classifier or fixture.

### Native integration check

The current WinMux build ran with `--read-only` and an isolated configuration containing the original routing rule:

```toml
[[on-window-detected]]
if.app-id = 'app.zen-browser.zen'
if.during-winmux-startup = false
run = ['move-node-to-workspace z']
```

Sidebar, tab chrome, and shortcut bindings were disabled. The browser was first moved to workspace `1` in WinMux's internal model. During a fresh Save As → Format → dismiss Format → Cancel sequence:

- The browser remained the only managed Zen window, on workspace `1`.
- Looking up the actual sheet ID with `debug-windows --window-id` returned “Can't find window with the specified window-id”. No open/save service window appeared in the managed-window list.
- The browser's native frame remained `(x: 0, y: 30, width: 1920, height: 960)` before, during, and after the interaction.
- A newly created independent blank Zen window routed to `z`, while the original browser remained on `1`.

The test-created Zen instance was then quit. WinMux's read-only mode suppresses native writes; this check verifies actual AX classification, model registration, and routing while preserving the host's window positions. It does **not** verify physical workspace hiding or focus/stacking effects with native writes enabled. The native AX tree was readable, but the UI automation screenshot endpoint could not capture the open Format menu, so no screenshot fixture is supplied.

`AxTransientWindowTest` replays the captured sheet and service records. Additional synthetic cases cover standalone dialogs, picture-in-picture, non-native fullscreen, unknown ownership, canonical focus references, and cyclic accessibility ancestry.

## Safari's crowded tab bar

`safari-27.0-crowded-tab-bar.json` is a reduced **actual native AX capture** of one Safari **27.0** window on macOS **27.0 (26A428)**, taken on September 29, 2026 in an isolated VM during the browser-tab CPU audit. The window was 704×680 points with 24 static local pages open, the first tab active, and the tab bar scrolled to its end.

Tab titles are replaced with `Tab NN` in tab-bar order. Page content, the tabs' favicon and title-text children, the address field, the window UUID, and process IDs are omitted. The window keeps its top-level structure (split group, toolbar, tab bar, window buttons), so discovery walks what Safari exposes.

### Captured behavior

- The tab bar, an `AXOpaqueProviderGroup` described as "Tab bar, 24 tabs", lists all 24 tabs among its `AXChildren`.
- Tabs 02–08 sit outside the visible bar (frame `0,736 32×32`) and answer `AXParent` with error −25212 (`kAXErrorNoValue`). Every other tab, including the active one, names the tab bar.
- Every tab answers `AXSelected` with error −25205 (attribute unsupported); `AXValue` carries the selection.

### Native check with 40 tabs

The same day, WinMux's scanner code ran natively against one Safari window with 40 local pages, opened by AppleScript with the first tab then selected:

- Tabs 02–08 again answered `AXParent` and `AXWindow` with `kAXErrorNoValue`. Safari accepted `AXPress` and the tab's close action on them, returning success, but did neither, even after `AXScrollToVisible`.
- Tabs 09–24 sat piled at one position. They answered `AXTitle` with `kAXErrorNoValue` while `AXDescription` held the title, and offered only `AXScrollToVisible`. After scrolling one into view it offered `AXPress` and close, and pressing it selected it.
- Once any tab had been selected through `AXPress`, every tab named the tab bar again.

WinMux used to require every tab to name its container and to have a title, so these windows never became browser tab groups. `BrowserTabsTest` replays the capture and checks that the whole group appears; that a tab out of view is scrolled into view before it's pressed or closed, and is refused rather than reported done if it still names no parent; that a piled-up tab is named by its description; and that the guards against foreign and stale controls still hold.
