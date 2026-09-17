import SwiftUI

/// The scheduler pane: the master switch, then the user's own scheduled tasks.
struct SchedulerSettingsView: View {
    @Environment(ScheduledTaskStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var editor: EditorTarget?
    @State private var pendingDeletion: ScheduledTask?

    var body: some View {
        @Bindable var settings = settings
        return Form {
            FeatureSwitchSection(
                anchor: .schedulerScheduler,
                enableTitle: "Enable scheduler",
                enableSubtitle:
                    "Runs a script or posts a notification on a schedule, catching up on fires missed "
                    + "while the app was closed.",
                launcherSubtitle: "Find your tasks in launcher search to run them on demand.",
                isEnabled: $settings.schedulerEnabled,
                showsInLauncher: $settings.schedulerShowInLauncher)

            Section {
                if store.tasks.isEmpty {
                    Text("Add one to run it on a schedule, or on demand from the launcher.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sortedTasks) { task in
                        ScheduledTaskSettingsRow(
                            task: task,
                            showsInLauncher: settings.schedulerShowInLauncher,
                            isEnabled: Binding(
                                get: { task.isEnabled },
                                set: { store.setEnabled($0, for: task.id) }),
                            onEdit: { editor = EditorTarget(task: task) },
                            onDelete: { pendingDeletion = task })
                    }
                }
                Button {
                    editor = EditorTarget(task: nil)
                } label: {
                    SettingsRowTitle(.schedulerScheduler, "Create Scheduled Task")
                }
            } footer: {
                Text(
                    "Pick when it fires and what it does. A task keeps its own last-fired anchor, so "
                        + "editing the schedule never double-fires.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .settingsEnabled(settings.schedulerEnabled)

            FeatureCommandsSection(owner: .scheduler, anchor: .schedulerCommands)
                .settingsEnabled(settings.schedulerEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.scheduler)
        .releasesFocusOnOutsideClick()
        .sheet(item: $editor) { target in
            SchedulerTaskEditorSheet(task: target.task, dismiss: { editor = nil })
        }
        .alert(item: $pendingDeletion) { task in
            Alert(
                title: Text("Delete “\(task.name)”?"),
                message: Text("Its global shortcut and launcher references will also be removed."),
                primaryButton: .destructive(Text("Delete")) {
                    store.remove(id: task.id)
                },
                secondaryButton: .cancel())
        }
    }

    private var sortedTasks: [ScheduledTask] {
        store.tasks.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private struct EditorTarget: Identifiable {
    let id = UUID()
    let task: ScheduledTask?
}

private struct ScheduledTaskSettingsRow: View {
    let task: ScheduledTask
    let showsInLauncher: Bool
    @Binding var isEnabled: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        SettingsRow(title: task.name, subtitle: ScheduleFormatter.summary(of: task)) {
            Image(systemName: ScheduledTask.sfSymbol)
        } trailing: {
            // An alias only reaches the ranker through the launcher slice, so it dims with it.
            AliasField(key: task.entryID, name: task.name)
                .settingsEnabled(task.isEnabled && showsInLauncher)

            // A disabled task's shortcut fires into the coordinator's refusal, so it dims too.
            ShortcutRecorder(action: .scheduledTask(id: task.id))
                .settingsEnabled(task.isEnabled)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .help("Edit Task")
            .accessibilityLabel("Edit \(task.name)")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Delete Task")
            .accessibilityLabel("Delete \(task.name)")

            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help("Enabled")
                .accessibilityLabel("Enable \(task.name)")
        }
    }
}
