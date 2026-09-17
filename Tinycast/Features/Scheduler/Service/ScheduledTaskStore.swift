import Foundation

/// The scheduled tasks, persisted as JSON in `UserDefaults` keyed by the bundle id like every store.
@MainActor
@Observable
final class ScheduledTaskStore {
    private(set) var tasks: [ScheduledTask] = []
    /// Fired after any change lands, so the coordinator reschedules and refreshes launcher rows.
    @ObservationIgnored var onChange: (([ScheduledTask]) -> Void)?

    private let defaults = UserDefaults.standard
    private let key = "scheduledTasks"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Read once at start; a decode failure drops to empty rather than losing the app.
    func load() {
        guard let data = defaults.data(forKey: key),
            let stored = try? decoder.decode([ScheduledTask].self, from: data)
        else { return }
        tasks = stored
    }

    func task(id: UUID) -> ScheduledTask? { tasks.first { $0.id == id } }

    func add(_ task: ScheduledTask) {
        tasks.append(task)
        persist()
    }

    func update(_ task: ScheduledTask) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
        persist()
    }

    func remove(id: UUID) {
        guard tasks.contains(where: { $0.id == id }) else { return }
        tasks.removeAll { $0.id == id }
        persist()
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].isEnabled != enabled
        else { return }
        tasks[index].isEnabled = enabled
        persist()
    }

    /// Records a fire without a user edit, so the next schedule advances from the right anchor.
    func markFired(id: UUID, at date: Date) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].lastFired = date
        persist()
    }

    private func persist() {
        if let data = try? encoder.encode(tasks) { defaults.set(data, forKey: key) }
        onChange?(tasks)
    }
}
