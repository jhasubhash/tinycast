import Foundation

/// Editable state for one scheduled task, shared by the Scheduler pane's sheet and the launcher's
/// in-palette editor so both bind to the same fields and validation. Building the task is here too;
/// only persistence (add vs update) and dismissal stay with each host.
@MainActor
@Observable
final class ScheduledTaskDraft {
    enum RuleKind: String, CaseIterable, Identifiable {
        case once, interval, daily, weekly, monthly
        var id: Self { self }
        var label: String {
            switch self {
            case .once: return "Once"
            case .interval: return "Every"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            }
        }
    }

    enum ActionKind: String, CaseIterable, Identifiable {
        case script, notification
        var id: Self { self }
        var label: String { self == .script ? "Run Script" : "Notification" }
    }

    enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes, hours, days
        var id: Self { self }
        var label: String { rawValue.capitalized }
        var seconds: TimeInterval {
            switch self {
            case .minutes: return 60
            case .hours: return 3_600
            case .days: return 86_400
            }
        }
    }

    var name: String
    var ruleKind: RuleKind
    var onceDate: Date
    var intervalValue: Double
    var intervalUnit: IntervalUnit
    var timeOfDay: Date
    var weekdays: Set<Int>
    var monthDay: Int

    var actionKind: ActionKind
    var scriptSource: String
    var workingDirectory: String
    var notifyOnFinish: Bool
    var notificationID: UUID?
    var notifyTitle: String
    var notifyBody: String
    var notifyStyle: NotificationStyle
    var notifyCorner: NotificationCorner
    var notifySticky: Bool
    var notifyDwell: Double

    var catchUp: CatchUpPolicy
    /// Defaults on for a one-time task; the user can still turn it off, or on for a recurring one.
    var deleteAfterRun: Bool

    /// The task being edited, kept so a save preserves its id, anchor and creation date; nil on add.
    private let existing: ScheduledTask?

    var isEditing: Bool { existing != nil }
    var editingID: UUID? { existing?.id }
    var title: String { isEditing ? "Edit Scheduled Task" : "Create Scheduled Task" }

    init(task: ScheduledTask?) {
        existing = task
        name = task?.name ?? ""

        var kind = RuleKind.daily
        var once = Date()
        var value = 1.0
        var unit = IntervalUnit.hours
        var time = Self.time(9, 0)
        var days: Set<Int> = [2, 3, 4, 5, 6]
        var day = 1
        switch task?.rule {
        case .once(let date): kind = .once; once = date
        case .interval(let seconds): kind = .interval; (value, unit) = Self.decompose(seconds)
        case .daily(let hour, let minute): kind = .daily; time = Self.time(hour, minute)
        case .weekly(let weekdays, let hour, let minute):
            kind = .weekly; days = weekdays; time = Self.time(hour, minute)
        case .monthly(let d, let hour, let minute):
            kind = .monthly; day = d; time = Self.time(hour, minute)
        case nil: break
        }
        ruleKind = kind
        onceDate = once
        intervalValue = value
        intervalUnit = unit
        timeOfDay = time
        weekdays = days
        monthDay = day

        var action = ActionKind.script
        var source = ""
        var directory = ""
        var notify = false
        var notifID: UUID?
        var nTitle = ""
        var nBody = ""
        var nStyle = NotificationStyle.toast
        var nCorner = NotificationCorner.topTrailing
        var nDwell = 6.0
        var nSticky = false
        switch task?.action {
        case .runScript(let spec):
            action = .script
            source = spec.source
            directory = spec.workingDirectory ?? ""
            notify = spec.notifyOnFinish
        case .postNotification(let spec):
            action = .notification
            notifID = spec.id
            nTitle = spec.title
            nBody = spec.body
            nStyle = spec.style
            nCorner = spec.corner
            if let dwell = spec.dwell { nDwell = dwell } else { nSticky = true }
        case nil: break
        }
        actionKind = action
        scriptSource = source
        workingDirectory = directory
        notifyOnFinish = notify
        notificationID = notifID
        notifyTitle = nTitle
        notifyBody = nBody
        notifyStyle = nStyle
        notifyCorner = nCorner
        notifyDwell = nDwell
        notifySticky = nSticky

        catchUp = task?.catchUp ?? .fireOnceOnResume
        deleteAfterRun = task?.deleteAfterRun ?? (kind == .once)
    }

    var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if ruleKind == .weekly && weekdays.isEmpty { return false }
        if ruleKind == .interval && !(intervalValue >= 1) { return false }
        switch actionKind {
        case .script:
            return !scriptSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .notification:
            return !notifyTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// The task to persist. Editing keeps the UUID, last-fired anchor and createdAt, so the schedule
    /// never re-fires from the change alone.
    func build() -> ScheduledTask {
        let (hour, minute) = Self.components(timeOfDay)
        let rule: ScheduleRule
        switch ruleKind {
        case .once: rule = .once(onceDate)
        case .interval: rule = .interval(seconds: max(1, intervalValue) * intervalUnit.seconds)
        case .daily: rule = .daily(hour: hour, minute: minute)
        case .weekly: rule = .weekly(weekdays: weekdays, hour: hour, minute: minute)
        case .monthly: rule = .monthly(day: monthDay, hour: hour, minute: minute)
        }

        let action: ScheduledAction
        switch actionKind {
        case .script:
            let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            action = .runScript(
                ScriptSpec(
                    source: scriptSource, arguments: [],
                    workingDirectory: directory.isEmpty ? nil : directory,
                    notifyOnFinish: notifyOnFinish))
        case .notification:
            action = .postNotification(
                NotificationSpec(
                    id: notificationID ?? UUID(), title: notifyTitle, body: notifyBody,
                    style: notifyStyle, corner: notifyCorner,
                    dwell: notifySticky ? nil : max(1, notifyDwell), actions: []))
        }

        return ScheduledTask(
            id: existing?.id ?? UUID(), name: name, isEnabled: existing?.isEnabled ?? true,
            rule: rule, action: action, catchUp: catchUp, deleteAfterRun: deleteAfterRun,
            lastFired: existing?.lastFired, createdAt: existing?.createdAt ?? Date())
    }

    private static func time(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private static func components(_ date: Date) -> (Int, Int) {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0, parts.minute ?? 0)
    }

    private static func decompose(_ seconds: TimeInterval) -> (Double, IntervalUnit) {
        for unit in [IntervalUnit.days, .hours, .minutes] {
            let value = seconds / unit.seconds
            if value >= 1 && value == value.rounded() { return (value, unit) }
        }
        return (max(1, seconds / 60), .minutes)
    }
}
