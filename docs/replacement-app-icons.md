# Replacement app icons

WinMux automatically uses replacement application icons exposed by macOS's file
icon service, including icons assigned through Finder's Get Info window. No new
setting or permission is required. Dock and Sidebar icons, window tabs, and drag
previews share the same artwork. Existing badge settings remain independent.

Mounted icon views refresh approximately every five seconds, and when the app
launches, activates, or terminates. Replacing or removing an icon updates the
existing view without requiring pointer movement or restarting WinMux. A failed
lookup keeps the last valid image. The app's bundle path takes precedence over its
identifier, so different installed copies do not share replacement artwork.

## Public API limits

The file icon is authoritative. In a native test, `NSRunningApplication.icon`
retained old artwork after a running application's file icon was replaced, even
when enumerating its application object again. `NSWorkspace.icon(forFile:)`
returned the replacement and is therefore used first.

An image set only through an application's `applicationIconImage`, custom
`NSDockTile.contentView` drawing, and animated Dock tiles are not guaranteed to be
available through these APIs. The native probe on this Mac did not expose an
`applicationIconImage`-only replacement. WinMux does not capture the screen or read
another process's rendering to reproduce those tiles.

## Refresh and performance

The initial bundle image retains the existing synchronous cache-miss behavior.
Subsequent lookups, image preparation, and pixel comparison run on a background
utility task. Only changed artwork publishes an update, and only its icon views
observe that update; the parent Dock layout is unaffected. Refresh requests are
coalesced, and stale completions cannot overwrite a reappeared view.

Icons are cached per application, with at most 128 inactive/active cache entries
unless mounted views require more. Polling and workspace notifications stop when
the final icon consumer disappears. Native resize previews take a cached snapshot
once per gesture.

## Validation

Regression tests cover cache identity and eviction, refresh without input,
unchanged-image deduplication, targeted updates, lookup failure, shared consumers,
coalescing, cancellation, aspect ratio, and native replacement/removal. An
offscreen `NSHostingView` check verifies that the icon repaints while parent body
evaluation and layout bounds stay unchanged. A separate temporary running app
verifies replacement/removal through the production source despite the running
application API's stale cache.

Additional lifecycle checks cover abrupt hosting-view destruction, clearing a
persistent drag-preview host, and workspace-notification targeting across repeated
open/close cycles. Drag previews discard their icon views and flush their empty
layout when the gesture ends; hidden hosting views otherwise defer teardown.

Swift 6.2.4 ARM64 validation on September 19, 2026: **903 tests, seven expected
skips, zero failures**, plus the development app/CLI build. The optional rapid
hover benchmark recorded 2.46 ms and 3.33 ms p99 layout times for eight and twelve
app slots, respectively (unchanged `main`: 2.70 ms and 3.26 ms). Its 32-slot case
failed the same geometry-update assertion on both versions, so that case does not
provide a valid performance measurement. These are CPU/layout timings, not GPU
presentation FPS. An installed-app smoke check and 120 Hz hardware verification
were not performed for this change.

Run the focused tests with the pinned Swift 6.2.4 toolchain:

```sh
swift test --arch arm64 --filter 'AppIconProviderTest|AppIconSourceTest'
```

## Review notes

Claude Fable 5 and agy Gemini 3.8 Flash High completed independent read-only
reviews and targeted follow-ups with no remaining blockers. Accepted findings
added missing-bundle retention, filtering of anonymous notifications, explicit
drag-preview teardown, and lifecycle/notification regression coverage. Raw reports
are kept under ignored `.local/reviews/replacement-app-icons-20260919/`.
