# Settings

Settings has six pages. The last page, Advanced tab, window size, and per-page
scroll positions are retained. Right-click a workspace tile and choose
**Customize Dock & Sidebar…** to open the appearance controls directly.

| Page | Controls |
| --- | --- |
| General | Startup, automatic TOML reload, menu bar, permissions |
| Dock & Sidebar | Mode, position, visibility, separate compact/expanded appearance, content |
| Windows & Layout | New-window behavior, default layout, window chrome, tabs, tiling gaps |
| Projects & Workspaces | Project deletion, saved workspaces, persistent workspaces, shortcut preset, workspace shortcuts |
| Shortcuts | Window-management shortcuts and directional controls |
| Advanced | TOML Editor, automation actions, performance diagnostics, configuration reference |

## Preview and dependent controls

Choose Dock or Sidebar first. Left/Bottom/Right buttons explain native Dock
auto-hide behavior. The interactive sample uses WinMux's existing shelf material,
workspace tile, and magnification geometry; it does not control sample windows.
It responds immediately to slider drafts, which save when dragging finishes.
Color changes save after a short pause. Toggles and menus save immediately.
Text fields use **Apply** or Return; automation actions use **Apply**.

Only relevant controls appear: Liquid Glass shows opacity, Solid color shows its
palette, Custom shows a color picker, and clock/tab options follow their parent
toggle. Compact Dock and Sidebar/expanded-panel appearance remain separate.
**Maximum icon size** explains adaptive sizing and reports the current fitted
size when a running panel is smaller. Magnification is displayed as a multiplier.

Search matches labels, help, and TOML keys. Results open their page and reveal the
setting. Hidden controls appear disabled with instructions for enabling them.
Diagnostics and permission searches link directly to their sections.

## Saving and recovery

Form, automation, and TOML changes use one serial save queue. The footer shows
unsaved, saving, saved, and error states. Failed writes retain drafts and queued
edits for **Retry** or **Revert unsaved changes**. Each form section has
**Restore Defaults**; that operation creates one Undo entry.

**Undo** restores the last successful form/TOML transaction only if the file and
preferences still match that transaction. External edits invalidate the history
instead of being overwritten. Shortcut recording retains its existing save path.
Valid external configuration reloads update clean controls; active drafts remain.
Unsaved TOML text survives page switches and resizing. Saving that text requires
the disk file to match the version originally loaded.

Existing TOML keys and CLI commands are unchanged. Surgical edits preserve
unrelated content, including multiline values and equivalent dotted/subtable keys.
Unsupported inline-table edits fail visibly before writing; use the TOML Editor
for those layouts. A form edit refuses an already-invalid file; the TOML Editor
can repair it. Formatting and trailing comments on edited values may normalize.
Persistent workspaces require `config-version = 2`.

## Validation

Use the pinned Swift 6.2.4 toolchain and ARM64:

```sh
swift test --arch arm64 --filter 'SettingsEditorTest|ShortcutSettings'
swift test --arch arm64
swift build --arch arm64
```

Regression checks cover queued failures/retries, rapid changes, preference and
section Undo, external conflicts, multiline/CRLF TOML, conditional preview state,
minimum/wide windows, native editor focus, page-switch retention, and search
reveal priority. Interactive light/dark appearance, VoiceOver, and pointer-driven
preview checks require an unlocked macOS desktop.

### Local results (2026-09-19)

- Swift 6.2.4: **951 tests, 7 opt-in skips, 0 failures**. ARM64 debug app and CLI
  build passed; both executables report ARM64 only.
- Independent Claude Fable 5 and agy Gemini 3.8 Flash High reviews led to fixes
  for failure/retry completion, automation drafts, malformed TOML protection,
  quoted/multiline and CRLF handling, child-before-parent table insertion,
  search/scroll ordering, and accessibility labels. Targeted follow-ups reported
  no remaining supported findings.
- Interactive appearance and VoiceOver checks remain pending: the Mac was locked.
  Offscreen scroll-layer captures were incomplete and were not accepted as visual
  verification. Automated AppKit geometry, resize, focus, and scroll checks passed.
