import Foundation

/// The on-disk descriptor that lets a plugin's launcher row exist before its dylib is loaded.
/// Mirrors the `PluginMetadata` the code reports; the row uses this, the session uses the code.
struct PluginManifest: Codable, Sendable, Hashable {
    let name: String
    let identifier: String
    var subtitle: String?
    var icon: String?
    /// The dynamic library's filename, relative to the plugin's own directory.
    let dylib: String
}

/// An installed plugin: its manifest plus where it lives.
struct PluginInstall: Sendable, Hashable, Identifiable {
    let manifest: PluginManifest
    let directory: URL

    var id: String { manifest.identifier }
    /// The `AppEntry.id` a plugin is surfaced under; survives a reinstall since it keys on identity.
    var entryID: String { "plugin:\(manifest.identifier)" }
    var dylibURL: URL { directory.appendingPathComponent(manifest.dylib) }

    /// The identifier a `plugin:` entry id carries, or nil when the id isn't a plugin's.
    static func identifier(fromEntryID entryID: String) -> String? {
        let prefix = "plugin:"
        guard entryID.hasPrefix(prefix) else { return nil }
        return String(entryID.dropFirst(prefix.count))
    }
}

/// Finds installed plugins under the per-channel support directory: one folder each, with a
/// `manifest.json` and the dylib it names.
enum PluginCatalog {
    static func pluginsDirectory() -> URL {
        let url = AppPaths.applicationSupport().appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A directory without a readable `manifest.json` whose dylib exists on disk is skipped, not an
    /// error: a half-copied install simply doesn't appear.
    nonisolated static func scan(root: URL = PluginCatalog.pluginsDirectory()) -> [PluginInstall] {
        let dirs =
            (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        let decoder = JSONDecoder()
        return
            dirs
            .compactMap { dir -> PluginInstall? in
                guard
                    (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                    let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                    let manifest = try? decoder.decode(PluginManifest.self, from: data),
                    FileManager.default.fileExists(
                        atPath: dir.appendingPathComponent(manifest.dylib).path)
                else { return nil }
                return PluginInstall(manifest: manifest, directory: dir)
            }
            .sorted {
                $0.manifest.name.localizedCaseInsensitiveCompare($1.manifest.name) == .orderedAscending
            }
    }
}
