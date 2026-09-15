import SwiftUI
import UniformTypeIdentifiers

/// Settings → AI's Skills library: the imported Claude Agent Skills an assistant can enable. Import a
/// `SKILL.md` (or its folder), toggle each one on or off library-wide, and remove.
struct SkillsSettingsSection: View {
    @Environment(SkillStore.self) private var store
    @State private var importing = false
    @State private var error: String?

    var body: some View {
        Section {
            if store.skills.isEmpty {
                Text("No Skills yet. Import a Claude Agent Skill to make it available to your assistants.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.skills) { skill in
                    SkillRow(
                        skill: skill,
                        onToggle: { store.setEnabled($0, for: skill.id) },
                        onRemove: { store.remove(id: skill.id) })
                }
            }
            Button {
                importing = true
            } label: {
                Label { SettingsRowTitle(.aiSkills, "Import Skill") } icon: {
                    Image(systemName: "plus")
                }
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            SettingsSectionHeader(.aiSkills)
        } footer: {
            Text(
                "A Skill is a `SKILL.md` — a name, a when-to-use summary and instructions. Its scripts "
                    + "run only for an assistant with shell tools enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fileImporter(
            isPresented: $importing, allowedContentTypes: [.folder, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            handle(result)
        }
    }

    private func handle(_ result: Result<[URL], Error>) {
        error = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.importSkill(from: url)
        } catch SkillStore.ImportError.notASkill {
            error = "That folder has no SKILL.md with a name in its frontmatter."
        } catch {
            self.error = "That SKILL.md could not be read."
        }
    }
}
private struct SkillRow: View {
    let skill: Skill
    let onToggle: (Bool) -> Void
    let onRemove: () -> Void

    var body: some View {
        SettingsRow(title: skill.name, subtitle: skill.summary.isEmpty ? nil : skill.summary) {
            Image(systemName: "book.closed").foregroundStyle(.secondary)
        } trailing: {
            Toggle("Enabled", isOn: Binding(get: { skill.enabledInLibrary }, set: onToggle))
                .labelsHidden()
                .help(skill.enabledInLibrary ? "Enabled" : "Disabled")
            Button(action: onRemove) {
                Image(systemName: "trash").foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove \(skill.name)")
            .accessibilityLabel("Remove \(skill.name)")
        }
    }
}
