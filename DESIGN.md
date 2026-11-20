# Typed tab content

Base: `03b634fa`. This remodel changes the floating thumbnail and missing lent-pin
saved-slot defects. Existing focus, close, recall and parking behavior stays; the
loan restore and downgrade contracts are made explicit below.

## Owner and value

`WorkspaceTabSnapshot`, derived synchronously on the main actor in
`tree/WorkspaceTabSnapshot.swift`, is the one projection of a workspace's tree,
auxiliary registry, pin identity, detached windows, and parking state. Its members
retain window identity, placement (tiled, floating, hidden, fullscreen, minimized,
or not presentable), membership (resident, lent from a pin, or away from a pinned
composition), auxiliary role/opener, and parking outcome. Tiled topology
retains orientation, layout, weights, and most-recent children for persistence and
thumbnail geometry. A loan is a resource of the pin, not a window the pin closes.

Consumers select explicit projections from this value rather than rediscovering
members from containers or the auxiliary/pin registries. The value is a snapshot,
not a second mutable registry. No AX reads occur while deriving it.

## Consumers and duplicate derivations to remove

References below identify the implementation consumers.

| Consumer | Typed projection | Deleted derivation |
| --- | --- | --- |
| `Sources/AppBundle/tree/WorkspaceTabMembers.swift:35` | lifecycle members | tiled/floating/hidden/fullscreen/minimized concatenation and dedup |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarWorkspaceSnapshotBuilder.swift:47` | one capture for items, associated windows, apps and offscreen members | independent list builders' tree/container membership |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarItemSnapshotBuilder.swift:2` | topology, placement, captured auxiliary attachment | direct tree and floating enumeration and auxiliary reclassification |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarContainerItemBuilder.swift:2` and `WorkspaceSidebarTabGroupItemBuilder.swift:2` | captured containers and child representatives | live recursive sidebar walks |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarTabCards.swift:42` | typed window placement | unconditionally treating every pair as a split |
| `Sources/AppBundle/tree/saved/SavedWorkspaceCapture.swift:327` | topology, floats, detached members and valid loan | independent tree walk and detached-list concatenation |
| `Sources/AppBundle/tree/frozen/FrozenWorld.swift:11` and `WorkspaceTabSnapshot+Frozen.swift:4` | actual resident topology and lifecycle members | recursive frozen membership and separate ID enumeration |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarPinLending.swift:74,111,635` | lent member, pin resources and composition-away members | loan/resource/away derivation and recalled placement classification |
| `Sources/AppBundle/mcp/MCPDebugSnapshot.swift:57` | contentMembers, placement, attachment and parking | tab-member classification in debug output |
| `Sources/AppBundle/command/impl/agent/AgentSnapshot.swift:63` and `AgentWorldId.swift:18` | tree members, topology and group representatives | independent workspace membership and pane/relation layout walks |
| `Sources/AppBundle/command/impl/ListWindowsCommand.swift:34` | tree members | CLI workspace traversal |
| `Sources/AppBundle/tree/WorkspaceVisibility.swift:7` | present and lifecycle members | separate visibility/offscreen leaf walks |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarTabUndo.swift:282` | topology, floats, offscreen members and captured recency | undo tree and most-recent recursive walks |
| `Sources/AppBundle/ui/sidebar/WorkspaceSidebarPinDocument.swift:221` and `WorkspaceSidebarPinHome.swift:90` | tree members | pin eligibility leaf walks |
| `Sources/AppBundle/command/impl/agent/AgentWindowTarget.swift:9` | tree members | target inventory leaf walk |
| `Sources/AppBundle/command/impl/agent/Window+AgentHelpers.swift:5` and `TilingContainer+AgentHelpers.swift:18` | captured member placement and typed topology | agent layout reclassification and world-ID tree walk |
| `Sources/AppBundle/intelligence/WorkspaceTopicSnapshot.swift:92` | lifecycle and present members | separate live/readable membership concatenations |

