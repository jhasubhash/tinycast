import SwiftUI

/// Add / edit form for a single scheduled task, hosted by the Scheduler pane's sheet. The launcher's
/// in-palette editor renders the same controls (`SchedulerTaskControls`) in its own layout; both
/// bind a `ScheduledTaskDraft`, so only chrome — title, buttons, width — differs between them.
struct SchedulerTaskEditorSheet: View {
    let dismiss: () -> Void

    @Environment(ScheduledTaskStore.self) private var store
    @State private var draft: ScheduledTaskDraft
    @FocusState private var nameFocused: Bool

    init(task: ScheduledTask?, dismiss: @escaping () -> Void) {
        self.dismiss = dismiss
        _draft = State(initialValue: ScheduledTaskDraft(task: task))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Text(draft.title)
                .font(.title2.weight(.bold))

            SchedulerNameField(draft: draft, focus: $nameFocused)
            SchedulerScheduleControls(draft: draft)
            SchedulerActionControls(draft: draft)
            SchedulerCatchUpControl(draft: draft)
            SchedulerDeleteControl(draft: draft)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!draft.isValid)
            }
        }
        .padding(Theme.Spacing.xxl)
        .frame(width: Theme.Size.editorSheetWidth)
        .onAppear { nameFocused = true }
    }

    private func save() {
        let task = draft.build()
        if draft.isEditing { store.update(task) } else { store.add(task) }
        dismiss()
    }
}
