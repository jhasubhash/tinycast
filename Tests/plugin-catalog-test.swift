import Foundation

@main
@MainActor
struct PluginCatalogTests {
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
        manifestRoundTripsThroughCodable()
        manifestDecodesWithoutOptionalKeys()
        installDerivesEntryIDAndDylibURL()
        identifierFromEntryIDRoundTrips()
        identifierRejectsNonPluginEntryIDs()
        scanReturnsOnlyWellFormedInstalls()
        scanSortsByNameCaseInsensitive()
        scanOnMissingRootIsEmptyNotAnError()
        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    // MARK: - Manifest

    static func manifestRoundTripsThroughCodable() {
        let manifest = PluginManifest(
            name: "Jira", identifier: "com.acme.jira", subtitle: "Issues", icon: "ticket",
            dylib: "libjira.dylib")
        guard
            let data = try? JSONEncoder().encode(manifest),
            let decoded = try? JSONDecoder().decode(PluginManifest.self, from: data)
        else { return expect(false, "manifest failed to round-trip through Codable") }
        expect(decoded == manifest, "a manifest survives an encode/decode round-trip intact")
    }

    /// A manifest that omits `subtitle`/`icon` must still decode — those keys are optional, and a
    /// plugin author is not required to write them.
    static func manifestDecodesWithoutOptionalKeys() {
        let json = Data(
            #"{"name":"Bare","identifier":"com.acme.bare","dylib":"bare.dylib"}"#.utf8)
        guard let decoded = try? JSONDecoder().decode(PluginManifest.self, from: json) else {
            return expect(false, "a manifest missing optional keys failed to decode")
        }
        expect(decoded.subtitle == nil, "an absent subtitle decodes as nil")
        expect(decoded.icon == nil, "an absent icon decodes as nil")
        expect(decoded.name == "Bare" && decoded.dylib == "bare.dylib", "the required keys decode")
    }

    // MARK: - Install identity

    static func installDerivesEntryIDAndDylibURL() {
        let dir = URL(fileURLWithPath: "/tmp/plugins/jira", isDirectory: true)
        let manifest = PluginManifest(
            name: "Jira", identifier: "com.acme.jira", subtitle: nil, icon: nil, dylib: "j.dylib")
        let install = PluginInstall(manifest: manifest, directory: dir)
        expect(install.id == "com.acme.jira", "an install's id is its manifest identifier")
        expect(install.entryID == "plugin:com.acme.jira", "the entry id namespaces the identifier")
        expect(
            install.dylibURL == dir.appendingPathComponent("j.dylib"),
            "the dylib url resolves against the plugin's own directory")
    }

    static func identifierFromEntryIDRoundTrips() {
        let manifest = PluginManifest(
            name: "X", identifier: "com.acme.x", subtitle: nil, icon: nil, dylib: "x.dylib")
        let install = PluginInstall(manifest: manifest, directory: URL(fileURLWithPath: "/tmp/x"))
        expect(
            PluginInstall.identifier(fromEntryID: install.entryID) == "com.acme.x",
            "the entry id round-trips back to the identifier")
    }

    static func identifierRejectsNonPluginEntryIDs() {
        expect(
            PluginInstall.identifier(fromEntryID: "assistant:123") == nil,
            "another feature's entry id is not read as a plugin's")
        expect(
            PluginInstall.identifier(fromEntryID: "com.acme.x") == nil,
            "a bare identifier without the prefix is not a plugin entry id")
        expect(
            PluginInstall.identifier(fromEntryID: "Plugin:x") == nil,
            "the prefix match is case-sensitive")
        expect(
            PluginInstall.identifier(fromEntryID: "plugin:") == "",
            "the prefix alone yields an empty identifier, not nil")
    }

    // MARK: - Scan

    static func scanReturnsOnlyWellFormedInstalls() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        writeInstall(root, folder: "good", identifier: "com.acme.good", dylib: "good.dylib",
            dropDylib: true)
        // A manifest whose dylib is absent is a half-copied install and must not appear.
        writeInstall(root, folder: "nodylib", identifier: "com.acme.nodylib", dylib: "missing.dylib",
            dropDylib: false)
        // A folder with a dylib but no manifest cannot be surfaced as a row.
        let noManifest = root.appendingPathComponent("nomanifest", isDirectory: true)
        try? FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: noManifest.appendingPathComponent("orphan.dylib").path, contents: Data())
        // A plain file sitting at the root is not a plugin directory.
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("stray.txt").path, contents: Data("hi".utf8))

        let installs = PluginCatalog.scan(root: root)
        expect(installs.count == 1, "scan returns only the one well-formed install")
        expect(
            installs.first?.manifest.identifier == "com.acme.good",
            "the surfaced install is the complete one")
    }

    static func scanSortsByNameCaseInsensitive() {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        writeInstall(root, folder: "c", identifier: "id.cherry", dylib: "d.dylib", dropDylib: true,
            name: "cherry")
        writeInstall(root, folder: "a", identifier: "id.apple", dylib: "d.dylib", dropDylib: true,
            name: "Apple")
        writeInstall(root, folder: "b", identifier: "id.banana", dylib: "d.dylib", dropDylib: true,
            name: "banana")

        let names = PluginCatalog.scan(root: root).map(\.manifest.name)
        expect(names == ["Apple", "banana", "cherry"], "installs sort case-insensitively by name")
    }

    static func scanOnMissingRootIsEmptyNotAnError() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-plugin-missing-\(UUID().uuidString)", isDirectory: true)
        expect(PluginCatalog.scan(root: missing).isEmpty, "scanning a missing root yields no installs")
    }

    // MARK: - Fixtures

    static func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tinycast-plugin-catalog-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func writeInstall(
        _ root: URL, folder: String, identifier: String, dylib: String, dropDylib: Bool,
        name: String? = nil
    ) {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest = PluginManifest(
            name: name ?? folder, identifier: identifier, subtitle: nil, icon: nil, dylib: dylib)
        let data = try? JSONEncoder().encode(manifest)
        try? data?.write(to: dir.appendingPathComponent("manifest.json"))
        if dropDylib {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(dylib).path, contents: Data())
        }
    }
}
