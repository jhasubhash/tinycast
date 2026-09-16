import Foundation

/// Every turn carries `AIPreamble`, then the user's text, then any enabled Skills; turned off, it
/// carries none of them.
enum AIInstructions {
    /// The user's own text goes after the preamble so it qualifies rather than fights it; enabled
    /// Skills follow, injected newest-first into `skillBudget` bytes with the overflow noted.
    /// `allowsSkillScripts` mirrors an assistant's shell-tools opt-in: only then is a skill's on-disk
    /// folder worth naming, since a skill's body often invokes its bundled scripts by a path relative
    /// to that folder (e.g. `./scripts/foo.py`), which resolves only if the model is told where it is.
    static func compose(
        userPrompt: String?, skills: [Skill] = [], skillBudget: Int = AISkillBudget.default,
        allowsSkillScripts: Bool = false, isEnabled: Bool
    ) -> String? {
        guard isEnabled else { return nil }
        var parts = [AIPreamble.text]
        let prompt = userPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !prompt.isEmpty { parts.append(prompt) }
        if let block = skillsBlock(skills, budget: skillBudget, allowsScripts: allowsSkillScripts) {
            parts.append(block)
        }
        return parts.joined(separator: "\n\n")
    }

    private static func skillsBlock(_ skills: [Skill], budget: Int, allowsScripts: Bool) -> String? {
        let usable = skills.filter {
            !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !usable.isEmpty else { return nil }
        var body = "# Skills\n\nUse the following skills when the task calls for one:"
        var remaining = budget
        var omitted = 0
        for skill in usable {
            var section = "\n\n## \(skill.name)\n\(skill.instructions)"
            if allowsScripts, !skill.sourcePath.isEmpty {
                section +=
                    "\n\n(This skill's own folder, including any bundled scripts, is at: "
                    + "\(skill.sourcePath))"
            }
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

/// How many bytes of Skill instructions a turn may carry. Injected every turn, so billed every turn on
/// an API route — `default` keeps that bounded, and the on-device route passes a far smaller cap
/// because its window holds a prompt and reply together. An installed CLI route (Claude, Codex,
/// OpenCode, Copilot) rides a paid subscription rather than per-token billing and opens a context
/// window an order of magnitude larger, so `cli` affords real-world Skills — often tens of KB — room
/// to land in full instead of being dropped wholesale for exceeding a budget sized for API cost.
enum AISkillBudget {
    static let `default` = 16_000
    static let onDevice = 2_000
    static let cli = 100_000
}
