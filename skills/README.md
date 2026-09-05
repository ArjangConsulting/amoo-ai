# Loading Amoo skills

Start with [`driving-amoo`](driving-amoo/SKILL.md) when operating a device. Its entrypoint covers
selection, inspection, mutation, assertions and completion. Load its coordinate or recording
references only for those tasks. Detailed code-generation guidance is unnecessary for a simple
inspection. `AMOO_TOOL_PROFILE=drive|record|audit` can also reduce MCP discovery context.

The remaining skills are contributor references, not a bundle every device-driving agent needs:

| Skill | Load when |
| --- | --- |
| `mcp-server-swift` | Editing MCP transport, schemas or handlers |
| `grpc-swift` | Editing the host/companion transport |
| `ios-accessibility` / `android-accessibility` | Editing the corresponding companion UI bridge |
| `ios-simulator` / `android-emulator` | Editing device setup or diagnosing platform setup |
| `swift-package-architecture` | Changing module ownership and package dependencies |
| `vapor` | A separate task actually introduces or maintains a Vapor service; the current package does not use Vapor |

Project `AGENTS.md`, `Package.swift`, checked-in protos and executable schemas take precedence over
outdated generic examples in reference skills. Do not preload every skill body or repeat a complete
tool catalog in the conversation. Keep shared operating rules in the entrypoint and source-specific
detail behind links. Validate edits with the skill validator and keep the entrypoint below 150 lines.
