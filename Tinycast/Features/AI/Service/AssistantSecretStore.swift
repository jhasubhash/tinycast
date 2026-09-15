import Foundation

/// An assistant's environment variables — tokens a script-based Skill needs (e.g. an API token) —
/// held one Keychain item per assistant, never in `UserDefaults` or a backup. Mirrors `MCPSecretStore`.
struct AssistantSecretStore: Sendable {
    private let keychain: KeychainSecretStore

    init(keychain: KeychainSecretStore = .assistantEnvironment) {
        self.keychain = keychain
    }

    /// A read that fails reads as none: a missing or unreadable item is an empty environment.
    func environment(for assistantID: UUID) -> [String: String] {
        guard let stored = try? keychain.secret(for: assistantID),
            let environment = try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))
        else { return [:] }
        return environment
    }

    func save(_ environment: [String: String], for assistantID: UUID) throws {
        guard !environment.isEmpty else {
            try keychain.removeSecret(for: assistantID)
            return
        }
        let data = try JSONEncoder().encode(environment)
        guard let encoded = String(bytes: data, encoding: .utf8) else {
            throw KeychainSecretStore.StoreError.invalidEncoding
        }
        try keychain.setSecret(encoded, for: assistantID)
    }

    func remove(for assistantID: UUID) throws {
        try keychain.removeSecret(for: assistantID)
    }
}

extension AssistantSecretStore {
    /// Parse a `NAME=value` block (one per line) into an environment, the shape the editor field uses.
    static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...])
            guard !key.isEmpty else { continue }
            result[key] = value
        }
        return result
    }

    /// The reverse, sorted so the field is stable across opens.
    static func format(_ environment: [String: String]) -> String {
        environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }
}
