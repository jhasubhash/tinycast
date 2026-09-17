import SwiftUI

/// The scheduled-task form controls, bound to a shared `ScheduledTaskDraft`. Both hosts — the
/// Scheduler pane's sheet and the launcher's in-palette editor — render these same blocks and only
/// differ in how they arrange them, so a restyle here lands on both surfaces at once.

/// A titled control group, the form's repeated unit.
struct SchedulerField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(Theme.Colors.textSecondary)
            content
        }
    }
}

/// The form's segmented control: mono `DialogChip` capsules, matching the New Event dialog.
struct SchedulerChips<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ForEach(options, id: \.0) { option in
                DialogChip(title: option.1, selected: option.0 == selection) {
                    selection = option.0
                }
            }
        }
    }
}

struct SchedulerNameField: View {
    @Bindable var draft: ScheduledTaskDraft
    let focus: FocusState<Bool>.Binding

    var body: some View {
        SchedulerField(title: "Name") {
            TextField("Nightly Backup", text: $draft.name)
                .dialogTextField()
                .focused(focus)
        }
    }
}

struct SchedulerScheduleControls: View {
    @Bindable var draft: ScheduledTaskDraft

    var body: some View {
        SchedulerField(title: "When") {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                SchedulerChips(
                    options: ScheduledTaskDraft.RuleKind.allCases.map { ($0, $0.label) },
                    selection: $draft.ruleKind)
                detail
            }
        }
        .onChange(of: draft.ruleKind) { _, kind in
            draft.deleteAfterRun = (kind == .once)
        }
    }

    @ViewBuilder private var detail: some View {
        switch draft.ruleKind {
        case .once:
            HStack(spacing: Theme.Spacing.sm) {
                DatePicker("", selection: $draft.onceDate, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                DatePicker("", selection: $draft.onceDate, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.compact)
                    .labelsHidden()
            }
        case .interval:
            HStack(spacing: Theme.Spacing.sm) {
                Text("Every").foregroundStyle(Theme.Colors.textSecondary)
                TextField("1", value: $draft.intervalValue, format: .number)
                    .dialogTextField()
                    .frame(width: 56)
                Picker("", selection: $draft.intervalUnit) {
                    ForEach(ScheduledTaskDraft.IntervalUnit.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 110)
            }
        case .daily:
            timeField
        case .weekly:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                weekdayField
                timeField
            }
        case .monthly:
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("On day").foregroundStyle(Theme.Colors.textSecondary)
                    Picker("", selection: $draft.monthDay) {
                        ForEach(1...31, id: \.self) { Text("\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 72)
                }
                timeField
            }
        }
    }

    private var timeField: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text("At").foregroundStyle(Theme.Colors.textSecondary)
            DatePicker("", selection: $draft.timeOfDay, displayedComponents: .hourAndMinute)
                .datePickerStyle(.compact)
                .labelsHidden()
                .fixedSize()
        }
    }

    private var weekdayField: some View {
        let symbols = Calendar.current.veryShortWeekdaySymbols
        return HStack(spacing: Theme.Spacing.xs) {
            ForEach(Array(symbols.enumerated()), id: \.offset) { index, symbol in
                let weekday = index + 1
                DialogChip(title: symbol, selected: draft.weekdays.contains(weekday)) {
                    toggleWeekday(weekday)
                }
            }
        }
    }

    private func toggleWeekday(_ weekday: Int) {
        if draft.weekdays.contains(weekday) {
            draft.weekdays.remove(weekday)
        } else {
            draft.weekdays.insert(weekday)
        }
    }
}

struct SchedulerActionControls: View {
    @Bindable var draft: ScheduledTaskDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SchedulerField(title: "Action") {
                SchedulerChips(
                    options: ScheduledTaskDraft.ActionKind.allCases.map { ($0, $0.label) },
                    selection: $draft.actionKind)
            }
            if draft.actionKind == .script {
                scriptFields
            } else {
                notificationFields
            }
        }
    }

    private var scriptFields: some View {
        Group {
            SchedulerField(title: "Command") {
                TextEditor(text: $draft.scriptSource)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(Theme.Spacing.sm)
                    .frame(height: Theme.Size.editorTextHeight)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .fill(Theme.Colors.cardFill))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                            .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
                    .contentShape(Rectangle())
                    .pointerStyle(.horizontalText)
            }
            SchedulerField(title: "Working directory (optional)") {
                TextField("~", text: $draft.workingDirectory)
                    .dialogTextField()
            }
            Toggle("Notify when it finishes", isOn: $draft.notifyOnFinish)
                .toggleStyle(.checkbox)
                .tint(Theme.Colors.textPrimary)
        }
    }

    private var notificationFields: some View {
        Group {
            SchedulerField(title: "Title") {
                TextField("Reminder", text: $draft.notifyTitle)
                    .dialogTextField()
            }
            SchedulerField(title: "Body") {
                TextField("", text: $draft.notifyBody)
                    .dialogTextField()
            }
            HStack(spacing: Theme.Spacing.lg) {
                SchedulerField(title: "Style") {
                    Picker("", selection: $draft.notifyStyle) {
                        ForEach(NotificationStyle.allCases, id: \.self) {
                            Text($0.rawValue.capitalized).tag($0)
                        }
                    }
                    .labelsHidden()
                }
                SchedulerField(title: "Corner") {
                    Picker("", selection: $draft.notifyCorner) {
                        ForEach(NotificationCorner.allCases, id: \.self) {
                            Text(schedulerCornerLabel($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                }
            }
            Toggle("Stay until dismissed", isOn: $draft.notifySticky)
                .toggleStyle(.checkbox)
                .tint(Theme.Colors.textPrimary)
            if !draft.notifySticky {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Dismiss after").foregroundStyle(Theme.Colors.textSecondary)
                    TextField("6", value: $draft.notifyDwell, format: .number)
                        .dialogTextField()
                        .frame(width: 56)
                    Text("seconds").foregroundStyle(Theme.Colors.textSecondary)
                }
            }
        }
    }
}

struct SchedulerCatchUpControl: View {
    @Bindable var draft: ScheduledTaskDraft

    var body: some View {
        SchedulerField(title: "If fires were missed while closed") {
            SchedulerChips(
                options: [
                    (CatchUpPolicy.skip, "Skip"),
                    (CatchUpPolicy.fireOnceOnResume, "Once on resume"),
                    (CatchUpPolicy.fireEach, "Each missed"),
                ],
                selection: $draft.catchUp)
        }
    }
}

struct SchedulerDeleteControl: View {
    @Bindable var draft: ScheduledTaskDraft

    var body: some View {
        if draft.ruleKind == .once {
            Toggle("Delete after it runs", isOn: $draft.deleteAfterRun)
                .toggleStyle(.checkbox)
                .tint(Theme.Colors.textPrimary)
        }
    }
}

private func schedulerCornerLabel(_ corner: NotificationCorner) -> String {
    switch corner {
    case .topLeading: return "Top Left"
    case .topTrailing: return "Top Right"
    case .bottomLeading: return "Bottom Left"
    case .bottomTrailing: return "Bottom Right"
    }
}
