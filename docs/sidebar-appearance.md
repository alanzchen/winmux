# Sidebar and Dock appearance

Appearance settings now have separate **Sidebar appearance** and **Dock appearance**
sections. Both remain available whichever mode is selected. Sidebar controls apply
to Sidebar mode and the expanded Dock, including search and window details.
The compact Dock keeps its own glass or solid-color appearance.

Solid-color palettes appear only when **Solid color** is selected, for both Window
chrome and Dock appearance. **Glass opacity** appears only for the Dock's Liquid
Glass style. Switching styles retains the saved color and opacity values.

The **Edge gap** applies only to the compact Dock, at the selected edge. It closes during expansion,
so search, workspace details, and **Keep sidebar expanded** sit flush against the
display edge. Sidebar mode also remains flush.

Choose **Position → Left, Bottom, or Right** under Dock appearance. Bottom uses
a horizontal shelf, temporarily auto-hides the macOS Dock, and restores its prior
setting when you change placement or quit. In every Dock placement, WinMux hides
on the display where the native Dock appears. See [Dock placement](dock-placement.md).

Sidebar retains native regular Liquid Glass with a 70% dark overlay on macOS 26 or
later. A native frosted backdrop underneath increases blur for readability. That
blur stays active while another application has focus, including during search.
**Background darkness** adjusts that overlay without fading text or icons.
Older macOS versions use the frosted backdrop with a dark overlay.
Disable **Blur background** for an opaque dark surface;
macOS Reduce Transparency also uses this opaque fallback.
Workspace cards use subtle tonal fills over that shared backdrop instead of adding
their own glass layers, keeping contrast consistent when search receives focus.

```toml
[workspace-sidebar.sidebar-appearance]
blur = true
background-opacity = 0.70

[workspace-sidebar.dock-appearance]
style = 'liquid-glass'
glass-opacity = 1.0
solid-color = 'midnight'
custom-color = '#191B20'
```

Opacity values accept numbers from 0 to 1. The blur uses macOS's native materials;
there is no numerical blur-radius setting. Changes refresh visible panels without
requiring pointer movement. Expansion fades between the compact Dock and Sidebar
backgrounds; the Sidebar's extra blur is absent from the compact Dock.

Existing flat `workspace-sidebar` appearance keys remain supported. Each omitted
Dock field falls back to its corresponding legacy value. Explicit nested settings
take precedence. Editing Dock appearance in Settings changes only the selected
setting. Editing other window chrome preserves inherited Dock values from the
latest saved configuration in the same atomic update; explicit Dock values remain
untouched.

Tab groups and the switcher retain their separate **Window chrome** controls.

Dock, Sidebar, tab, and drag-preview icons automatically refresh macOS
[replacement app icons](replacement-app-icons.md). Custom drawn or animated Dock
tiles remain subject to the public API limits described there.

## Validation — September 19, 2026

- Swift 6.2.4, ARM64: complete suite **862 tests, six expected skips, zero failures**;
  development app/CLI build passed.
- Tart macOS 26: **19 focused tests, one expected native-bitmap skip, zero failures**.
  A real WindowServer preview compared the previous Sidebar, new Sidebar, and
  expanded Dock over a bright patterned background. The new surfaces were darker,
  more blurred, and clipped correctly at rounded corners. This fixture checks the
  real materials; it is not a screenshot of the installed application.
- Regression coverage includes independent settings, legacy inheritance, live
  snapshot updates, mode switching, darkening without fading content, opaque
  expansion with Reduce Transparency, and atomic edits to commented/CRLF TOML.
- The installed app was not replaced. Manual interaction with the new Settings UI,
  search, and drag gestures in an installed build remains a smoke-check item.

## Review notes

Claude Fable 5 and agy Gemini 3.8 Flash High completed independent read-only reviews
and targeted follow-ups with no blockers. Accepted findings fixed stale-value
rewrites of Dock preferences, loss of legacy defaults, transparency dips during
opaque expansion, and section matching for commented/padded/CRLF TOML headers.
Raw reports remain under ignored `.local/reviews/sidebar-appearance-20260919/`.

Existing Settings limitations remain: externally edited values can require reopening
an already-open Settings pane to update its controls, although valid reloads refresh
the panels immediately. Quoted scalar keys and complex multiline values are not
fully supported by the scalar editor; invalid generated TOML is rejected before
writing. These pre-existing editor limitations were outside this appearance change.
