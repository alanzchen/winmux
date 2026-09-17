# Native Dock proportions and glass

The September 17 reference shows a roughly 167-pixel shelf, 104-pixel visible
icons, and 136-pixel spacing between icon centers. Scaling those proportions to
WinMux's fixed 64-point rail gives about 40 points of artwork and a 52-point pitch.

## Default geometry

| Measurement | Previous default | New default |
| --- | --- | --- |
| Fixed rail width | 64 pt | 64 pt |
| Icon canvas | 40 pt | 48 pt |
| Space between canvases | 6 pt | 4 pt |
| Icon-center pitch | 46 pt | 52 pt |
| Compact corner radius | 16 pt | 21⅓ pt |

App icons contain transparent padding. In the native preview, a 48-point canvas
paints approximately 39–41 points of artwork, depending on the icon. The number
tiles use the same canvas. Workspace separator margins remain fixed while the
magnification layout moves the separators. The icon-size setting still accepts
24–48 points, and explicitly saved values override the new default.

## Liquid Glass implementation

Dock mode uses SwiftUI's public `.glassEffect(.clear.interactive(false), in:)`
on one background surface throughout expansion. Apple's
[Liquid Glass guidance](https://developer.apple.com/videos/play/wwdc2025/219/)
describes clear glass as more transparent than the adaptive regular variant.
This choice brings more wallpaper color through than the previous `.regular`
surface; it is an approximation of the reference, not Apple's internal Dock recipe.

The default `glass-opacity = 1.0` retains the full glass effect. A fine inner rim
keeps the clipped shelf edge visible without another glass layer. One outer clip
contains the material; icons and text remain outside the opacity adjustment.
Sidebar mode retains its dark material. Solid, Reduce Transparency, and older
macOS fallbacks retain their existing behavior.

## Native comparison and validation

These are real WindowServer captures of production views in the isolated preview,
using sample workspaces and the same bundled wallpaper. Both material comparison
captures use 48-point icons; the previous capture explicitly selected that size.

| Previous regular glass | Updated clear glass and spacing |
| --- | --- |
| ![Previous material](images/dock-glass-regular-before.png) | ![Updated material](images/dock-glass-clear-after.png) |

Pinned Swift 6.2.4, ARM64: 227 focused sidebar tests and the full 786-test suite,
each with three expected skips and zero failures, plus the application build.
Static native checks cover light/dark appearance, reduced opacity, compact/half/full
expansion, and magnified icons. Live mouse, drag, multi-monitor, and physical
120 Hz behavior were not remeasured for this appearance change.
