# Settings

Settings has six pages. The last page, Advanced tab, window size, and per-page
scroll positions are retained. Right-click a workspace tile and choose
**Customize Dock…** or **Customize Sidebar…**, or click the gear at the bottom of
the Tabs sidebar, to open the Workspace Panel page directly.

| Page | Controls |
| --- | --- |
| General | Startup, automatic TOML reload, menu bar, permissions |
| Workspace Panel | Panel switch and mode cards; the active mode's settings; settings every mode shares |
| Windows & Layout | New-window behavior, default layout, window chrome, tabs, tiling gaps |
| Projects & Workspaces | Project deletion, saved workspaces, persistent workspaces, shortcut preset, workspace shortcuts |
| Shortcuts | Window-management shortcuts and directional controls |
| Advanced | TOML Editor, automation actions, performance diagnostics, configuration reference |

## Workspace Panel

The panel switch and three mode cards, Dock, Sidebar, and Tabs, stay at the top.
Choosing a card switches the running panel. Below them are the live preview, the
active mode's sections, and **Shared across modes** (which displays' workspaces to
list, the Focused filter, menu bar space, keeping above the macOS Dock, and a
read-only summary of which displays have a panel, with a link to edit `monitor` in the
TOML Editor). There's no editing of another mode's settings: the modes
share one configuration, so other modes' rows are hidden. A row that also changes
other modes says so, and a shared key can have a different label in each mode.
For example, `width` is Project column width on a Dock that can collapse, Panel
width on one kept expanded, Expanded width in Sidebar, and Sidebar width in Tabs.

Turning on Tabs mode's panel moves window stack entries into separate tabs, which
Undo can't rebuild. When stacks with more than one window exist, any Settings save
that would do that asks first: a mode card, turning on a panel set to Tabs, a TOML
Editor save, a save retried after a failure, an Undo, or any save that would load a
switch to Tabs made in another editor. The question comes as the save is about to
run, and the page keeps showing the running mode meanwhile. Later saves wait behind
it; a new edit drops an open Undo question instead.
Picking Tabs while the panel is off doesn't ask. If a mode can't be saved, its card says
**Not applied** while the running panel keeps the previous mode.

A section's **Restore Defaults** resets only that section's rows; its menu names
the other modes any of them also change. Each mode, and the page with the panel
off, keeps its own scroll position. With the panel off, only the switch and cards
remain.

Search names the mode and section of each result. Opening a result from another
mode, or any panel setting while the panel is off, shows it at the top of the page,
disabled, with **Use Dock** (or the mode it belongs to) and **Turn On the Panel**.
Opening a result never switches the mode by itself.

## Preview and dependent controls

The Dock's Left/Bottom/Right buttons explain native Dock auto-hide behavior. The
Dock's interactive sample uses WinMux's existing shelf material, workspace tile,
and magnification geometry; it does not control sample windows. Sidebar shows its
rail at the collapsed width; **Expanded** shows the expanded surface. The Tabs preview shows sample rows on the Tabs background, with
badges and browser tabs when those settings are on.
It responds immediately to slider drafts, which save when dragging finishes.
Color changes save after a short pause. Toggles and menus save immediately.
Text fields use **Apply** or Return; automation actions use **Apply**.

Controls follow what the running panel uses. Settings for another mode are
hidden, and so are unselected alternatives: Liquid Glass shows opacity, Solid color
shows its palette, and Custom shows a color picker. A setting that depends on another
stays in view, disabled, and says what to change. Examples are seconds under the
clock, the magnification amount, and compact-Dock settings while the Dock is kept
expanded. When a mode fixes a behavior, the row says so instead of showing a switch;
in Tabs mode, New Tab always opens the launcher. Tabs mode has no window stacks, so
their settings are hidden while its panel is on, and Window tabs says why. Compact Dock and
Sidebar/expanded-panel appearance remain separate.
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

Use the Swift pinned in `.swift-version` and ARM64:

```sh
swift test --arch arm64 --filter 'SettingsAvailabilityTest|SettingsPanelPageTest|SettingsEditorTest|ShortcutSettings'
swift test --arch arm64
swift build --arch arm64
```

Regression checks cover:

- queued failures and retries, rapid changes, and preference and section Undo;
- external conflicts, and multiline and CRLF TOML;
- minimum and wide windows, native editor focus, and page-switch retention.

They also check:

- which modes each setting is shown in, which follows what the running panel reads;
- the draft projection, which matches what saving writes, including the Dock's
  inherited look and defaults that follow the mode;
- that each mode's sections list exactly the settings it uses;
- that a revealed search result is inside the visible area, including other modes'
  results, the panel-off page, and after switching mode;
- the Tabs question across queued, retried, TOML Editor and Undo saves, and saves
  that would load an external switch to Tabs;
- that a section's Restore Defaults leaves other modes' settings alone;
- that each mode keeps its own scroll position.

Interactive light and dark appearance, VoiceOver, and pointer-driven preview checks
require an unlocked macOS desktop.

### Local results (2026-09-28, mode-aware Settings)

- Swift 6.4, ARM64: **1625 tests, 7 opt-in skips, 0 failures**; the debug build
  passed.
- Independent reviews used ChatGPT Astra (xhigh, through Paseo) after each phase
  and agy Gemini 3.8 Flash High. Their findings led to these fixes:
  - unset defaults kept as unset in drafts, and draft cleanup matching intent as
    well as value;
  - alternatives hiding before the panel-off check;
  - the empty Window tabs group explaining itself;
  - the Tabs question judged against the file each save will write, and covering
    queued, retried, TOML Editor and Undo saves without replacing newer drafts;
  - per-mode scroll rebinding;
  - the display summary following runtime resolution;
  - Sidebar's rail preview, and VoiceOver hearing "Not applied".
- Offscreen renders of each mode's page, narrow and wide, were checked for layout.
  Liquid Glass surfaces don't render offscreen.
- Native check in the `winmux-tests` VM (macOS 27, unsigned build of f0826e4a;
  the later Undo-question change is covered by unit tests only):
  - **Customize Dock…** opened the Workspace Panel page.
  - With a two-window stack, the Tabs card asked first. **Cancel** left Dock mode
    and the stack unchanged. **Use Tabs** switched the running panel and split the
    stack into two tabs.
  - **Undo Mode** returned to Dock without asking, and the stack stayed split as
    the note says.
  - The Sidebar card applied without asking and showed the rail preview.
- Not checked natively: VoiceOver on the cards, multiple displays and `monitor`,
  Reduce Transparency and Reduce Motion notices, and real hardware.
