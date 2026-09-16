import Foundation
import Observation

/// The library of imported Claude Agent Skills. Metadata (and, for v1, the parsed body) persists as
/// JSON in `UserDefaults`; the imported `SKILL.md` folders live under `directory` so a reimport can
/// re-read them. Backup-excluded — a skill is instruction content the model is billed for.
@MainActor
@Observable
final class SkillStore {
    private let defaults: UserDefaults
    private let directory: URL

    private(set) var skills: [Skill] {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard, directory: URL) {
        self.defaults = defaults
        self.directory = directory
        skills = Self.decode(defaults.data(forKey: AppSettingsKey.aiSkills.rawValue))
    }

    func skill(id: UUID) -> Skill? {
        skills.first { $0.id == id }
    }

    /// The enabled skills an assistant references, in library order — what a turn injects.
    func enabledSkills(ids: Set<UUID>) -> [Skill] {
        skills.filter { ids.contains($0.id) && $0.enabledInLibrary }
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = skills.firstIndex(where: { $0.id == id }) else { return }
        skills[index].enabledInLibrary = enabled
    }

    enum ImportError: Error, Equatable {
        /// No `SKILL.md`, or it had no `---` frontmatter naming a `name`.
        case notASkill
        case unreadable
    }

    /// Copy a skill folder (or a bare `SKILL.md`) into the library, parse its frontmatter and body, and
    /// add it. `url` may point at the folder or at the `SKILL.md` itself.
    @discardableResult
    func importSkill(from url: URL) throws -> Skill {
        let manifestURL = url.lastPathComponent.lowercased() == "skill.md"
            ? url : url.appendingPathComponent("SKILL.md")
        guard let source = try? String(contentsOf: manifestURL, encoding: .utf8) else {
            throw ImportError.unreadable
        }
        guard let parsed = SkillFrontmatter.parse(source) else { throw ImportError.notASkill }

        let sourceFolder = manifestURL.deletingLastPathComponent()
        let slug = Self.slug(parsed.name, existing: Set(skills.map { Self.folderName($0.sourcePath) }))
        let destination = directory.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        // Copy the whole folder so bundled resources travel, even though v1 injects only the body.
        try FileManager.default.copyItem(at: sourceFolder, to: destination)

        let skill = Skill(
            name: parsed.name, summary: parsed.description, instructions: parsed.body,
            sourcePath: destination.path)
        if let index = skills.firstIndex(where: { $0.name == skill.name }) {
            skills[index] = Skill(
                id: skills[index].id, name: skill.name, summary: skill.summary,
                instructions: skill.instructions, sourcePath: skill.sourcePath,
                enabledInLibrary: skills[index].enabledInLibrary)
        } else {
            skills.append(skill)
        }
        return skill
    }

    func remove(id: UUID) {
        guard let skill = skill(id: id) else { return }
        if !skill.sourcePath.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: skill.sourcePath))
        }
        skills.removeAll { $0.id == id }
    }

    private static func folderName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    /// A filesystem-safe folder name from the skill's name, uniqued so two skills never collide.
    private static func slug(_ name: String, existing: Set<String>) -> String {
        var slug = ""
        var pendingSeparator = false
        for character in name.lowercased() {
            if character.isLetter || character.isNumber {
                if pendingSeparator, !slug.isEmpty { slug.append("-") }
                pendingSeparator = false
                slug.append(character)
            } else {
                pendingSeparator = true
            }
        }
        let base = slug.isEmpty ? "skill" : slug
        guard existing.contains(base) else { return base }
        var index = 2
        while existing.contains("\(base)-\(index)") { index += 1 }
        return "\(base)-\(index)"
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(skills) else { return }
        defaults.set(data, forKey: AppSettingsKey.aiSkills.rawValue)
    }

    private static func decode(_ data: Data?) -> [Skill] {
        guard let data, let skills = try? JSONDecoder().decode([Skill].self, from: data)
        else { return [] }
        return skills
    }
}