Old public helper names that existing callers or tests use remain thin projections;
the traversal they previously owned is deleted. Command mutation algorithms still
operate on live nodes; snapshots retain source identity for those commands. Existing
TreeNode representative semantics are reused, with the active group header distinct
from each child's tab representative. No second mutable registry is introduced.

## Validation and constraints

Regression coverage will exercise tiled plus floating content, auxiliary children,
lent pins and borrower ownership, absent/offscreen members, parking outcomes, and
saved-layout identity/topology. Existing reviewer probes stay byte-identical.
Run focused tests, the complete suite, arm64 build, and `make upstream-guard`.
All Swift validation waits in a script for other heavy work and uses temporary
HOME, CFFIXED_USER_HOME, XDG_CONFIG_HOME, and TMPDIR. No native window manipulation.

SQLite storage, focus ownership, the sidebar floating section, context-menu policy,
and drag-to-tile are explicitly out of scope.

## Retained loan slots and restore ownership

A loan remains a resource slot of its pin, including while it is absent, but is not
part of the pin's live tiling set. Capture protects the existing slot as detached
and introduces it once on a first capture. The JSON slot stores optional
`membership: lentFromPin`; an omitted key retains the old resident semantics. This
is interpreted by the shared `savedWorkspaceRestoreSlots` projection in
`Sources/AppBundle/tree/saved/SavedWorkspaceRouting.swift`. Both missing-app discovery
and window routing use that projection. Startup omits retention-only loan slots; an
explicit Open Missing Apps request includes the selected pin and establishes the
preferred destination before launching the app. The borrower keeps restoration ownership, including
after its old window identity changes. Explicit reopening from the pin can still
use its resource slot. Resident capture or an explicit claim clears the marker.

Mixed browser cards reuse the existing browser-group header and search selection
ordering: tiled headers precede their browser children, then each floating row and
its children. `WorkspaceSidebarSearchSelection.swift:54` consumes the presentation
instead of treating floats as split headers.

The final full-suite run exposed an unrelated existing icon-cache race: a metadata
lookup treated the disk lock being busy as absence. A separate commit gives the
prepared index one short metadata lock, independent of disk operations, with a
deterministic gated-prune regression. Existing tests are unchanged.

The saved JSON format is version 2. Ownership-bearing layouts encode under `content`;
the new reader also imports the legacy `layout` key. Version 1 readers otherwise
ignore the marker and would claim the loan. A version bump alone is insufficient:
the shipped reader exposes future-version records to its router even when the store
is read-only. The new key makes those records decode with empty layouts in that
reader. Thus a downgrade disables saved-layout restoration, preserves the file
byte-for-byte, and restores full functionality on re-upgrade. An isolated archive
of actual `03b634fa` passed a decoder/router/no-rewrite regression using this branch's
encoded bytes. This is a JSON compatibility boundary, not the deferred SQLite remodel.

The final consumer audit also moved visibility, undo topology and recency, pin-home
and document eligibility, agent target inventory, agent layout descriptions and
world-ID topology to this owner. Hot visibility predicates share the same resident
visitor as full capture, stop at the first match, and never create a root. MRU
traversal is requested only by Undo; lifecycle refresh evaluates presence once. Auxiliary diagnostics use the captured attachment.
Global minimized inventory comes from the same member factory, including orphaned
previous-workspace references. Pin eligibility intentionally keeps the existing
exactly-one-tree-window rule, including auxiliary children.

The settings-scroll failure passed alone on an idle host, then failed deterministically
when queued restoration ran before the new page's document geometry. A separate
commit makes layout own restoration and preserves pending positions while the
document has incomplete geometry. Pointer, keyboard, focus and accessibility
navigation supersede a pending restore; geometry changes do not. No timing
tolerances or original tests changed.
Native hardware checks remain outside this task; regression renders mount SwiftUI
views without an NSWindow.
