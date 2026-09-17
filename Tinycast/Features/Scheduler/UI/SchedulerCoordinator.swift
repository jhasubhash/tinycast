import Foundation

/// Owns the single pending wake for the whole task set: it computes the next fire, sleeps to it,
/// fires whatever is due, records the fire, then re-arms. Catch-up replays fires missed while the
/// app (or the Mac) was off, bounded so a long sleep can't unleash a flood.
@MainActor
@Observable
final class SchedulerCoordinator {
    private let store: ScheduledTaskStore
    private let settings: AppSettings
    private let notifications: NotificationPresenter
    private let appIndex: AppIndex
    private let calendar = Calendar.current

    /// The most missed occurrences a single catch-up sweep will replay for one task.
    private static let catchUpCap = 25

    /// The one pending wake; replaced whenever the task set or the feature switch changes.
    @ObservationIgnored private var timer: Task<Void, Never>?

    init(
        store: ScheduledTaskStore, settings: AppSettings, notifications: NotificationPresenter,
        appIndex: AppIndex
    ) {
        self.store = store
        self.settings = settings
        self.notifications = notifications
        self.appIndex = appIndex
    }

    /// Called once from `AppCore.start()`: loads the store, wires its change hook, then arms.
    func applyEnabled() {
        store.onChange = { [weak self] _ in
            self?.applySchedulerPresence()
            self?.reschedule()
        }
        store.load()
        applySchedulerPresence()
        arm()
    }

    /// The feature switch flipped: re-project rows and re-arm (off cancels the timer).
    func applySchedulerEnabled() {
        applySchedulerPresence()
        arm()
    }

    /// Launcher rows for the enabled tasks, gated by both the feature and its show-in-launcher flag.
    func applySchedulerPresence() {
        let show = settings.schedulerEnabled && settings.schedulerShowInLauncher
        let entries = show ? store.tasks.filter(\.isEnabled).map(Self.entry) : []
        appIndex.setScheduledTasks(entries)
        appIndex.setCommandsVisible([.createScheduledTask], show)
    }

    /// Runs a task now, from a launcher row or its global shortcut; a disabled feature no-ops.
    func runTask(id: UUID) {
        guard settings.schedulerEnabled, let task = store.task(id: id) else { return }
        perform(task.action, name: task.name)
        if task.deleteAfterRun { store.remove(id: task.id) }
    }

    private static func entry(_ task: ScheduledTask) -> AppEntry {
        AppEntry(
            id: task.entryID, name: task.name,
            url: URL(string: "tinycast://scheduled-task/" + task.id.uuidString)!,
            bundleID: nil, kind: .scheduledTask)
    }

    // MARK: - Firing

    /// Off cancels the pending wake; on catches up on what was missed, then schedules the next.
    private func arm() {
        guard settings.schedulerEnabled else {
            timer?.cancel()
            timer = nil
            return
        }
        catchUp()
        reschedule()
    }

    /// The first occurrence a task owes past its last fire; also the sleep target for the set.
    private func nextFire(_ task: ScheduledTask) -> Date? {
        ScheduleEngine.nextFireDate(
            for: task, after: task.lastFired ?? task.createdAt, calendar: calendar)
    }

    private func reschedule() {
        timer?.cancel()
        guard settings.schedulerEnabled,
            let target = store.tasks.compactMap(nextFire).min()
        else {
            timer = nil
            return
        }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, target.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.fireDue()
        }
    }

    /// A small tolerance so a wake that lands a hair early still fires this tick.
    private func fireDue() {
        let now = Date()
        for task in store.tasks {
            guard let fireDate = nextFire(task), fireDate <= now.addingTimeInterval(0.5) else {
                continue
            }
            settle(task, firedAt: fireDate)
            perform(task.action, name: task.name)
        }
        reschedule()
    }

    /// Replays fires owed while the app was off, from each task's own last-fired anchor.
    private func catchUp() {
        let now = Date()
        for task in store.tasks where task.isEnabled {
            let since = task.lastFired ?? task.createdAt
            guard since < now else { continue }
            let missed = ScheduleEngine.missedOccurrences(
                for: task, since: since, until: now, calendar: calendar, cap: Self.catchUpCap)
            guard let last = missed.last else { continue }
            switch task.catchUp {
            case .skip:
                store.markFired(id: task.id, at: last)
            case .fireOnceOnResume:
                settle(task, firedAt: last)
                perform(task.action, name: task.name)
            case .fireEach:
                for _ in missed { perform(task.action, name: task.name) }
                settle(task, firedAt: last)
            }
        }
    }

    /// A one-shot task deletes itself once fired; anything else records the fire so the next advances.
    private func settle(_ task: ScheduledTask, firedAt date: Date) {
        if task.deleteAfterRun {
            store.remove(id: task.id)
        } else {
            store.markFired(id: task.id, at: date)
        }
    }

    private func perform(_ action: ScheduledAction, name: String) {
        switch action {
        case .postNotification(let spec):
            notifications.post(spec)
        case .runScript(let script):
            Task { [weak self] in
                let result = await ShellCommandRunner.run(
                    script.source, arguments: script.arguments,
                    loadingShellEnvironment: true, workingDirectory: script.workingDirectory)
                guard script.notifyOnFinish else { return }
                self?.notifyScriptFinished(name: name, result: result)
            }
        }
    }

    private func notifyScriptFinished(name: String, result: ShellCommandResult) {
        let body =
            result.succeeded
            ? (result.lastOutputLine ?? "Finished.")
            : "Failed."
        notifications.post(
            NotificationSpec(
                id: UUID(), title: name, body: body, style: .toast, corner: .topTrailing,
                dwell: 6, actions: []))
    }
}
