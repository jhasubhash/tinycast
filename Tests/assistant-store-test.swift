import CoreGraphics
import Foundation

@main
@MainActor
struct AssistantStoreTests {
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
        // AssistantStore
        saveAppendsNewAssistantsInDenseOrder()
        saveTrimsNameAndUpsertsInPlace()
        onChangeDeliversTheCurrentLibrary()
        setModelMutatesOnlyThatAssistant()
        reorderRenumbersDenselyAndKeepsLeftovers()
        removeDropsById()
        aStoreLoadsPersistedAssistantsSortedByOrder()

        // SkillStore
        enabledSkillsFiltersByIdAndLibrarySwitch()
        setEnabledTogglesAndPersists()
        importCopiesFolderAndParsesFrontmatter()
        importFromBareSkillMdWorks()
        importRejectsWhatIsNotASkill()
        reimportBySameNameKeepsIdentityAndEnabledState()
        importUniquesCollidingSlugs()
        removeDeletesFolderAndEntry()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    static func freshDefaults() -> UserDefaults {
        let name = "tinycast-assistant-store-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-skill-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - AssistantStore

    static func saveAppendsNewAssistantsInDenseOrder() {
        let store = AssistantStore(defaults: freshDefaults())
        store.save(Assistant(name: "First"))
        store.save(Assistant(name: "Second"))
        expect(store.assistants.map(\.order) == [0, 1], "each new assistant takes the next order")
        expect(
            store.assistants.map(\.name) == ["First", "Second"],
            "the library stays sorted by order")
    }

    static func saveTrimsNameAndUpsertsInPlace() {
        let store = AssistantStore(defaults: freshDefaults())
        var assistant = Assistant(name: "  Coding  ")
        store.save(assistant)
        expect(store.assistant(id: assistant.id)?.name == "Coding", "a saved name is trimmed")

        assistant.name = "Renamed"
        store.save(assistant)
        expect(store.assistants.count == 1, "re-saving the same id upserts rather than appends")
        expect(store.assistant(id: assistant.id)?.name == "Renamed", "the upsert takes the new value")
        expect(store.assistant(id: assistant.id)?.order == 0, "an upsert leaves the order untouched")
    }

    static func onChangeDeliversTheCurrentLibrary() {
        let store = AssistantStore(defaults: freshDefaults())
        var seen: [[Assistant]] = []
        store.onChange = { seen.append($0) }
        store.save(Assistant(name: "A"))
        store.save(Assistant(name: "B"))
        expect(!seen.isEmpty, "onChange fires when the library mutates")
        expect(
            seen.last?.map(\.name).sorted() == ["A", "B"],
            "onChange's last payload is the post-save library the launcher slice re-syncs from")
    }

    static func setModelMutatesOnlyThatAssistant() {
        let store = AssistantStore(defaults: freshDefaults())
        let a = Assistant(name: "A")
        let b = Assistant(name: "B")
        store.save(a)
        store.save(b)
        store.setModel(.appleIntelligence, for: a.id)
        expect(store.assistant(id: a.id)?.model == .appleIntelligence, "setModel updates its target")
        expect(store.assistant(id: b.id)?.model == nil, "setModel leaves the others alone")
    }

    static func reorderRenumbersDenselyAndKeepsLeftovers() {
        let store = AssistantStore(defaults: freshDefaults())
        let a = Assistant(name: "A")
        let b = Assistant(name: "B")
        let c = Assistant(name: "C")
        store.save(a)
        store.save(b)
        store.save(c)
        // Name only c then a; b is a leftover that must keep its place at the end, never dropped.
        store.reorder([c.id, a.id])
        expect(store.assistants.map(\.name) == ["C", "A", "B"], "the named order leads, leftovers trail")
        expect(store.assistants.map(\.order) == [0, 1, 2], "orders are renumbered densely")
    }

    static func removeDropsById() {
        let store = AssistantStore(defaults: freshDefaults())
        let a = Assistant(name: "A")
        let b = Assistant(name: "B")
        store.save(a)
        store.save(b)
        store.remove(id: a.id)
        expect(store.assistants.map(\.name) == ["B"], "remove drops exactly the named assistant")
    }

    static func aStoreLoadsPersistedAssistantsSortedByOrder() {
        let defaults = freshDefaults()
        let unordered = [
            Assistant(name: "Third", order: 2),
            Assistant(name: "First", order: 0),
            Assistant(name: "Second", order: 1)
        ]
        defaults.set(try! JSONEncoder().encode(unordered), forKey: AppSettingsKey.aiAssistants.rawValue)
        let store = AssistantStore(defaults: defaults)
        expect(
            store.assistants.map(\.name) == ["First", "Second", "Third"],
            "a new store loads persisted assistants sorted by order")
    }

    // MARK: - SkillStore

    static func enabledSkillsFiltersByIdAndLibrarySwitch() {
        let defaults = freshDefaults()
        let on1 = Skill(name: "On1", enabledInLibrary: true)
        let off = Skill(name: "Off", enabledInLibrary: false)
        let on2 = Skill(name: "On2", enabledInLibrary: true)
        defaults.set(
            try! JSONEncoder().encode([on1, off, on2]), forKey: AppSettingsKey.aiSkills.rawValue)
        let store = SkillStore(defaults: defaults, directory: tempDir())

        expect(
            store.enabledSkills(ids: [on1.id, off.id, on2.id]).map(\.name) == ["On1", "On2"],
            "a disabled skill is excluded even when its id is requested")
        expect(
            store.enabledSkills(ids: [off.id]).isEmpty,
            "requesting only a disabled skill yields nothing")
        expect(
            store.enabledSkills(ids: [on2.id]).map(\.name) == ["On2"],
            "an unreferenced enabled skill is not injected")
    }

    static func setEnabledTogglesAndPersists() {
        let defaults = freshDefaults()
        let skill = Skill(name: "Toggle", enabledInLibrary: true)
        defaults.set(try! JSONEncoder().encode([skill]), forKey: AppSettingsKey.aiSkills.rawValue)
        let store = SkillStore(defaults: defaults, directory: tempDir())
        store.setEnabled(false, for: skill.id)
        expect(store.skill(id: skill.id)?.enabledInLibrary == false, "setEnabled flips the switch")

        let reloaded = SkillStore(defaults: defaults, directory: tempDir())
        expect(
            reloaded.skill(id: skill.id)?.enabledInLibrary == false,
            "the switch state persists across store instances")
    }

    static func importCopiesFolderAndParsesFrontmatter() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())
        let source = tempDir()
        writeSkillMd(source, name: "PDF Forms", description: "Fill PDF forms", body: "Do the thing.")
        FileManager.default.createFile(
            atPath: source.appendingPathComponent("helper.py").path, contents: Data("x".utf8))

