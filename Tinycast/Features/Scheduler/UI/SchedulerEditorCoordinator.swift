import Foundation

/// Creates, edits, and deletes scheduled tasks from the launcher. The editor is an in-palette form
/// (`.schedulerEditor`), never a window or the Scheduler pane; delete confirms through the app's
/// own dialog, not an alert.
@MainActor
final class SchedulerEditorCoordinator {
    let store: ScheduledTaskStore
    /// Environment injection only — never for state this type owns.
    private unowned let core: AppCore
    /// The draft the editor form binds to, replaced on each open so re-editing shows the right task.
    private(set) var draft = ScheduledTaskDraft(task: nil)

    init(store: ScheduledTaskStore, core: AppCore) {
        self.store = store
        self.core = core
    }

    func createTask() {
        draft = ScheduledTaskDraft(task: nil)
        present()
    }

    func editTask(entryID: String) {
        guard let id = ScheduledTask.id(fromEntryID: entryID), let task = store.task(id: id)
        else { return }
        draft = ScheduledTaskDraft(task: task)
        present()
    }

    /// The launcher reminder fallback: parse a typed phrase into a notification task and confirm via
    /// a HUD, no form. The deterministic parser answers instantly; only its miss falls to the model.
    func scheduleFromPhrase(_ text: String) {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return }
        core.paletteCoordinator.hidePalette(restoreFocus: false)
        let now = Date(), calendar = Calendar.current
        if let parsed = ReminderPhraseParser.parse(phrase, now: now, calendar: calendar) {
            commit(parsed, now: now)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            if let parsed = await ReminderPhraseModel.extract(phrase, now: now, calendar: calendar) {
                commit(parsed, now: now)
            } else {
                core.showMessage("Couldn't find a time in “\(phrase)”.", tone: .danger)
            }
        }
    }

    private func commit(_ parsed: ParsedReminder, now: Date) {
        store.add(ScheduledTask.notification(title: parsed.title, rule: parsed.rule, now: now))
        core.showMessage("Reminder set — \(ScheduleFormatter.rule(parsed.rule))")
    }

    /// The form's primary action: persist the draft, then leave the editor.
    func save() {
        guard draft.isValid else { return }
        let task = draft.build()
        let editing = draft.isEditing
        if editing { store.update(task) } else { store.add(task) }
        finish()
        core.showMessage(editing ? "Scheduled task updated" : "Scheduled task created")
    }

    func deleteTask(entryID: String) {
        guard let id = ScheduledTask.id(fromEntryID: entryID), let task = store.task(id: id)
        else { return }
        confirmDelete(task)
    }

    /// Delete the task the editor is open on, from its ⌘K menu; leaves the editor once confirmed.
    func deleteEditing() {
        guard let id = draft.editingID, let task = store.task(id: id) else { return }
        confirmDelete(task) { [weak self] in self?.finish() }
    }

    /// Save or cancel from the form: back to whatever screen opened it, or hide when it was the root.
    func finish() {
        core.paletteCoordinator.closeScreen()
    }

    private func confirmDelete(_ task: ScheduledTask, then onDeleted: (() -> Void)? = nil) {
        Task {
            guard await core.confirm(
                title: "Delete “\(task.name)”?",
                message: "Its global shortcut and launcher references will also be removed.",
                symbol: ScheduledTask.sfSymbol, confirmTitle: "Delete")
            else { return }
            store.remove(id: task.id)
            onDeleted?()
        }
    }

    /// Push over an open launcher so ⎋ returns to it; a bare shortcut opens the form as the root.
    private func present() {
        if core.paletteCoordinator.isVisible {
            core.paletteCoordinator.navigate(to: .schedulerEditor)
        } else {
            core.paletteCoordinator.showPalette(mode: .schedulerEditor)
        }
    }
}
