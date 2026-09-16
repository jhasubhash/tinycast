import CoreGraphics
import Foundation

/// A named, dedicated AI chat bar — its own shortcut, prompt, model, Skills, MCP servers, history and
/// placement. Pure and `Codable`: `AssistantStore` persists it, the coordinator reads it. The default
/// bar (`toggleAIBar`) is deliberately *not* an Assistant. See `Assistant_Architecture.md`.
struct Assistant: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    /// Configured (standard chat UI) or provided by a Swift plugin (custom UI + behaviour).
    var provider: AssistantProvider
    var name: String
    /// SF Symbol name or emoji for the leading glyph and the launcher row.
    var symbol: String
    var tint: AssistantTint
    /// Appended to the preamble on every turn, so it is billed on every turn.
    var systemPrompt: String
    var systemPromptEnabled: Bool
    /// `nil` falls forward to the global default model, so an assistant need not name one.
    var model: AIModelSelection?
    var webSearch: Bool
    /// On by default: the model's reasoning streams into this assistant's transcript as it thinks.
    var showReasoning: Bool
    /// Enabled Skills — a subset of the library. Instructions injected into the turn.
    var skillIDs: Set<UUID>
    /// Enabled MCP servers — a subset of the library. Tools offered on API routes only.
    var mcpServerIDs: Set<UUID>
    /// Opt-in: let an installed CLI route run this assistant's MCP servers as its own tools (a
    /// generated `--mcp-config`). Off by default — it un-sandboxes native CLI tool execution.
    var allowCLITools: Bool
    /// A broader opt-in than `allowCLITools`: let an installed CLI route run *shell* commands too, so a
    /// script-based Skill can execute. Full native tool access.
    var allowShellTools: Bool
    var opensTo: AIOpensTo
    var newChatAfter: AINewChatAfter
    var retention: AIRetention
    /// True never persists this assistant's chats — a scratch or sensitive persona.
    var ephemeral: Bool
    /// Shown in the empty state under the placeholder; a nudge, not a message.
    var seedPrompt: String
    /// Per-display placement offset, like `AppSettings.aiBarPosition`; the bar remembers where it sat.
    var positions: [String: [Double]]
    /// Optional per-assistant panel width; `nil` uses the shared `panelWidth`.
    var width: CGFloat?
    var order: Int

    init(
        id: UUID = UUID(),
        provider: AssistantProvider = .configured,
        name: String = "",
        symbol: String = "sparkles",
        tint: AssistantTint = .blue,
        systemPrompt: String = "",
        systemPromptEnabled: Bool = true,
        model: AIModelSelection? = nil,
        webSearch: Bool = false,
        showReasoning: Bool = true,
        skillIDs: Set<UUID> = [],
        mcpServerIDs: Set<UUID> = [],
        allowCLITools: Bool = false,
        allowShellTools: Bool = false,
        opensTo: AIOpensTo = .recent,
        newChatAfter: AINewChatAfter = .fiveMinutes,
        retention: AIRetention = .forever,
        ephemeral: Bool = false,
        seedPrompt: String = "",
        positions: [String: [Double]] = [:],
        width: CGFloat? = nil,
        order: Int = 0
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.symbol = symbol
        self.tint = tint
        self.systemPrompt = systemPrompt
        self.systemPromptEnabled = systemPromptEnabled
        self.model = model
        self.webSearch = webSearch
        self.showReasoning = showReasoning
        self.skillIDs = skillIDs
        self.mcpServerIDs = mcpServerIDs
        self.allowCLITools = allowCLITools
        self.allowShellTools = allowShellTools
        self.opensTo = opensTo
        self.newChatAfter = newChatAfter
        self.retention = retention
        self.ephemeral = ephemeral
        self.seedPrompt = seedPrompt
        self.positions = positions
        self.width = width
        self.order = order
    }

    /// Decode-tolerant: a field an older saved assistant lacks falls back to its default rather than
    /// failing the whole decode — one missing key must never drop every saved assistant.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Assistant()
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? d.id,
            provider: try c.decodeIfPresent(AssistantProvider.self, forKey: .provider) ?? d.provider,
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? d.name,
            symbol: try c.decodeIfPresent(String.self, forKey: .symbol) ?? d.symbol,
            tint: try c.decodeIfPresent(AssistantTint.self, forKey: .tint) ?? d.tint,
            systemPrompt: try c.decodeIfPresent(String.self, forKey: .systemPrompt) ?? d.systemPrompt,
            systemPromptEnabled: try c.decodeIfPresent(Bool.self, forKey: .systemPromptEnabled)
                ?? d.systemPromptEnabled,
            model: try c.decodeIfPresent(AIModelSelection.self, forKey: .model) ?? d.model,
            webSearch: try c.decodeIfPresent(Bool.self, forKey: .webSearch) ?? d.webSearch,
            showReasoning: try c.decodeIfPresent(Bool.self, forKey: .showReasoning) ?? d.showReasoning,
            skillIDs: try c.decodeIfPresent(Set<UUID>.self, forKey: .skillIDs) ?? d.skillIDs,
            mcpServerIDs: try c.decodeIfPresent(Set<UUID>.self, forKey: .mcpServerIDs) ?? d.mcpServerIDs,
            allowCLITools: try c.decodeIfPresent(Bool.self, forKey: .allowCLITools) ?? d.allowCLITools,
            allowShellTools: try c.decodeIfPresent(Bool.self, forKey: .allowShellTools)
                ?? d.allowShellTools,
            opensTo: try c.decodeIfPresent(AIOpensTo.self, forKey: .opensTo) ?? d.opensTo,
            newChatAfter: try c.decodeIfPresent(AINewChatAfter.self, forKey: .newChatAfter)
                ?? d.newChatAfter,
            retention: try c.decodeIfPresent(AIRetention.self, forKey: .retention) ?? d.retention,
            ephemeral: try c.decodeIfPresent(Bool.self, forKey: .ephemeral) ?? d.ephemeral,
            seedPrompt: try c.decodeIfPresent(String.self, forKey: .seedPrompt) ?? d.seedPrompt,
            positions: try c.decodeIfPresent([String: [Double]].self, forKey: .positions)
                ?? d.positions,
            width: try c.decodeIfPresent(CGFloat.self, forKey: .width) ?? d.width,
            order: try c.decodeIfPresent(Int.self, forKey: .order) ?? d.order)
    }

    var isPlugin: Bool {
        if case .plugin = provider { return true }
        return false
    }

    /// This display's stored placement, or `nil` when the assistant has never been dragged there.
    func position(on display: String) -> CGPoint? {
        positions[display].flatMap { $0.count == 2 ? CGPoint(x: $0[0], y: $0[1]) : nil }
    }

    /// Set or clear this display's placement; the store persists the result.
    mutating func setPosition(_ offset: CGPoint?, on display: String) {
        guard let offset else {
            positions.removeValue(forKey: display)
            return
        }
        positions[display] = [offset.x, offset.y]
    }
}

/// Where an Assistant's UI and behaviour come from — plain config, or a native Swift plugin that renders
/// its own SwiftUI surface (see `Assistant_Architecture.md` §19).
enum AssistantProvider: Codable, Sendable, Equatable {
    case configured
    case plugin(pluginID: String, descriptorID: String)
}

/// A named accent for an assistant's glyph. The UI layer maps each to a colour; the model stays
/// Foundation-only, so it never names one here.
enum AssistantTint: String, Codable, CaseIterable, Sendable {
    case blue, purple, pink, red, orange, yellow, green, teal, gray
}

extension Assistant {
    /// The launcher entry id for this assistant's "Ask <Name>" command; mirrors the custom-command scheme.
    var entryID: String { "assistant:\(id.uuidString)" }

    static func id(fromEntryID entryID: String) -> UUID? {
        let prefix = "assistant:"
        guard entryID.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(prefix.count)))
    }
}