        guard let skill = try? store.importSkill(from: source) else {
            return expect(false, "importing a well-formed skill folder threw")
        }
        expect(skill.name == "PDF Forms", "the frontmatter name becomes the skill name")
        expect(skill.summary == "Fill PDF forms", "the description becomes the summary")
        expect(skill.instructions == "Do the thing.", "the body becomes the instructions")
        expect(store.skills.count == 1, "the imported skill is added to the library")
        expect(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: skill.sourcePath)
                    .appendingPathComponent("helper.py").path),
            "bundled resources travel into the library copy")
    }

    static func importFromBareSkillMdWorks() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())
        let source = tempDir()
        writeSkillMd(source, name: "Bare", description: "d", body: "b")
        let skill = try? store.importSkill(from: source.appendingPathComponent("SKILL.md"))
        expect(skill?.name == "Bare", "a url pointing straight at SKILL.md imports the folder")
    }

    static func importRejectsWhatIsNotASkill() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())

        let empty = tempDir()
        expect(
            throwsImportError(store, empty, .unreadable),
            "a folder without a SKILL.md is unreadable")

        let noFrontmatter = tempDir()
        FileManager.default.createFile(
            atPath: noFrontmatter.appendingPathComponent("SKILL.md").path,
            contents: Data("# Just a heading\n".utf8))
        expect(
            throwsImportError(store, noFrontmatter, .notASkill),
            "a SKILL.md without naming frontmatter is not a skill")
    }

    static func reimportBySameNameKeepsIdentityAndEnabledState() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())
        let first = tempDir()
        writeSkillMd(first, name: "Same", description: "v1", body: "old")
        let original = try! store.importSkill(from: first)
        store.setEnabled(false, for: original.id)

        let second = tempDir()
        writeSkillMd(second, name: "Same", description: "v2", body: "new")
        try? store.importSkill(from: second)

        expect(store.skills.count == 1, "re-importing the same name replaces rather than duplicates")
        expect(store.skills.first?.id == original.id, "the replacement keeps the original id")
        expect(store.skills.first?.instructions == "new", "the replacement carries the new body")
        expect(
            store.skills.first?.enabledInLibrary == false,
            "the replacement preserves the library on/off state")
    }

    static func importUniquesCollidingSlugs() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())
        let a = tempDir()
        writeSkillMd(a, name: "My Skill!", description: "d", body: "b")
        let b = tempDir()
        writeSkillMd(b, name: "my skill", description: "d", body: "b")

        let first = try! store.importSkill(from: a)
        let second = try! store.importSkill(from: b)
        expect(
            first.sourcePath != second.sourcePath,
            "two skills whose names slug alike land in distinct folders")
        expect(
            FileManager.default.fileExists(atPath: first.sourcePath)
                && FileManager.default.fileExists(atPath: second.sourcePath),
            "both library copies exist on disk")
    }

    static func removeDeletesFolderAndEntry() {
        let store = SkillStore(defaults: freshDefaults(), directory: tempDir())
        let source = tempDir()
        writeSkillMd(source, name: "Gone", description: "d", body: "b")
        let skill = try! store.importSkill(from: source)
        let path = skill.sourcePath
        store.remove(id: skill.id)
        expect(store.skills.isEmpty, "remove drops the entry")
        expect(
            !FileManager.default.fileExists(atPath: path),
            "remove deletes the library copy on disk")
    }

    // MARK: - Fixtures

    static func writeSkillMd(_ folder: URL, name: String, description: String, body: String) {
        let contents = "---\nname: \(name)\ndescription: \(description)\n---\n\(body)\n"
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("SKILL.md").path, contents: Data(contents.utf8))
    }

    static func throwsImportError(
        _ store: SkillStore, _ url: URL, _ expected: SkillStore.ImportError
    ) -> Bool {
        do {
            _ = try store.importSkill(from: url)
            return false
        } catch let error as SkillStore.ImportError {
            return error == expected
        } catch {
            return false
        }
    }
}
