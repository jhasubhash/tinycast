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
    /// Enabled Skills — a subset of the library. Instructions injected into the turn.
    var skillIDs: Set<UUID>
    /// Enabled MCP servers — a subset of the library. Tools offered on API routes only.
    var mcpServerIDs: Set<UUID>
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
        skillIDs: Set<UUID> = [],
        mcpServerIDs: Set<UUID> = [],
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
        self.skillIDs = skillIDs
        self.mcpServerIDs = mcpServerIDs
        self.opensTo = opensTo
        self.newChatAfter = newChatAfter
        self.retention = retention
        self.ephemeral = ephemeral
        self.seedPrompt = seedPrompt
        self.positions = positions
        self.width = width
        self.order = order
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
