import CoreGraphics
import Foundation

@main
@MainActor
struct AssistantTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        assistantRoundTripsThroughCodable()
        assistantDecodesLegacyJSONMissingFields()
        providerRoundTripsBothCases()
        placementReadsAndWrites()
        skillRoundTripsThroughCodable()
        frontmatterParsesNameDescriptionAndBody()
        frontmatterRejectsWhatIsNotASkill()
        frontmatterStripsQuotesAndHandlesCRLF()

        composeInjectsEnabledSkills()
        composeTrimsSkillsPastTheBudget()
        composeWithoutSkillsIsPreambleAndPrompt()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func assistantRoundTripsThroughCodable() {
        let assistant = Assistant(
            name: "Coding", symbol: "chevron.left.forwardslash.chevron.right", tint: .purple,
            systemPrompt: "Review code carefully.", model: .appleIntelligence, webSearch: true,
            skillIDs: [UUID()], mcpServerIDs: [UUID()], opensTo: .newConversation,
            newChatAfter: .never, retention: .week, ephemeral: true, seedPrompt: "Paste a diff",
            positions: ["display-a": [12, 34]], width: 640, order: 3)
        guard let data = try? JSONEncoder().encode(assistant),
            let decoded = try? JSONDecoder().decode(Assistant.self, from: data)
        else {
            expect(false, "an assistant encodes and decodes")
            return
        }
        expect(decoded == assistant, "an assistant round-trips through Codable unchanged")
        expect(decoded.model == .appleIntelligence, "the chosen model survives the round trip")
        expect(decoded.width == 640, "a per-assistant width survives")
    }

    /// A saved assistant from before a field existed must still decode — a missing key falling back to
    /// its default, never failing the whole decode (which would drop every saved assistant).
    static func assistantDecodesLegacyJSONMissingFields() {
        // Only id and name — every other field is absent, as an early build would have written none.
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","name":"Legacy"}"#
        guard let decoded = try? JSONDecoder().decode(Assistant.self, from: Data(legacy.utf8)) else {
            expect(false, "a legacy assistant JSON missing new fields still decodes")
            return
        }
        expect(decoded.name == "Legacy", "the present fields decode")
        expect(decoded.allowCLITools == false, "a missing allowCLITools falls back to its default")
        expect(decoded.allowShellTools == false, "a missing allowShellTools falls back to its default")
        expect(decoded.opensTo == .recent, "a missing enum field falls back to its default")
        expect(decoded.symbol == "sparkles", "a missing string field falls back to its default")
    }

    static func providerRoundTripsBothCases() {
        for provider in [
            AssistantProvider.configured,
            .plugin(pluginID: "com.example.chart", descriptorID: "assistant-1"),
        ] {
            let assistant = Assistant(provider: provider, name: "X")
            guard let data = try? JSONEncoder().encode(assistant),
                let decoded = try? JSONDecoder().decode(Assistant.self, from: data)
            else {
                expect(false, "a \(provider) assistant encodes")
                continue
            }
            expect(decoded.provider == provider, "the provider case round-trips: \(provider)")
        }
        expect(Assistant(provider: .configured, name: "X").isPlugin == false, "configured is not a plugin")
        expect(
            Assistant(provider: .plugin(pluginID: "a", descriptorID: "b"), name: "X").isPlugin,
            "a plugin-provided assistant reports isPlugin")
    }

    static func placementReadsAndWrites() {
        var assistant = Assistant(name: "X")
        expect(assistant.position(on: "d1") == nil, "an unplaced assistant has no position on a display")
        assistant.setPosition(CGPoint(x: 100, y: 200), on: "d1")
        expect(assistant.position(on: "d1") == CGPoint(x: 100, y: 200), "a placement reads back")
        assistant.setPosition(nil, on: "d1")
        expect(assistant.position(on: "d1") == nil, "clearing a placement removes it")
    }

    static func skillRoundTripsThroughCodable() {
        let skill = Skill(
            name: "pdf-forms", summary: "Fill PDF forms", instructions: "Step 1...",
            sourcePath: "/skills/pdf-forms", enabledInLibrary: false)
        guard let data = try? JSONEncoder().encode(skill),
            let decoded = try? JSONDecoder().decode(Skill.self, from: data)
        else {
            expect(false, "a skill encodes and decodes")
            return
        }
        expect(decoded == skill, "a skill round-trips through Codable unchanged")
    }

    static func frontmatterParsesNameDescriptionAndBody() {
        let source = """
            ---
            name: pdf-forms
            description: Fill, read and flatten PDF forms.
            ---

            # PDF forms

            Follow these steps.
            """
        guard let parsed = SkillFrontmatter.parse(source) else {
            expect(false, "a well-formed SKILL.md parses")
            return
        }
        expect(parsed.name == "pdf-forms", "the name comes from the frontmatter")
        expect(parsed.description == "Fill, read and flatten PDF forms.", "the description is read")
        expect(
            parsed.body == "# PDF forms\n\nFollow these steps.",
            "the body is everything after the frontmatter, trimmed")
    }

    static func frontmatterRejectsWhatIsNotASkill() {
        expect(SkillFrontmatter.parse("Just some markdown, no frontmatter.") == nil, "no frontmatter is rejected")
        expect(
            SkillFrontmatter.parse("---\ndescription: no name here\n---\nbody") == nil,
            "frontmatter without a name is rejected")
        expect(
            SkillFrontmatter.parse("---\nname: unclosed\nbody with no closing fence") == nil,
            "an unclosed frontmatter is rejected")
    }

    static func frontmatterStripsQuotesAndHandlesCRLF() {
        let source = "---\r\nname: \"Quoted Name\"\r\ndescription: 'single quoted'\r\n---\r\nBody line."
        guard let parsed = SkillFrontmatter.parse(source) else {
            expect(false, "a CRLF SKILL.md parses")
            return
        }
        expect(parsed.name == "Quoted Name", "double quotes are stripped from a value")
        expect(parsed.description == "single quoted", "single quotes are stripped from a value")
        expect(parsed.body == "Body line.", "CRLF newlines are normalised and the body is read")
    }

    static func composeInjectsEnabledSkills() {
        let skills = [
            Skill(name: "pdf", instructions: "Handle PDFs."),
            Skill(name: "csv", instructions: "Handle CSVs."),
        ]
        guard let composed = AIInstructions.compose(
            userPrompt: "Be terse.", skills: skills, isEnabled: true)
        else {
            expect(false, "compose returns instructions when enabled")
            return
        }
        expect(composed.hasPrefix(AIPreamble.text), "the preamble leads")
        expect(composed.contains("Be terse."), "the user prompt is carried")
        expect(composed.contains("# Skills"), "enabled skills are injected under a heading")
        expect(composed.contains("## pdf") && composed.contains("Handle PDFs."), "a skill's body is injected")
        expect(composed.contains("## csv"), "every enabled skill is injected")
    }

    static func composeTrimsSkillsPastTheBudget() {
        let big = String(repeating: "x", count: 500)
        let skills = (0..<10).map { Skill(name: "s\($0)", instructions: big) }
        guard let composed = AIInstructions.compose(
            userPrompt: nil, skills: skills, skillBudget: 1_200, isEnabled: true)
        else {
            expect(false, "compose returns instructions with skills")
            return
        }
        expect(composed.contains("omitted here for length"), "skills past the budget are noted, not injected")
        expect(composed.utf8.count < AIPreamble.text.utf8.count + 5_000, "the budget caps the injected total")
    }

    static func composeWithoutSkillsIsPreambleAndPrompt() {
        let composed = AIInstructions.compose(userPrompt: "Hi.", isEnabled: true)
        expect(composed == AIPreamble.text + "\n\n" + "Hi.", "no skills leaves the classic composition")
        expect(AIInstructions.compose(userPrompt: "x", isEnabled: false) == nil, "disabled carries nothing")
    }
}
