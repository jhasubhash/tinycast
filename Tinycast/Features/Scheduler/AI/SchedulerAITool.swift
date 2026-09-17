import Foundation

/// The scheduler exposed to the in-app AI chat as native tools, merged beside the MCP tools:
/// create a reminder, list what is scheduled, and delete one by name. Each only ever touches a
/// notification reminder — never a user's script task, and it can never run a shell script.
enum SchedulerAITool {
    static let createName = "scheduler__create_reminder"
    static let listName = "scheduler__list_reminders"
    static let deleteName = "scheduler__delete_reminder"

    static let tools: [AITool] = [createTool, listTool, deleteTool]

    static func handles(_ name: String) -> Bool {
        name == createName || name == listName || name == deleteName
    }

    private static let createTool = AITool(
        name: createName,
        description:
            "Schedule a Tinycast notification to remind the user later. Only call this when the user "
            + "explicitly asks to be reminded or notified about something at a time — never infer a "
            + "reminder from a number, ratio, dimension, or time that appears for another reason. "
            + "Cannot run scripts or commands.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Short headline shown in the notification."),
                ]),
                "body": .object([
                    "type": .string("string"),
                    "description": .string("Optional detail line under the title."),
                ]),
                "when": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Natural-language time, e.g. 'tomorrow at 9am' or 'in 30 minutes'."),
                ]),
                "repeat": .object([
                    "type": .string("string"),
                    "enum": .array([.string("once"), .string("daily")]),
                    "description": .string(
                        "'once' fires a single time; 'daily' repeats every day at that time."),
                ]),
            ]),
            "required": .array([.string("title"), .string("when")]),
        ]),
        origin: "Scheduler",
        title: "Schedule a reminder")

    private static let listTool = AITool(
        name: listName,
        description:
            "List the reminders currently scheduled, so you can tell the user or choose one to "
            + "delete. Call this before deleting when you do not already know the exact name.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ]),
        origin: "Scheduler",
        title: "List reminders")

    private static let deleteTool = AITool(
        name: deleteName,
        description:
            "Delete an existing scheduled reminder by its name, cancelling it. This removes a "
            + "reminder — it never schedules a new one. To cancel a reminder, call this, not create.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "title": .object([
                    "type": .string("string"),
                    "description": .string("Name of the reminder to delete, as shown when listed."),
                ]),
            ]),
            "required": .array([.string("title")]),
        ]),
        origin: "Scheduler",
        title: "Delete a reminder")

    @MainActor
    static func invoke(
        _ call: AIToolCall, store: ScheduledTaskStore, calendar: Calendar, now: Date
    ) -> AIToolResult {
        switch call.name {
        case createName: return create(call, store: store, calendar: calendar, now: now)
        case listName: return list(call, store: store)
        case deleteName: return delete(call, store: store)
        default: return .failure(call.id, "Unknown scheduler tool \"\(call.name)\".")
        }
    }

    /// The AI surface only ever manages the notifications it can create, never a user's script task.
    private static func isReminder(_ task: ScheduledTask) -> Bool {
        if case .postNotification = task.action { return true }
        return false
    }

    private struct CreateArguments: Decodable {
        let title: String
        let body: String?
        let when: String
        let repeatRule: String?

        enum CodingKeys: String, CodingKey {
            case title, body, when
            case repeatRule = "repeat"
        }
    }

    @MainActor
    private static func create(
        _ call: AIToolCall, store: ScheduledTaskStore, calendar: Calendar, now: Date
    ) -> AIToolResult {
        guard let data = call.arguments.data(using: .utf8),
            let args = try? JSONDecoder().decode(CreateArguments.self, from: data)
        else {
            return .failure(call.id, "Could not read the reminder arguments.")
        }
        guard let fireDate = NaturalDateParser.date(from: args.when, now: now, calendar: calendar),
            fireDate > now
        else {
            return .failure(
                call.id, "Couldn't understand a future time from \"\(args.when)\".")
        }

        let repeats = args.repeatRule == "daily"
        let rule: ScheduleRule
        if repeats {
            let parts = calendar.dateComponents([.hour, .minute], from: fireDate)
            rule = .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        } else {
            rule = .once(fireDate)
        }

        let task = ScheduledTask.notification(
            title: args.title, body: args.body ?? "", rule: rule, now: now)
        store.add(task)

        let stamp = formatter.string(from: fireDate)
        let suffix = repeats ? " and every day after" : ""
        return AIToolResult(
            callID: call.id, content: "Scheduled \"\(args.title)\" for \(stamp)\(suffix).",
            isError: false)
    }

    @MainActor
    private static func list(_ call: AIToolCall, store: ScheduledTaskStore) -> AIToolResult {
        let reminders = store.tasks.filter(isReminder)
        guard !reminders.isEmpty else {
            return AIToolResult(
                callID: call.id, content: "No reminders are scheduled.", isError: false)
        }
        let lines = reminders.map { "• \($0.name) — \(ScheduleFormatter.rule($0.rule))" }
        return AIToolResult(
            callID: call.id,
            content: "Scheduled reminders:\n" + lines.joined(separator: "\n"), isError: false)
    }

    private struct DeleteArguments: Decodable { let title: String }

    @MainActor
    private static func delete(_ call: AIToolCall, store: ScheduledTaskStore) -> AIToolResult {
        guard let data = call.arguments.data(using: .utf8),
            let args = try? JSONDecoder().decode(DeleteArguments.self, from: data)
        else {
            return .failure(call.id, "Could not read the reminder to delete.")
        }
        let reminders = store.tasks.filter(isReminder)
        guard !reminders.isEmpty else {
            return .failure(call.id, "There are no reminders to delete.")
        }
        // A weak on-device model rarely quotes the exact name; a lone reminder is unambiguous.
        if reminders.count == 1 {
            store.remove(id: reminders[0].id)
            return AIToolResult(
                callID: call.id, content: "Deleted the reminder \"\(reminders[0].name)\".",
                isError: false)
        }

        let query = args.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let exact = reminders.filter { $0.name.lowercased() == query }
        let matches = exact.isEmpty ? reminders.filter { $0.name.lowercased().contains(query) } : exact
        switch matches.count {
        case 0:
            let names = reminders.map { "\"\($0.name)\"" }.joined(separator: ", ")
            return .failure(
                call.id, "No reminder named \"\(args.title)\". Currently scheduled: \(names).")
        case 1:
            store.remove(id: matches[0].id)
            return AIToolResult(
                callID: call.id, content: "Deleted the reminder \"\(matches[0].name)\".",
                isError: false)
        default:
            let names = matches.map { "\"\($0.name)\"" }.joined(separator: ", ")
            return .failure(
                call.id, "Several reminders match \"\(args.title)\": \(names). Ask which one.")
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
