# adamcp

`adamcp` is a stdio MCP router for live AdaMCP HTTP servers.

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
