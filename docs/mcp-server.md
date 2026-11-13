# MCP server

WinMux can run a [Model Context Protocol](https://modelcontextprotocol.io) server over HTTP, so MCP clients such as
Claude, Codex or Hermes-style agents can read WinMux's windows, tabs, pins and displays, and run `winmux`
commands. A command run this way has exactly the effects it has from the `winmux` command line: it goes through
the same dispatch as the CLI. It's off by default, and it listens on 127.0.0.1 only, so only apps on this Mac can
reach it.

## Turn it on

In **Settings → General → MCP server**, turn on **Turn on MCP server**, or in your config:

```toml
[mcp-server]
enabled = true          # listens on 127.0.0.1, this Mac only
port = 41740            # 1024–65535
require-token = false   # true: clients must send the access token
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
| `winmux` | Runs one command, given its arguments without the leading `winmux`, such as `["workspace", "mail"]`. Optional `stdin`. Returns its output and exit code. |

The read tools run the CLI's own queries (`list-windows --json` and so on). With the `winmux` tool, `["--help"]` (or
`["-h"]`) prints the CLI's own command list, and `[<command>, "--help"]` explains one. `["--version"]` (or `["-v"]`)
prints WinMux.app's version. The CLI prints these itself; the server answers them from the same text, leaving out
`chrome-extension install`, which only the CLI runs. As from the CLI, `exec-and-forget` is refused. `subscribe` is
the one CLI command not offered over MCP: it streams events, and this server answers each request once. Poll the list
tools instead.

## Other devices

The server can't be reached from another device: it listens on 127.0.0.1 only, and refuses any peer that isn't this
Mac's loopback. Access over Tailscale isn't available yet; it's planned as a separate feature.

## Access token

The token is optional. With **Require access token**, every request must carry `Authorization: Bearer <token>`.
Settings has **Copy Token** and **Generate New Token…**. A new token takes effect at once, and clients using the
old one are refused.

The token is kept in `~/Library/Application Support/WinMux/mcp-server-token`, readable only by you, never in the
config, so a shared config doesn't share it. WinMux makes one when a token is required and none is saved. It's
compared in constant time and never logged.

## Security

- Anything that can reach the server can do what the `winmux` command line can, including focusing, moving and
  closing windows. Read tools and `agent query` return window titles and app names, which can be private.
  `list-exec-env-vars` prints the environment WinMux's commands inherit, which may hold secrets.
- Off, nothing listens. On, only 127.0.0.1. A connection from any other address is closed before anything is read.
- Without a token, any app on this Mac can use the server. Turning the server off, or changing its port, closes the
  connections it had.
- Requests whose `Host` isn't `localhost` or a loopback address, or whose `Origin` is a web page from anywhere but this
  Mac's loopback, are refused. That stops a web page from reaching the server through DNS rebinding. There's no CORS,
  so other web pages can't read its answers.
- Limits: 16 KiB of headers and 16 MiB of body per request. A request must arrive within 60 seconds. At most 16
  connections at once. A tool waits up to 60 seconds for its command; the command isn't stopped then, as the CLI
  never stops one. Chunked request bodies aren't accepted: send a `Content-Length`.
