# MCP

The `mcp` block in `config.json` is the shape every other client uses, so an
entry from a `claude_desktop_config.json` pastes in unchanged:

```json
{
  "mcp": {
    "servers": {
      "files": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
      },
      "linear": { "url": "https://mcp.linear.app/mcp" },
      "internal": {
        "url": "https://internal.example/mcp",
        "headers": { "X-Api-Key": "..." }
      }
    }
  }
}
```

A `command` runs a child process; a `url` is a remote server over Streamable
HTTP, signed in with `synth mcp auth <name>` where it needs OAuth. `/mcp` turns
servers on and off without leaving the TUI.
