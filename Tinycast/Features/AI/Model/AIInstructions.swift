import Foundation

/// Every turn carries `AIPreamble`, then the user's text, then any enabled Skills; turned off, it
/// carries none of them.
enum AIInstructions {
    /// The user's own text goes after the preamble so it qualifies rather than fights it; enabled
    /// Skills follow, injected newest-first into `skillBudget` bytes with the overflow noted.
    static func compose(
        userPrompt: String?, skills: [Skill] = [], skillBudget: Int = AISkillBudget.default,
        isEnabled: Bool
    ) -> String? {
        guard isEnabled else { return nil }
        var parts = [AIPreamble.text]
        let prompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty { parts.append(prompt) }
        if let block = skillsBlock(skills, budget: skillBudget) { parts.append(block) }
        return parts.joined(separator: "\n\n")
    }

    private static func skillsBlock(_ skills: [Skill], budget: Int) -> String? {
        let usable = skills.filter {
            !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return nil }
        var body = "# Skills\n\nUse the following skills when the task calls for one:"
        var remaining = budget
        var omitted = 0
        for skill in usable {
            let section = "\n\n## \(skill.name)\n\(skill.instructions)"
            if section.utf8.count <= remaining {
                body += section
                remaining -= section.utf8.count
            } else {
                omitted += 1
            }
        }
        if omitted > 0 { body += "\n\n(\(omitted) more skill(s) omitted here for length.)" }
        return body
    }
}

/// How many bytes of Skill instructions a turn may carry. Injected every turn, so billed every turn;
/// the on-device route passes a far smaller cap because its window holds a prompt and reply together.
enum AISkillBudget {
    static let `default` = 16_000
    static let onDevice = 2_000
}
