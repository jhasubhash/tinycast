import SwiftUI

/// The scheduled-task editor as an in-palette form: the launcher panel morphs to host it, the
/// search field is hidden, and the palette's own footer carries the actions — Save on ↵ and, when
/// editing, Delete under ⌘K. The form owns no buttons of its own.
struct SchedulerEditorScreen: PaletteScreen {
    /// The form owns the keyboard whole; it has no rows the palette selects between.
    struct Row: Identifiable { let id: Int }

    let coordinator: SchedulerEditorCoordinator
    let vm: PaletteState

    var rows: [Row] { [] }
    var hidesSearchField: Bool { true }
    var actsWithoutRows: Bool { true }
    var primaryActionTitle: String { coordinator.draft.isEditing ? "Save Task" : "Create Task" }

    func hasPrimaryAction(at selection: Int) -> Bool { true }
    func hasActions(at selection: Int) -> Bool { coordinator.draft.isEditing }

    func activate(at selection: Int) {
        guard coordinator.draft.isValid else { return }
        coordinator.save()
    }

    func secondary(at selection: Int) -> Bool { false }

    func actions(at selection: Int) -> PopoverMenuContent? {
        guard coordinator.draft.isEditing else { return nil }
        return PopoverMenuContent(items: [
            PopoverMenuItem(
                title: "Delete Scheduled Task", systemImage: "trash", isDestructive: true
            ) { coordinator.deleteEditing() }
        ])
    }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        // Standard TextFields swallow ↵, so the panel's return handler never sees it; onSubmit
        // lets a focused single-line field save, while the Command editor keeps its newlines.
        AnyView(
            SchedulerEditorForm(draft: coordinator.draft, vm: vm)
                .onSubmit { activate(at: selection) })
    }
}

/// Lays the shared controls out in two columns so the whole form fits the fixed palette panel
/// without scrolling, and hands the keyboard to the form while it is up.
private struct SchedulerEditorForm: View {
    @Bindable var draft: ScheduledTaskDraft
    let vm: PaletteState
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "calendar.badge.plus")
                    .font(.title3)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Text(draft.title)
                    .font(.title3.weight(.bold))
            }

            SchedulerNameField(draft: draft, focus: $nameFocused)

            HStack(alignment: .top, spacing: Theme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    SchedulerScheduleControls(draft: draft)
                    SchedulerCatchUpControl(draft: draft)
                    SchedulerDeleteControl(draft: draft)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                SchedulerActionControls(draft: draft)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Spacing.xxl)
        .padding(.vertical, Theme.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            vm.noteEditingField(true)
            // The panel is key but not yet ready for a field to take first responder on the same
            // tick the screen mounts, so hand it the Name field one runloop later.
            Task { @MainActor in nameFocused = true }
        }
        .onDisappear { vm.noteEditingField(false) }
    }
}
