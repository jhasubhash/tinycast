import Foundation

/// A launcher fallback: the typed query is its input, so it is offered whatever the query says.
enum Fallback: Hashable, Sendable {
    /// The shipped destinations, in the order a fresh install offers them.
    enum Builtin: String, CaseIterable, Sendable {
        case aiChat
        case searchFiles
        case runShellCommand
        case scheduleReminder

        /// Where its name and glyph come from, so a fallback row reads like the command it runs.
        var command: CommandID {
            switch self {
            case .aiChat: return .aiChat
            case .searchFiles: return .searchFiles
            case .runShellCommand: return .runShellCommand
            case .scheduleReminder: return .createScheduledTask
            }
        }

        /// The typed-query intent that should float this fallback to the top, if any. The launcher
        /// asks `IntentClassifier` what a query means, then promotes the fallbacks that answer to it.
        var intent: QueryIntent? {
            switch self {
            case .aiChat: return .aiQuestion
            case .searchFiles: return .fileSearch
            case .runShellCommand: return .shellCommand
            case .scheduleReminder: return .reminder
            }
        }
    }

    case builtin(Builtin)
    case quicklink(UUID)

    /// The built-in behind this fallback, or nil for a quicklink — the intent map keys off it.
    var builtin: Builtin? {
        if case .builtin(let builtin) = self { return builtin }
        return nil
    }

    /// The row's `AppEntry` id, so a stored order outlives a rename and survives a reinstall.
    var id: String {
        switch self {
        case .builtin(let builtin): return builtin.command.rawValue
        case .quicklink(let id): return Quicklink.entryIDPrefix + id.uuidString.lowercased()
        }
    }

    init?(id: String) {
        if let command = CommandID(rawValue: id),
            let builtin = Builtin.allCases.first(where: { $0.command == command })
        {
            self = .builtin(builtin)
        } else if let quicklink = Quicklink.id(fromEntryID: id) {
            self = .quicklink(quicklink)
        } else {
            return nil
        }
    }

    /// The footer pill's verb: what ↵ does, in the destination's own words.
    var openVerb: String {
        switch self {
        case .builtin(.aiChat): return "Ask AI Chat"
        case .builtin(.searchFiles): return "Search Files"
        case .builtin(.runShellCommand): return "Run Shell Command"
        case .builtin(.scheduleReminder): return "Schedule a Reminder"
        case .quicklink: return "Open Quicklink"
        }
    }

    /// Stored order first, then anything it has never seen — a quicklink added today lands last.
    static func ordered(_ available: [Fallback], by storedIDs: [String]) -> [Fallback] {
        var remaining = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = storedIDs.compactMap { remaining.removeValue(forKey: $0) }
        return known + available.filter { remaining[$0.id] != nil }
    }

    /// Floats the fallbacks whose intent the query expressed to the top, strongest intent first, and
    /// keeps everything else in its given order below. A per-query view — the stored order is untouched.
    static func prioritised(_ offered: [Fallback], forIntents ranked: [QueryIntent]) -> [Fallback] {
        var front: [Fallback] = []
        for intent in ranked {
            for fallback in offered where fallback.builtin?.intent == intent && !front.contains(fallback) {
                front.append(fallback)
            }
        }
        return front + offered.filter { !front.contains($0) }
    }

    /// The section header. A long query is elided in the middle, so “with…” always survives.
    static func sectionTitle(query: String, limit: Int = 72) -> String {
        guard query.count > limit else { return "Use “\(query)” with…" }
        return "Use “\(query.prefix(limit / 2))…\(query.suffix(limit - limit / 2 - 1))” with…"
    }
}
