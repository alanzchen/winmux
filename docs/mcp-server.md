# MCP server

WinMux can run a [Model Context Protocol](https://modelcontextprotocol.io) server over HTTP, so MCP clients such as
Claude, Codex or Hermes-style agents can read WinMux's windows, tabs, pins and displays, and run `winmux`
commands. A command run this way has exactly the effects it has from the `winmux` command line: it goes through
the same dispatch as the CLI. It's off by default, and it listens on 127.0.0.1 only, so only apps on this Mac can
reach it, unless you let your tailnet reach it through `tailscale serve` (see [Access from your
tailnet](#access-from-your-tailnet)).

## Turn it on

In **Settings → General → MCP server**, turn on **Turn on MCP server**, or in your config:

```toml
[mcp-server]
enabled = true          # listens on 127.0.0.1, this Mac only
port = 41740            # 1024–65535
require-token = false   # true: clients must send the access token
tailnet = false         # true: a second port, for tailscale serve to forward your tailnet to
tailnet-port = 41741    # 1024–65535, not the same as port
tailnet-name = ''       # this Mac's name in your tailnet; empty: its local host name
debug-screenshots = false  # true: offer the screenshot and recording tools (needs Screen Recording)
```

Settings saves these keys to your config file. Reload Config, or editing the file with auto-reload on, applies them.

The server is at `http://127.0.0.1:41740/mcp`. Settings shows whether it's listening, its URL, and an example client
configuration to copy. If the port is taken, Settings and a notice say so: choose another.

## Connect a client

The transport is MCP's Streamable HTTP: JSON-RPC messages sent with `POST` to `/mcp`, each answered with one JSON
response. There's no event stream and no session. Protocol versions `2025-06-18`, `2025-03-26` and `2024-11-05`
are supported.

Each POST carries one JSON-RPC message. Batches (JSON arrays) are refused whole with HTTP 400, whatever the protocol
version, and nothing in them runs. A request's `id` must be a string or an integer, `params` an object, and a tool's
`arguments` an object with only the arguments it declares; anything else is answered with a JSON-RPC error
(`-32600` or `-32602`) and runs nothing.

Claude Code:

```sh
claude mcp add --transport http winmux http://127.0.0.1:41740/mcp
# With a token:
claude mcp add --transport http winmux http://127.0.0.1:41740/mcp --header "Authorization: Bearer <token>"
```

Clients that take an `mcpServers` JSON configuration, such as a project's `.mcp.json`:

```json
{
  "mcpServers": {
    "winmux": {
      "type": "http",
      "url": "http://127.0.0.1:41740/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

Leave out `headers` when no token is required. Codex and other clients name the same two things, the URL and,
if a token is required, the `Authorization: Bearer <token>` header; see your client's documentation for where.

From the shell:

```sh
curl -s http://127.0.0.1:41740/mcp \
  -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

## Tools

| Tool | What it does |
| --- | --- |
| `list_windows` | Windows as JSON: id, title, layout, app, workspace, whether it's pinned, display. Optional `workspace`. |
| `get_focused_window` | The focused window, as `list_windows` describes it; `[]` when no window has focus. |
| `list_workspaces` | Workspaces (Tabs mode's tabs): name, display name, focused, visible, saved, pinned, layout, display. |
| `list_pins` | Pinned workspaces only. |
| `list_monitors` | Displays. |
| `list_projects` | Projects with their workspace and window counts. |
| `list_apps` | Running apps with a user interface. |
| `query_desktop` | `winmux agent query`: one structured snapshot of every workspace's windows, tab groups and layout. |
| `winmux_debug_snapshot` | One JSON document for diagnosing window and sidebar problems; see below. Optional `window_ids`, `include_titles`. |
| `winmux_debug_screenshot` | With **Allow debug screenshots**: an image of each display, and where it lies. Optional `display`, `max_long_edge`, `format`. |
| `winmux_debug_recording` | With **Allow debug screenshots**: records snapshots, frames and window events for up to 120 seconds. `action`: `start`, `status`, `fetch`, `stop`. |
| `winmux` | Runs one command, given its arguments without the leading `winmux`, such as `["workspace", "mail"]`. Optional `stdin`. Returns its output and exit code. |

The read tools run the CLI's own queries (`list-windows --json` and so on). With the `winmux` tool, `["--help"]` (or
`["-h"]`) prints the CLI's own command list, and `[<command>, "--help"]` explains one. `["--version"]` (or `["-v"]`)
prints WinMux.app's version. The CLI prints these itself; the server answers them from the same text, leaving out
`chrome-extension install`, which only the CLI runs. As from the CLI, `exec-and-forget` is refused. `subscribe` is
the one CLI command not offered over MCP: it streams events, and this server answers each request once. Poll the list
tools instead.

### Debug snapshot

`winmux_debug_snapshot` returns one JSON document (`"schema": "winmux-debug-snapshot/1"`) with what's needed to
diagnose a window or sidebar problem without sending logs:

- WinMux's version and commit, and the macOS version.
- Every display: id, name, frame, visible frame, the workspace it shows, and whether it has focus.
- The sidebar's rows as the panel draws them, ordinary and pinned, with their windows and tab groups, auxiliary
  windows, windows not shown in their tab, a pin's lent window, empty pins, and a saved tab's placeholders.
- For each member window: its app's bundle id and kind of bundle (app, app inside another app, helper, XPC service);
  its workspace, container, and whether it's tiled or floating; its auxiliary parent and children; whether it's
  hidden with its app, minimized, in full screen or parked in a corner (and where); the frame WinMux last placed it at,
  the one it last saw and the one macOS reports now; whether its app's own list of windows still has it; and the last
  Accessibility error WinMux got for it. A member whose window is gone says `"live": false`.
- Windows WinMux has that no row lists, and the last 256 window events (registered, gone, parked, back from a
  corner, moved to another workspace, a display showing another workspace).

It only reads. It doesn't go through the command line's dispatch, which lays windows out first, so nothing runs,
moves or refreshes. It waits at most 2 seconds for an app to answer.

Titles, tab labels and app paths are left out unless you pass `"include_titles": true`. Ids, bundle ids, app names,
workspace names, display names, frames and states are always in. `"window_ids": [123]` keeps only the rows with those
windows, and their events. The document is at most 64 KiB: over that, it leaves out the oldest events first, then
windows no row lists, then the last rows, and says how many of each in `truncated`.

### Debug screenshots and recordings

With **Allow debug screenshots** (`debug-screenshots = true`, off by default), the server also offers
`winmux_debug_screenshot` and `winmux_debug_recording`. Off, they aren't listed at all. Turning it on in Settings asks
macOS for Screen Recording permission, once; Settings shows whether macOS allows it, with **Allow Screen Recording…**
and **Open Privacy Settings…** if it doesn't. Nothing else asks: not launching WinMux, not editing or reloading the
config (from any client), and not the tools, which fail until macOS allows it.

**Images can't be redacted.** A screenshot or frame shows whatever is on screen, window titles and private content
included, even though `winmux_debug_snapshot` leaves titles out. They're kept in memory only and never written to
disk. WinMux's own sidebar and panels are in them: they're what's being debugged.

`winmux_debug_screenshot` returns one image per display (or the one `display` names, numbered as the snapshot's
`monitors[].id`), downscaled so its long edge is at most `max_long_edge` pixels (1600 by default, never more than the
display's own), as JPEG or PNG. With them, a JSON part gives each display's `frame` and `visibleFrame` in the
snapshot's coordinates and the image's `pixelsPerPoint`, so a window's frame from the snapshot can be found in the
image: `(x − frame.x) × pixelsPerPoint`.

`winmux_debug_recording`:

- `start` records for `duration_seconds` (default 60, at most 120), every `interval_ms` (default 1000, at least 250):
  a `winmux_debug_snapshot` (`window_ids` and `include_titles` apply), and, if frames are allowed, a frame of each
  display (`display`, `max_long_edge` default 1024, `format`). It keeps every window event in between, not just the
  newest the snapshot's log keeps. One recording at a time; starting another replaces a finished one.
- `status` says what it holds; `fetch` returns its entries — each tick's state, its events, its frames — in order, a
  page at a time: pass the `nextCursor` of one page to get the next. A page holds at most 8 images, 6 MB of them and
  96 KB of text, without exception: every entry fits a page alone. A frame larger than 6 MB isn't kept, and the
  recording says so; use JPEG or a smaller `max_long_edge`. Events come in pieces. A state the same as the one before
  it is sent as `"unchanged"`.
- It's kept in memory only, at most 64 MB, counting what it holds as `fetch` sends it, events included; an event's
  detail values are cut at 200 characters. Room is made before anything is kept: the oldest frames go first, then the
  oldest states, then the oldest events, and `truncated` says how many of each.
- It ends at its deadline, on a clock that changing the Mac's time doesn't move: no capture starts after it, and one
  still under way then is dropped.
- It's discarded on `stop`, once its last page is fetched, ten minutes after it ends, when another replaces it, or
  when **Allow debug screenshots** or the server is turned off. Discarding drops everything it holds at once, and a
  capture still under way keeps nothing; a screenshot under way when the tools are turned off sends nothing.
- Without Screen Recording permission, it records snapshots and events only.

While a recording runs, WinMux's menu bar icon is a recording symbol and its menu has **Debug recording… Stop**, which
ends and discards it. macOS shows its own screen recording indicator too.

From the tailnet, while the server requires no token, no image is captured or sent: a screenshot is refused, a
recording started from there records snapshots and events only, and a recording fetched from there comes without its
frames, and isn't discarded when that fetch reaches its end, so a request that may see the frames still can. Each
says to turn on **Require access token**. The local port is unaffected.

## Access from your tailnet

With **Allow access from my tailnet** (`tailnet = true`), WinMux opens a second port on 127.0.0.1, 41741 by default,
for [`tailscale serve`](https://tailscale.com/kb/1312/serve) to forward requests from your tailnet to. WinMux never
runs Tailscale. Run this yourself; Settings shows it to copy:

```sh
tailscale serve --bg --https=443 http://127.0.0.1:41741
```

Other devices in your tailnet then reach the server at `https://<this Mac's name>.<your tailnet>.ts.net/mcp`. To stop
forwarding:

```sh
tailscale serve --https=443 off
```

Turning **Allow access from my tailnet** off closes the port and every connection it let in, even if the serve rule
is still there; Tailscale then answers with an error. Never use `tailscale funnel` for it: that would put the server on
the internet, and neither port answers requests that come through Funnel.

Which port a request arrived on is all that says it came from the tailnet; WinMux never takes a request's headers,
Tailscale's identity headers included, as who sent it. On the tailnet port:

- The `Host` must be this Mac's name in your tailnet, `<name>.<tailnet>.ts.net`, on 443. `<name>` is **Name in your
  tailnet** (`tailnet-name`), or this Mac's local host name, lowercased, which is how Tailscale names a Mac unless you
  renamed it in Tailscale or it added a suffix such as `-1` because another machine had the name; then set **Name in
  your tailnet**. WinMux reads the local host name when the settings are applied: after renaming the Mac, reload the
  config or turn tailnet access off and on. Requests naming `localhost`, an address, another machine or another
  domain are refused, so a web page can't reach the port through DNS rebinding.
- A browser's request must come from that same `https://` origin.
- `list-exec-env-vars` is refused while the server requires no token, however it's reached, `trigger-binding`
  included.

Anyone your tailnet lets reach this Mac can use the server as an app on this Mac can, including closing windows. Use
your tailnet's access controls to choose who that is, and turn on **Require access token** to ask for the token too.

The local port is this Mac's only. It refuses any request a proxy forwarded, whatever `Host` its client chose:
`tailscale serve` picks where an HTTPS request goes by the name the client connected to, passes on the client's own
`Host`, and adds `X-Forwarded-Host` and `X-Forwarded-For` to everything it forwards. So a request carrying any
`X-Forwarded-*`, `Forwarded`, `X-Real-IP`, `Via` or `Tailscale-*` header is refused there. A serve rule pointed at the
local port, or left pointing at a port number the local port takes later, gets nothing. These headers only ever
refuse; leaving them out gets a client nothing it couldn't get as an app on this Mac.

Forwarding a port at the TCP level instead (`tailscale serve --tcp` or `--tls-terminated-tcp`, `ssh -L`, `socat`)
copies bytes and adds no header: WinMux can't tell such a request from an app on this Mac. Don't forward the local
port that way.

## Access token

The token is optional. With **Require access token**, every request must carry `Authorization: Bearer <token>`.
Settings has **Copy Token** and **Generate New Token…**. A new token takes effect at once, and clients using the
old one are refused.

The token is kept in `~/Library/Application Support/WinMux/mcp-server-token`, readable only by you, never in the
config, so a shared config doesn't share it. WinMux makes one when a token is required and none is saved. It's
compared in constant time and never logged.

## Security

- Anything that can reach the server can do what the `winmux` command line can, including focusing, moving and
  closing windows. Read tools and `agent query` return window titles and app names, which can be private. With
  **Allow debug screenshots**, it can see your screen: images can't be redacted.
  `list-exec-env-vars` prints the environment WinMux's commands inherit, which may hold secrets.
- Off, nothing listens. On, only 127.0.0.1, on one port, or two with tailnet access. A connection from any other
  address is closed before anything is read.
- Without a token, any app on this Mac can use the server, and, with tailnet access, anyone your tailnet lets reach
  this Mac. Turning the server or tailnet access off, or changing a port, closes the connections that port had.
- Requests whose `Host` isn't `localhost` or a loopback address, or whose `Origin` is a web page from anywhere but this
  Mac's loopback, are refused. That stops a web page from reaching the server through DNS rebinding. There's no CORS,
  so other web pages can't read its answers. Requests a proxy forwarded are refused on the local port, and Funnel's on
  both. The tailnet port has its own rule: see [Access from your tailnet](#access-from-your-tailnet).
- Limits: 16 KiB of headers and 16 MiB of body per request. A request must arrive within 60 seconds. At most 16
  connections at once. A tool waits up to 60 seconds for its command; the command isn't stopped then, as the CLI
  never stops one. Chunked request bodies aren't accepted: send a `Content-Length`.
