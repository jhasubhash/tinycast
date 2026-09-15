import Foundation

/// One MCP server resolved for a CLI route: its handle plus the transport and secrets a CLI needs to
/// launch or reach it. Self-contained (no MCP-model dependency) so each CLI formats its own config.
struct AICLIMCPServer: Sendable, Equatable {
    enum Transport: Sendable, Equatable {
        case stdio(command: String, arguments: [String])
        case http(url: String, headerName: String)
    }
    var slug: String
    var transport: Transport
    /// The HTTP header value from the Keychain, empty when none — kept out of UserDefaults and backups.
    var headerValue: String
    var environment: [String: String]
}

/// The opt-in payload for running an installed CLI route's *own* MCP tools, scoped to exactly the
/// Assistant's enabled servers. Built only when an Assistant has `allowCLITools` on and enables MCP
/// servers; `nil` everywhere else keeps the CLI route sandboxed as before.
struct AICLIToolConfig: Sendable, Equatable {
    var servers: [AICLIMCPServer]
    /// A tool turn is call → result → answer; one turn is never enough.
    var maxTurns: Int

    init(servers: [AICLIMCPServer], maxTurns: Int = 25) {
        self.servers = servers
        self.maxTurns = maxTurns
    }

    /// `mcp__<slug>` per server — an allowlist, so only these tools run, not the CLI's built-ins.
    var allowedTools: [String] { servers.map { "mcp__\($0.slug)" } }

    /// Claude Code's `--mcp-config` payload: `{"mcpServers":{…}}` for the enabled servers.
    var claudeMCPConfigJSON: String {
        var entries: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case .stdio(let command, let arguments):
                var entry: [String: Any] = ["command": command, "args": arguments]
                if !server.environment.isEmpty { entry["env"] = server.environment }
                entries[server.slug] = entry
            case .http(let url, let headerName):
                var entry: [String: Any] = ["type": "http", "url": url]
                if !server.headerValue.isEmpty { entry["headers"] = [headerName: server.headerValue] }
                entries[server.slug] = entry
            }
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["mcpServers": entries], options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else { return #"{"mcpServers":{}}"# }
        return json
    }

    /// Codex app-server `mcp_servers` map for `thread/start`. Codex spawns stdio servers itself and
    /// reaches HTTP ones by URL; the shapes mirror its config schema.
    var codexMCPServers: [String: Any] {
        var entries: [String: Any] = [:]
        for server in servers {
            switch server.transport {
            case .stdio(let command, let arguments):
                var entry: [String: Any] = ["command": command, "args": arguments]
                if !server.environment.isEmpty { entry["env"] = server.environment }
                entries[server.slug] = entry
            case .http(let url, let headerName):
                var entry: [String: Any] = ["url": url]
                if !server.headerValue.isEmpty {
                    entry["http_headers"] = [headerName: server.headerValue]
                }
                entries[server.slug] = entry
            }
        }
        return entries
    }
}
