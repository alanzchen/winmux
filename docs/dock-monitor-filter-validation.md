# Dock monitor-filter defaults — September 18, 2026

Each Dock initially selects its own display's existing Monitor filter. Sidebar
mode retains its original Default filter. A menu choice is panel-local and survives
refreshes, expansion, focus changes, and mode changes. Temporarily clearing the
model while disabled preserves the choice; an authoritative monitor list that no
longer contains the selected display falls back to Default.

The own-display Dock filter keeps workspace tiles and app icons clickable. Other
display summaries and Sidebar's display-specific summaries retain their existing
read-only behavior. Applying a filter does not focus or move any workspace.

## Checks

- Swift 6.2.4, ARM64, isolated source excluding the unrelated glass-style draft.
- 41 focused host tests passed, including ten new regressions for panel isolation,
  startup discovery, mode transitions, explicit choices, disconnection, temporary
  model clearing, activation policy, and suppression of redundant publications.
- Native NSPanel synchronization passed on the host and in Tart.
- Complete Tart suite: **825 tests, three expected skips, zero failures**. ARM64
  development build passed.
- The host full-suite run hit `testMagnifiedAppRespondsAtItsProtrudingEdge` while
  its physical display was asleep. The isolated test also failed in the existing
  unchanged host binary. It passed in the VM's active desktop. This environment
  limitation is not counted as a passing host full-suite result.
- Two/three-display selection is covered with model fixtures. Physical multi-display
  connect/disconnect and menu interaction remain unverified on hardware.

## Review

Claude CLI (`claude-fable-5`) and agy CLI (`gemini-3.8-flash-high`) reviewed the
scoped diff and surrounding code independently. Claude identified the temporary
empty-catalog reset; the guard and regression test address it. Initial and targeted
follow-up reviews reported no remaining confirmed blockers. Reports are saved under ignored
`.local/reviews/dock-monitor-default-20260918/`.

No app installation, release, or GitHub CI run is part of this change.
