// The scheduler's AI surface: create, list, and delete reminders, and the guards that keep the
// model from mangling a delete into another create or touching a user's script task.
import Foundation

@main
@MainActor
struct SchedulerAIToolTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("✗ \(message)")
        }
    }

    static func main() {
        createSchedulesAReminder()
        listNamesEveryReminder()
        listIgnoresScriptTasks()
        deleteRemovesTheSoleReminder()
        deletePrefersAnExactNameOverASubstring()
        deleteReportsWhenNothingMatches()
        deleteRefusesAnAmbiguousName()
        deleteNeverTouchesAScriptTask()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let now = calendar.date(
        from: DateComponents(year: 2025, month: 1, day: 15, hour: 10, minute: 0))!

    private static func store(_ tasks: [ScheduledTask]) -> ScheduledTaskStore {
        let store = ScheduledTaskStore()
        for task in tasks { store.add(task) }
        return store
    }

    private static func reminder(_ title: String) -> ScheduledTask {
        ScheduledTask.notification(title: title, rule: .daily(hour: 9, minute: 0), now: now)
    }

    private static func script(_ name: String) -> ScheduledTask {
        ScheduledTask(
            id: UUID(), name: name, isEnabled: true, rule: .daily(hour: 9, minute: 0),
            action: .runScript(
                ScriptSpec(source: "echo hi", arguments: [], workingDirectory: nil,
                    notifyOnFinish: false)),
            catchUp: .skip, deleteAfterRun: false, lastFired: nil, createdAt: now)
    }

    private static func call(_ name: String, _ arguments: String) -> AIToolCall {
        AIToolCall(id: "c1", name: name, arguments: arguments)
    }

    private static func run(_ store: ScheduledTaskStore, _ call: AIToolCall) -> AIToolResult {
        SchedulerAITool.invoke(call, store: store, calendar: calendar, now: now)
    }

    static func createSchedulesAReminder() {
        let store = store([])
        let result = run(
            store,
            call(SchedulerAITool.createName, #"{"title":"Standup","when":"tomorrow at 9am"}"#))
        expect(!result.isError, "a well-formed reminder schedules without error")
        expect(store.tasks.count == 1 && store.tasks[0].name == "Standup", "and lands in the store")
    }

    static func listNamesEveryReminder() {
        let store = store([reminder("Standup"), reminder("Drink water")])
        let result = run(store, call(SchedulerAITool.listName, "{}"))
        expect(!result.isError, "listing is never an error")
        expect(
            result.content.contains("Standup") && result.content.contains("Drink water"),
            "and names every reminder so the model can pick one to delete")
    }

    static func listIgnoresScriptTasks() {
        let store = store([script("Nightly Backup")])
        let result = run(store, call(SchedulerAITool.listName, "{}"))
        expect(
            !result.content.contains("Nightly Backup"),
            "a user's script automation is never exposed through the reminder surface")
    }

    static func deleteRemovesTheSoleReminder() {
        let store = store([reminder("Post the reel")])
        // The demoed failure: "delete that schedule" with a vague title must still remove the one.
        let result = run(
            store, call(SchedulerAITool.deleteName, #"{"title":"the previous reminder"}"#))
        expect(!result.isError, "a lone reminder is unambiguous even under a vague name")
        expect(store.tasks.isEmpty, "and is actually deleted, not re-created as a new reminder")
    }

    static func deletePrefersAnExactNameOverASubstring() {
        let store = store([reminder("Call"), reminder("Call mom")])
        let result = run(store, call(SchedulerAITool.deleteName, #"{"title":"Call"}"#))
        expect(!result.isError, "an exact name resolves even when it is a prefix of another")
        expect(
            store.tasks.count == 1 && store.tasks[0].name == "Call mom",
            "exactly the named reminder goes, not the one it is a substring of")
    }

    static func deleteReportsWhenNothingMatches() {
        let store = store([reminder("Standup"), reminder("Lunch")])
        let result = run(store, call(SchedulerAITool.deleteName, #"{"title":"Groceries"}"#))
        expect(result.isError, "a name that matches nothing is an error the model can recover from")
        expect(
            result.content.contains("Standup") && result.content.contains("Lunch"),
            "and lists what is scheduled so it can retry with a real name")
        expect(store.tasks.count == 2, "nothing is deleted on a miss")
    }

    static func deleteRefusesAnAmbiguousName() {
        let store = store([reminder("Standup team"), reminder("Standup 1:1")])
        let result = run(store, call(SchedulerAITool.deleteName, #"{"title":"standup"}"#))
        expect(result.isError, "a name matching several reminders is refused rather than guessed")
        expect(store.tasks.count == 2, "and none are deleted while it is ambiguous")
    }

    static func deleteNeverTouchesAScriptTask() {
        let store = store([script("Nightly Backup")])
        let result = run(store, call(SchedulerAITool.deleteName, #"{"title":"Nightly Backup"}"#))
        expect(result.isError, "the delete tool sees no reminders when only a script task exists")
        expect(store.tasks.count == 1, "so a user's automation is left intact")
    }
}
