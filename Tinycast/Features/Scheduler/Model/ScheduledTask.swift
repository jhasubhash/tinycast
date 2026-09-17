import Foundation

struct ScriptSpec: Codable, Hashable, Sendable {
    var source: String
    var arguments: [String]
    var workingDirectory: String?
    var notifyOnFinish: Bool
}

enum ScheduledAction: Codable, Hashable, Sendable {
    case runScript(ScriptSpec)
    case postNotification(NotificationSpec)
}

enum ScheduleRule: Codable, Hashable, Sendable {
    case once(Date)
    case interval(seconds: TimeInterval)
    case daily(hour: Int, minute: Int)
    /// `weekdays` uses Calendar weekday integers: 1 = Sunday … 7 = Saturday.
    case weekly(weekdays: Set<Int>, hour: Int, minute: Int)
    case monthly(day: Int, hour: Int, minute: Int)
}

enum CatchUpPolicy: String, Codable, Sendable {
    case skip, fireOnceOnResume, fireEach
}

struct ScheduledTask: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var rule: ScheduleRule
    var action: ScheduledAction
    var catchUp: CatchUpPolicy
    /// A one-shot task deletes itself once it runs rather than lingering as a spent row.
    var deleteAfterRun: Bool
    var lastFired: Date?
    var createdAt: Date

    static let entryIDPrefix = "scheduled-task:"
    static let sfSymbol = "clock"

    var entryID: String { Self.entryIDPrefix + id.uuidString.lowercased() }

    static func id(fromEntryID entryID: String) -> UUID? {
        guard entryID.hasPrefix(entryIDPrefix) else { return nil }
        return UUID(uuidString: String(entryID.dropFirst(entryIDPrefix.count)))
    }

    /// A notification task from parsed intent: a one-shot deletes itself, a recurring one persists.
    static func notification(
        title: String, body: String = "", rule: ScheduleRule, now: Date
    ) -> ScheduledTask {
        let repeats: Bool = { if case .once = rule { return false } else { return true } }()
        let spec = NotificationSpec(
            id: UUID(), title: title, body: body, style: .banner, corner: .topTrailing,
            dwell: nil, actions: [])
        return ScheduledTask(
            id: UUID(), name: title, isEnabled: true, rule: rule,
            action: .postNotification(spec), catchUp: .fireOnceOnResume, deleteAfterRun: !repeats,
            lastFired: nil, createdAt: now)
    }
}
