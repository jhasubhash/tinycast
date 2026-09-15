import SwiftUI

/// Create or configure one Assistant. Edits a live draft and writes it through to the store on every
/// change, so there is no Cancel — Add already created the record, and Remove lives in the list.
struct AssistantEditorSheet: View {
    let assistantID: UUID
    let onClose: () -> Void

    @Environment(AssistantStore.self) private var store
    @Environment(SkillStore.self) private var skills
    @Environment(MCPSettingsStore.self) private var mcp
    @Environment(AppSettings.self) private var appSettings

    @State private var draft: Assistant

    init(assistantID: UUID, onClose: @escaping () -> Void) {
        self.assistantID = assistantID
        self.onClose = onClose
        // The store always has it — Add saved before opening — but a default keeps the sheet total.
        _draft = State(initialValue: AssistantStore().assistant(id: assistantID) ?? Assistant())
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                identitySection
                shortcutSection
                modelSection
                systemPromptSection
                skillsSection
                if appSettings.mcpEnabled { mcpSection }
                behaviourSection
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 640, height: 660)
        .onAppear { if let live = store.assistant(id: assistantID) { draft = live } }
        .onChange(of: draft) { store.save(draft) }
    }

    private var identitySection: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $draft.name, prompt: Text("Coding")).labelsHidden()
            }
            LabeledContent("Icon") {
                HStack(spacing: Theme.Spacing.md) {
                    AssistantGlyph(symbol: draft.symbol, tint: draft.tint)
                    TextField("Icon", text: $draft.symbol, prompt: Text("sparkles"))
                        .labelsHidden()
                        .frame(width: 160)
                }
            }
            LabeledContent("Colour") {
                Picker("Colour", selection: $draft.tint) {
                    ForEach(AssistantTint.allCases, id: \.self) { tint in
                        Text(tint.title).tag(tint)
                    }
                }
                .labelsHidden()
            }
        } header: {
            Text("Assistant")
        } footer: {
            Text("The icon is an SF Symbol name (like `wand.and.stars`) or a single emoji.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var shortcutSection: some View {
        Section {
            LabeledContent("Shortcut") {
                ShortcutRecorder(action: .assistant(id: draft.id))
            }
        } footer: {
            Text("Press this chord anywhere to summon \(draft.name.isEmpty ? "this assistant" : draft.name).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modelSection: some View {
        Section {
            AIModelSelectionRows(
                selection: draft.model,
                inheritedTitle: "Default model",
                select: { draft.model = $0 },
                modelLabel: { Text("Model") },
                effortLabel: { Text("Reasoning effort") })
            Toggle("Web search", isOn: $draft.webSearch)
        } header: {
            Text("Model")
        } footer: {
            Text("Leave on Default model to follow the global default; web search needs a model that supports it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var systemPromptSection: some View {
        Section {
            Toggle("Send a system prompt", isOn: $draft.systemPromptEnabled)
            SystemPromptEditor(text: $draft.systemPrompt)
                .settingsEnabled(draft.systemPromptEnabled)
        } header: {
            Text("System prompt")
        } footer: {
            Text("Added to every message, so it is billed every turn. This is what gives the assistant its persona.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var skillsSection: some View {
        Section {
            if skills.skills.isEmpty {
                Text("No Skills imported. Add some in the Skills library below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(skills.skills) { skill in
                    Toggle(isOn: skillBinding(skill.id)) {
                        Text(skill.name)
                        if !skill.summary.isEmpty {
                            Text(skill.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(!skill.enabledInLibrary)
                }
            }
        } header: {
            Text("Skills")
        } footer: {
            Text("Enabled Skills inject their instructions into every turn for this assistant.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var mcpSection: some View {
        Section {
            if mcp.servers.isEmpty {
                Text("No MCP servers configured. Add some in the MCP Servers section.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(mcp.servers) { server in
                    Toggle(server.title, isOn: mcpBinding(server.id))
                }
            }
        } header: {
            Text("MCP servers")
        } footer: {
            Text("Only the servers enabled here offer their tools to this assistant.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var behaviourSection: some View {
        Section {
            Picker("Opens to", selection: $draft.opensTo) {
                ForEach(AIOpensTo.allCases) { Text($0.title).tag($0) }
            }
            Picker("Start a new conversation after", selection: $draft.newChatAfter) {
                ForEach(AINewChatAfter.allCases) { Text($0.title).tag($0) }
            }
            Picker("Keep conversations", selection: $draft.retention) {
                ForEach(AIRetention.allCases) { Text($0.title).tag($0) }
            }
            .disabled(draft.ephemeral)
            Toggle("Ephemeral (never save conversations)", isOn: $draft.ephemeral)
            LabeledContent("Seed prompt") {
                TextField("Seed prompt", text: $draft.seedPrompt, prompt: Text("Ask me to refactor…"))
                    .labelsHidden()
            }
        } header: {
            Text("Behaviour")
        } footer: {
            Text("The seed prompt shows under the placeholder as a nudge; it is never sent on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func skillBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.skillIDs.contains(id) },
            set: { on in
                if on { draft.skillIDs.insert(id) } else { draft.skillIDs.remove(id) }
            })
    }

    private func mcpBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { draft.mcpServerIDs.contains(id) },
            set: { on in
                if on { draft.mcpServerIDs.insert(id) } else { draft.mcpServerIDs.remove(id) }
            })
    }
}
