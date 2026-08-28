# adamcp

`adamcp` is a stdio MCP router and local web profiler for live AdaMCP HTTP servers.

```json
{
  "mcpServers": {
    "adamcp": {
      "command": "npx",
      "args": ["-y", "adamcp@latest"]
    }
  }
}
```

The CLI discovers running AdaEngine apps through AdaMCP discovery manifests. You can override discovery with:

- `ADAMCP_URL` or `--url` for a direct HTTP MCP endpoint.
- `ADAMCP_SERVER` or `--server` for a manifest `id` or unique `serverName`.
- `ADAMCP_DISCOVERY_DIR` or `--discovery-dir` for a custom manifest directory.
- `ADAMCP_STDIO_COMMAND` or `--stdio-command` to launch an AdaEngine app/server as a child stdio MCP process.

When multiple live apps are found, use `adamcp.list_servers` and `adamcp.select_server` from the MCP client.

## Web profiler

With an AdaEngine app running, start the local-only dashboard:

```bash
npx adamcp profiler
```

The server listens on `127.0.0.1` and opens the browser automatically. Options include `--no-open`, `--port`, `--server`, `--url`, and `--sessions-dir`. Captures are stored under `~/Library/Application Support/AdaMCP/profiles` on macOS and remain there until deleted through the local API.

CPU-first v1 provides live frame-time/FPS/memory summaries, bounded frame captures, ECS and render hotspots, display presentation data, and an embedded Perfetto timeline. Unsupported Hangs, Allocations, Symbols, and GPU providers are shown explicitly.

The MCP router also exposes composite tools: `adamcp.profiler.status`, `adamcp.profiler.start`, `adamcp.profiler.stop`, `adamcp.profiler.get_report`, and `adamcp.profiler.export`.
