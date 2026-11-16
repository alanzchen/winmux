# WinMux's TOMLDecoder patch

Base: [dduan/TOMLDecoder](https://github.com/dduan/TOMLDecoder) 0.4.5 (`a2bbd279`), library sources only, unchanged
except the lines marked `WINMUX-PATCH` in `Sources/TOMLDecoder/Parsing/Parser.swift`. Drop the vendored copy for an
upstream release that fixes both defects below; until then, update by re-applying this patch to a new upstream tag.

Written to be reported upstream as is.

## 1. A multiline basic string ending in an escaped backslash never closes

The lexer treats a `"""` as escaped whenever the byte before it is a backslash. A backslash that is itself escaped
doesn't escape the quote:

```toml
a = """C:\\Users\\"""
```

TOMLDecoder 0.4.4/0.4.5: `unterminated triple-d-quote`. TOML 1.0/1.1 and `tomllib`: `a = 'C:\Users\'`.

Fix: count the run of backslashes before the quote; the quote is escaped only when the run is odd.

## 2. `\u`/`\U`/`\x` escapes and line-ending backslashes don't end a run of quotes

`basicString` counts consecutive quotes in a multiline basic string to reject `"""` inside it, and resets the count
after an escape, except after a Unicode escape and after a line-ending backslash. The quotes on either side are then
counted as one run:

```toml
a = """x""\u005C"y"""
b = """x""\
"y"""
```

TOMLDecoder 0.4.4/0.4.5: `basic multiline strings cannot contain more than 2 consecutive double quotes`. TOML and
`tomllib` accept both: `a = 'x""\"y'` and `b = 'x"""y'`. In `b` the line continuation joins `x""` and `"y`; the quotes
are not adjacent in the source, so they are not three consecutive quotes.

Fix: reset the count after those two escapes, as after every other one.

## Not patched here

WinMux's `WinMuxToml` front end (`Sources/AppBundle/WinMux/WinMuxToml.swift`) handles the rest outside the library:
contiguous UTF-8 for `Token.unpackAnyValue`'s force-unwrap, CRLF in multiline strings, a missing final newline, a
leading byte order mark, a lone CR.
