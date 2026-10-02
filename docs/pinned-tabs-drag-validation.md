# Dragging pinned tabs — September 28, 2026

In Tabs mode the pinned tiles now take part in drag and drop both ways.

- A tab dragged from the list beside a tile is pinned there. A vertical line between
  the tiles marks the spot; the empty cells after the last tile put it last. With
  nothing pinned, **Drop to Pin** over the search row works as before.
- A pinned tile drags as its whole tab, split or empty: beside another tile to
  rearrange the pins, into the list to unpin it where it's dropped, onto a group to
  unpin it into the group, or onto **New Tab** to unpin it in place. The tile stays
  dimmed and the pointer carries its icon until the drop. With every tab pinned, the
  empty list below still takes a pin.
- A tile takes a dropped window as a tab in the list does: moving across it places the
  tab beside it among the pins, and a brief pause over it arms a split, with the half
  under the pointer highlighted. Dropping then tiles the window beside the pin's window
  on that side; the tab stays pinned. An empty pin takes the window in, and a window
  dragged in from the screen joins the pin (added September 28, after 0.6.372). For
  windows from the screen, the tile under the pointer now wins over a neighbor that only
  the drop slop reaches, in the list as well as among the pins.
  Dragging a pinned tile over another rearranges; pins don't split with each other.
- The pins' order is saved as `pinOrder` beside each pin in `sidebar-organization.json`,
  so it survives relaunch. Rearranging pins doesn't change the tabs' own order, so an
  unpinned tab returns to its place in the list. A tab pinned from its menu goes
  after the pins already arranged. Files without `pinOrder` load unchanged.
- Next/previous and numbered tab commands follow the pins' new order.
- Pins in All Projects (`pinScope: "allProjects"` beside the pin; files without it load as
  project pins) sit in an upper section above the project's own. A pin dragged into the other
  section moves there, still pinned; one coming down joins the pins of the project shown. Each
  section has its own order, and tab navigation shows the upper section first.
- Each drop can be undone (**Undo Move Tab**, **Undo Pin Tab**, **Undo Unpin Tab**,
  **Undo Pin to All Projects**, **Undo Pin to This Project**).
  A drop that can't save its pin or group change, such as with a read-only
  organization file, changes nothing.
- The compact rail's tiles don't drag.

## Checks

- Swift 6.4, ARM64, worktree based on `cd723620`.
- 20 regressions in `WorkspaceSidebarPinnedDragTest` cover arranged and unarranged
  pin order, rearranging (including no-op positions), pinning a list tab beside a
  pin, unpinning into list gaps, rows, groups, New Tab and the all-pinned list,
  pinned splits and empty pins, the drop-target geometry and rendered targets,
  read-only organization and saved-workspace stores (across projects too), a group
  removed before the drop, a tab whose name is reused during the drag or before
  its drop runs, undo, and reload of older files. Each fix was reverted in turn and
  a test failed.
- Offscreen renders checked the insertion line at both outer tile edges in light
  and dark appearances.
- Full host suite: 1652 tests, 7 skipped, 0 failures, and 1675 with the split change
  on the newer main. ARM64 build passes.
- Native, in the `winmux-tests` Tart VM (macOS 27, unsigned candidate, synthetic
  CGEvent drags with TextEdit windows): pinning onto Drop to Pin, after and before a
  tile, rearranging, unpinning into a list gap and below the last tab, an empty pin
  dragged into the list, clicking tiles to focus their windows, the tiles' context
  menu, and the arranged order after relaunching WinMux. The host Mac was locked.
- Split change, natively in the same VM: a tab paused over a tile's left half
  highlighted that half and joined the pin on the left; a quick drag across a tile
  pinned the tab after it instead; a window dragged by its title bar from the screen
  onto a tile highlighted the whole tile and joined that pin.
- Not verified natively: two displays, several projects, browser-group tiles, and
  more than three rows of pins. The mouse-up cleanup that drops a pin when its
  gesture ends without the end callback has no test: it needs a real panel under
  the pointer, and the gesture ended normally in every native run.

## Review

Astra xhigh (`codex/gpt-6-astra`, via Paseo) and agy (`gemini-3.8-flash-high`)
reviewed the diff independently, with a follow-up after each round of fixes. In
the first round Astra found that an empty pin couldn't be dragged, that with every
tab pinned nothing unpinned by drag, and that a failed unpin could leave a tab in
another project; agy found that a pinned split couldn't move as one tab and that
the whole-area target was always hidden by the tiles. Those led to the tab-level
drag, the all-pinned drop below the list, New Tab unpinning, and unpinning before a
project move. Later Astra rounds found a cross-project group drop that still
half-committed (agy's follow-up found it too), a drop that could apply to a tab that
reused the name, drops lost when a gesture never ends, and groups removed before
the drop. All are fixed, and all but the lost-gesture case have regression tests. agy's claims that the gesture blocks drag-scrolling, that a
self-anchored move crashes, that failed drops record undo entries, and that the
mouse-up cleanup leaks drag state did not hold up against the code. Both
reviewers' final verdict was ship. Reports are under ignored
`.local/reviews/pinned-drag-20260928/`.

For the split change, Astra found that a screen drag's hit slop let a neighboring tile,
or the empty-row band, take a drop aimed at the tile under the pointer; agy found the
band issue too, and a possible floating-point sliver band after a full row. Hit testing
now prefers the target under the pointer, screen drags skip the pins' gap targets, and
the band follows the column count. Both also noted that a release a pixel past a
tile's midpoint commits the position shown at the last drag event; that is kept, as
in the list. Both reviewers' final verdict was ship.

Known limitation: a cross-project drop into a group makes two organization writes.
If the second fails with an I/O error, the tab ends up unpinned in the target
project, outside the group. Read-only stores are rejected before anything changes.
