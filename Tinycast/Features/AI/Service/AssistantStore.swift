import CoreGraphics
import Foundation
import Observation

/// The library of user-created Assistants, persisted as JSON in `UserDefaults`. Mirrors
/// `MCPSettingsStore`'s shape. Backup-excluded, like every other AI key.
@MainActor
@Observable
final class AssistantStore {
    private let defaults: UserDefaults

    /// Fires after any mutation so the launcher slice and hotkey registrations can re-sync.
    var onChange: (([Assistant]) -> Void)?

    private(set) var assistants: [Assistant] {
        didSet {
            persist()
            onChange?(assistants)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assistants = Self.decode(defaults.data(forKey: AppSettingsKey.aiAssistants.rawValue))
            .sorted { $0.order < $1.order }
    }

    func assistant(id: UUID) -> Assistant? {
        assistants.first { $0.id == id }
    }

    /// Upsert; a new assistant lands at the end of the order.
    func save(_ assistant: Assistant) {
        var assistant = assistant
        assistant.name = assistant.name.trimmingCharacters(in: .whitespaces)
        if let index = assistants.firstIndex(where: { $0.id == assistant.id }) {
            assistants[index] = assistant
        } else {
            assistant.order = (assistants.map(\.order).max() ?? -1) + 1
            assistants.append(assistant)
        }
        assistants.sort { $0.order < $1.order }
    }

    func remove(id: UUID) {
        assistants.removeAll { $0.id == id }
    }

    /// Persist one assistant's live model choice without disturbing the rest — the header menu path.
    func setModel(_ model: AIModelSelection?, for id: UUID) {
        mutate(id) { $0.model = model }
    }

    /// Persist a drag; `nil` clears the entry so the next summon re-centres on that display.
    func setPosition(_ offset: CGPoint?, for id: UUID, on display: String) {
        mutate(id) { $0.setPosition(offset, on: display) }
    }

    func setWidth(_ width: CGFloat?, for id: UUID) {
        mutate(id) { $0.width = width }
    }

    /// Reorder to match the given ids, then renumber so the persisted order is dense and stable.
    func reorder(_ orderedIDs: [UUID]) {
        let byID = Dictionary(uniqueKeysWithValues: assistants.map { ($0.id, $0) })
        var reordered = orderedIDs.compactMap { byID[$0] }
        for index in reordered.indices { reordered[index].order = index }
        // Anything not named keeps its relative place at the end, so a partial list never drops one.
        for var leftover in assistants where !orderedIDs.contains(leftover.id) {
            leftover.order = reordered.count
            reordered.append(leftover)
        }
        assistants = reordered
    }

    private func mutate(_ id: UUID, _ change: (inout Assistant) -> Void) {
        guard let index = assistants.firstIndex(where: { $0.id == id }) else { return }
        change(&assistants[index])
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(assistants) else { return }
        defaults.set(data, forKey: AppSettingsKey.aiAssistants.rawValue)
    }

    private static func decode(_ data: Data?) -> [Assistant] {
        guard let data, let assistants = try? JSONDecoder().decode([Assistant].self, from: data)
        else { return [] }
        return assistants
    }
}
