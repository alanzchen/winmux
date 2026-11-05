# Window rules

Tabs mode only. A window rule names a window of an app, such as an image viewer, that should float over
the window it was opened from instead of taking a tab of its own. The named window:

- floats at the size the app gave it, over the window it was opened from, in that window's tab;
- is listed under that window in the sidebar, and counted on a pin's tile instead of becoming another cell.

Every other window is placed as before.

A rule only describes windows; nothing in a rules file runs. A rule is asked about a window only when
WinMux first sees it, and only when it was opened from a window of the same app that was in use, just
after a click or key press, appearing directly above it. A window already placed, by you or by WinMux, is
never moved by a rule, and a rule never closes, hides or resizes a window to full screen.

## Files

- WinMux's own rules ship with the app (`default-window-rules.toml`). Updates replace them; don't edit them.
- Your rules go in `~/.config/winmux/window-rules.toml`. Run **Reload Config** after editing it.

## WinMux's rule: WeChat's image viewer

One rule is on by default, with the id `wechat-image-viewer`. A WeChat window titled exactly
`Photos and Videos`, a standard window, opened from a WeChat window in use just after a click or key press,
floats at its own size over that window.

- Only the English title is covered. With WeChat in another language, add your title by replacing the rule
  in your own file, keeping its id:

  ```toml
  version = 1

  [[rule]]
  id = "wechat-image-viewer"
  app-id = "com.tencent.xinWeChat"
  window-title = ["Photos and Videos", "your title"]
  subrole = "AXStandardWindow"
  opened-from = "focused-window"
  action = "float-under-opener"
  ```

- The rule names windows by their title. Another WeChat window with that same title, opened the same way,
  would float over its window too.
- To turn the rule off, put this in your own file:

  ```toml
  version = 1

  [[rule]]
  id = "wechat-image-viewer"
  enabled = false
  ```

## A rule

```toml
version = 1

[[rule]]
id = "my-image-viewer"                 # letters, digits, '-', '_' and '.'
app-id = "com.example.app"             # the app's bundle id, exactly
window-title = ["Photos and Videos"]   # the window's exact title, in each language you use
subrole = "AXStandardWindow"           # optional: the window's accessibility subrole, exactly
opened-from = "focused-window"         # the only value
action = "float-under-opener"          # the only value
```

- Titles match exactly, after spaces around them are trimmed, and are case-sensitive. List each
  translation you use: a title the rule doesn't list isn't matched.
- A title can be shared by two different windows of an app. A rule names every window with that title
  that's opened from another of the app's windows, so choose titles that only the window you mean has.
- `winmux debug-windows` shows a window's title, subrole and bundle id.

## Your rules and WinMux's

- A rule in your file with the id of one of WinMux's replaces it whole.
- `enabled = false`, with only the id, turns one of WinMux's rules off.
- Your other rules are added after WinMux's. The first rule that names a window applies.

## When a rule can't be used

- A rule with a mistake is left out, and the rest still apply. Mistakes include a missing or misspelled
  key, a key rules don't have (such as `run`), a value other than the ones above, or a repeated id.
- A file that isn't a rules file is left out whole: invalid TOML, or a version other than `1`. Your own
  file being left out never changes WinMux's rules.
- What was left out, and why, is shown after Reload Config, and printed by `winmux reload-config`. The main
  config is unaffected either way.
- At most 64 rules are read from a file, and 32 titles from a rule.

## Its windows

A window placed by a rule behaves like any other window opened from another:

- **Its own tab:** moving it to a tab of its own makes it an ordinary window for good.
- **Opener closed:** if the window it was opened from closes, it stays open as a window of its own.
- **Restart:** after WinMux restarts, it's listed under its opener again while both are still the same
  windows.
- **Saved layouts:** it isn't saved into a tab's or a pin's layout.
