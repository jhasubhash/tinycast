import SwiftUI

/// Settings → AI's Assistants list: each named chat bar, its glyph and its shortcut, with Add, Edit and
/// Remove. The editor lives in `AssistantEditorSheet`; the Skills library it draws from is its own
/// section below.
struct AssistantsSettingsSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AssistantStore.self) private var store
    @Environment(AppSettings.self) private var appSettings
    @State private var editing: UUID?
    @State private var pendingRemoval: Assistant?

    var body: some View {
        Section {
            if store.assistants.isEmpty {
                Text("No assistants yet. Add one to give a persona its own bar, model and shortcut.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.assistants) { assistant in
                    AssistantRow(
                        assistant: assistant,
                        onEdit: { editing = assistant.id },
                        onRemove: { pendingRemoval = assistant })
                }
            }
            Button(action: add) {
                Label { SettingsRowTitle(.aiAssistants, "Add Assistant") } icon: {
                    Image(systemName: "plus")
                }
            }
            if !store.assistants.isEmpty {
                Toggle(isOn: showInLauncher) {
                    SettingsRowTitle(.aiAssistants, "Show in launcher")
                    Text("List each assistant as an “Ask …” command in the launcher.")
                }
            }
        } header: {
            SettingsSectionHeader(.aiAssistants)
        } footer: {
            Text("Each assistant carries its own prompt, model, Skills, MCP servers and conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .sheet(item: editingBinding) { id in
            AssistantEditorSheet(assistantID: id.id, onClose: { editing = nil })
        }
        .confirmationDialog(
            "Remove \(removalName)?", isPresented: removalBinding, presenting: pendingRemoval
        ) { assistant in
            Button("Remove", role: .destructive) { remove(assistant) }
        } message: { _ in
            Text("Its bar, shortcut and saved conversations are deleted. Skills stay in the library.")
        }
    }

    private var removalName: String {
        let name = pendingRemoval?.name ?? ""
        return name.isEmpty ? "this assistant" : name
    }

    private var editingBinding: Binding<IdentifiedUUID?> {
        Binding(get: { editing.map(IdentifiedUUID.init) }, set: { editing = $0?.id })
    }

    private var removalBinding: Binding<Bool> {
        Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
    }

    private var showInLauncher: Binding<Bool> {
        Binding(
            get: { appSettings.aiAssistantsShowInLauncher },
            set: { appSettings.aiAssistantsShowInLauncher = $0 })
    }

    private func add() {
        let assistant = Assistant(name: "New Assistant")
        store.save(assistant)
        editing = assistant.id
    }

    private func remove(_ assistant: Assistant) {
        core.aiChatCoordinator.removeAssistant(id: assistant.id)
    }
}

/// A `sheet(item:)` needs an `Identifiable`; a bare `UUID` is not one on its own.
struct IdentifiedUUID: Identifiable {
    let id: UUID
}

private struct AssistantRow: View {
    let assistant: Assistant
    let onEdit: () -> Void
    let onRemove: () -> Void

    @Environment(HotKeyManager.self) private var hotKeys

    var body: some View {
        SettingsRow(title: assistant.name.isEmpty ? "Untitled" : assistant.name, subtitle: subtitle) {
            AssistantGlyph(symbol: assistant.symbol, tint: assistant.tint)
        } trailing: {
            Button(action: onEdit) { Image(systemName: "pencil") }
                .buttonStyle(.plain)
                .help("Edit \(assistant.name)")
                .accessibilityLabel("Edit \(assistant.name)")
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove \(assistant.name)")
            .accessibilityLabel("Remove \(assistant.name)")
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        parts.append(hotKeys.binding(for: .assistant(id: assistant.id)) != nil ? "Shortcut" : "No shortcut")
        if !assistant.skillIDs.isEmpty {
            parts.append(assistant.skillIDs.count == 1 ? "1 Skill" : "\(assistant.skillIDs.count) Skills")
        }
        if assistant.webSearch { parts.append("Web") }
        if assistant.ephemeral { parts.append("Ephemeral") }
        return parts.joined(separator: " · ")
    }
}

/// The assistant's glyph: an emoji rendered as text, or an SF Symbol rendered in its tint.
struct AssistantGlyph: View {
    let symbol: String
    let tint: AssistantTint

    var body: some View {
        if symbol.unicodeScalars.contains(where: { $0.properties.isEmoji && $0.value > 0x238C }) {
            Text(symbol)
        } else {
            Image(systemName: symbol.isEmpty ? "sparkles" : symbol)
                .foregroundStyle(tint.color)
        }
    }
}
