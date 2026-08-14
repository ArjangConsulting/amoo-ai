# MCP For Local AI

Amoo exposes AI-facing automation through MCP, implemented in Swift over the standard `stdio` transport.
The CLI does not configure or run an AI provider; local AI clients provide the reasoning and call Amoo tools.

## Prerequisites

The MCP server is a thin wrapper around the platform driver — it requires a running
companion app on the loopback gRPC port:

- iOS companion on `127.0.0.1:22087` (default)
- Android companion on `127.0.0.1:22088` (default)

Boot a companion before sending tool calls — for example with
`scripts/run-e2e-ios.sh --skip-build` or `scripts/run-e2e-android.sh --skip-build`,
or by running the companion app from `CompanionApps/`.

## Start the server manually

```bash
swift run amoo mcp serve
```

By default this targets the iOS companion on port `22087`. For Android or custom ports:

```bash
swift run amoo mcp serve --platform android --port 22088
```

The server speaks JSON-RPC over `stdio` and exits cleanly when the client closes
stdin. It supports both stateless MCP `2026-07-28` requests and the legacy
`initialize` flow used by MCP `2025-11-25` clients.

## Connecting an MCP client

Add an entry to your MCP client's configuration. For Claude Desktop
(`~/Library/Application Support/Claude/claude_desktop_config.json`) and Cursor
(`~/.cursor/mcp.json`), the shape is the same:

```json
{
  "mcpServers": {
    "amoo": {
      "command": "swift",
      "args": [
        "run",
        "--package-path", "/absolute/path/to/amoo",
        "amoo", "mcp", "serve",
        "--platform", "ios"
      ]
    }
  }
}
```

For a faster startup, build once and point the client at the binary:

```bash
swift build -c release
```

```json
{
  "mcpServers": {
    "amoo": {
      "command": "/absolute/path/to/amoo/.build/release/amoo",
      "args": ["mcp", "serve", "--platform", "ios"]
    }
  }
}
```

## Inspect the server during development

```bash
npx @modelcontextprotocol/inspector swift run amoo mcp serve
```

Useful assistant-facing tools include:

- `describe_screen`
- `suggest_test_actions`
- `find_element_by_description`
- `analyze_ai_testability`

Use `analyze_ai_testability` to understand what developers can improve for better AI-driven testing: labels, identifiers, duplicate controls, hidden enabled elements, and missing primary actions.

## Reusable test flows

Keep deterministic smoke tests in a checked-in `*.amoo.json` file and run the whole sequence over
one companion connection:

```bash
amoo flow Examples/sign-in.amoo.json
```

Each step names a normal device/MCP tool. Exact `${ENV_NAME}` argument values are resolved from the
process environment so credentials do not enter source control. The runner stops at the first
failed action or assertion and prints the verified result for every completed step. See
[`Examples/sign-in.amoo.json`](../Examples/sign-in.amoo.json) for the format.
