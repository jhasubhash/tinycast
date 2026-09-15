import Foundation

/// A Claude Agent Skill: a name, a "when to use" summary, and instruction text an assistant injects into
/// a turn. Pure and `Codable`; `SkillStore` imports it from a `SKILL.md` and persists the parsed result.
/// v1 uses the instruction text only — bundled scripts are never executed (see `Assistant_Architecture.md`).
struct Skill: Identifiable, Codable, Sendable, Equatable {
    let id: UUID
    var name: String
    /// The frontmatter `description` — "when to use this skill".
    var summary: String
    /// The `SKILL.md` body (frontmatter stripped), injected as instructions.
    var instructions: String
    /// The imported folder under application-support/skills; a reimport re-reads its `SKILL.md`.
    var sourcePath: String
    /// A global off switch, like an MCP server's; an assistant only ever sees enabled skills.
    var enabledInLibrary: Bool

    init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        instructions: String = "",
        sourcePath: String = "",
        enabledInLibrary: Bool = true
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.instructions = instructions
        self.sourcePath = sourcePath
        self.enabledInLibrary = enabledInLibrary
    }
}

/// Parses a Claude Agent Skill's `SKILL.md`: a leading `---` frontmatter block of `key: value` lines
/// (only `name` and `description` are read) followed by the markdown body. Pure, so `assistant-test`
/// drives it without a file. No full YAML — the frontmatter Anthropic's skills use is flat.
enum SkillFrontmatter {
    struct Parsed: Equatable, Sendable {
        var name: String
        var description: String
        var body: String
    }

    /// `nil` when there is no `---` frontmatter or it names no `name` — an unparseable skill is rejected
    /// at import rather than injected as a nameless block later.
    static func parse(_ source: String) -> Parsed? {
        var lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        // The frontmatter must open on the first non-empty line with a bare `---`.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        lines.removeFirst()

        var fields: [String: String] = [:]
        var closed = false
        var bodyStart = 0
        for (offset, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                closed = true
                bodyStart = offset + 1
                break
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'",
                value.last == first
            {
                value = String(value.dropFirst().dropLast())
            }
            if key == "name" || key == "description" { fields[key] = value }
        }
        guard closed, let name = fields["name"], !name.isEmpty else { return nil }

        let body = lines[bodyStart...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Parsed(name: name, description: fields["description"] ?? "", body: body)
    }
}
