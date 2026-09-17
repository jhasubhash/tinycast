import Foundation

/// The scheduler exposed to the in-app AI chat as one native tool, merged beside the MCP tools.
/// It only ever schedules a notification: the model can remind the user, never run a shell script.
enum SchedulerAITool {
    static let name = "scheduler__create_reminder"

    static let tool = AITool(
        name: name,
        description:
            "Schedule a Tinycast notification to fire later. Use for reminders the user asks to be "
            + "nudged about at a time. Cannot run scripts or commands.",
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

    private struct Arguments: Decodable {
        let title: String
        let body: String?
        let when: String
        let repeatRule: String?

        enum CodingKeys: String, CodingKey {
            case title, body, when
            case repeatRule = "repeat"
        }
    }

    /// Runs on the main actor: creates the task in the store, returns a line the model can read.
    @MainActor
    static func invoke(
        _ call: AIToolCall, store: ScheduledTaskStore, calendar: Calendar, now: Date
    ) -> AIToolResult {
        guard let data = call.arguments.data(using: .utf8),
            let args = try? JSONDecoder().decode(Arguments.self, from: data)
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

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
