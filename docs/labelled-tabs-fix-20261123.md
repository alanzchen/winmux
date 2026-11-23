# Labelled tab correction: release notes and implementation

Renaming a tab no longer makes it permanent. When its last window closes, it leaves the list
and its saved identity expires after the usual grace. Pin it or choose **Keep Tab When Empty**
to retain an empty tab. **Stop Keeping Empty Tab** and **Forget Saved Workspace** keep current
windows and the name for now, then let normal empty-workspace cleanup remove the identity.

Numbered workspace and move shortcuts follow the active project's tab order. An explicit
configured nonnumeric label binding can target that exact label within the project. Foreign
and archived label targets are rejected without moving or reviving them. This also means a CLI
command, binding or window rule cannot target a labelled workspace in another project; it fails
and leaves the window in place. Unlabelled workspace names retain their existing cross-project behavior.

## Ownership and retained changes

- `Workspace.isKeptWhenEmpty`, `isExplicitlyKeptTab` and `retainsTabAfterLastWindowCloses` in
  `SavedWorkspaceLifecycle.swift` own retention. Labels never enter those decisions.
- The existing optional `SavedWorkspaceRecord.keepWhenEmpty` distinguishes an explicit Keep
  (`true`) from a legacy/implicitly saved identity (`nil`) and automatic group inheritance
  (`false`). The menu's Keep action sets true; renaming and saving restoration data do not.
  Existing records keep their pre-#27 behavior; no schema or storage migration is needed.
- Lifecycle, last-window focus, Tabs visibility and menu snapshots read that owner. Config-persistent
  identities still remain unlisted while empty; only a pin or the UI Keep choice lists an empty tab. Saving a
  name still reserves restoration data during grace; it is not the same as keeping an empty tab.
- Restore the original startup deferral and orphan-label cleanup, including legacy draft labels.
  Labels are metadata for live or saved identities: after startup restoration, an orphan label
  is removed from `winmux.toml`, including a hand-written config label whose workspace never appeared. A pruned
  workspace's label is removed too, matching the restored pre-#27 contract.
- Sidebar-mode Save keeps its previous semantics; only Tabs-mode Keep writes the explicit flag.
  Keep writes once, reports persistence failure and rolls back using existing saved/runtime
  identity rollback support. Literal workspace names take precedence over display-label aliases.
- Keep #27's automatic-name reservation while a configured label is pending restoration, and
  explicit close of an empty labelled tab. Neither implies permanent retention.
- Restore the original close/grace, lock-screen, title-gated relaunch, read-only, recovery,
  legacy-draft and Forget tests. Rewrite all ten #27 label cases for the reverted contract;
  none are removed or skipped. Add stock binding, scoped target, archived target, exact label
  binding and explicit Keep/Forget regressions.

Carbon's supplied diagnostic asserts the defects, so its unchanged four cases pass on the
reviewed base and are expected to fail after correction. It is retained as a byte-identical
external diagnostic, separate from the regression tests asserting correct behavior.
