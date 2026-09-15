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
