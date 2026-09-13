import CryptoKit
import Foundation
import TinycastPluginKit

enum PluginLoadError: LocalizedError {
    case openFailed(String)
    case missingEntry(String)
    case wrongType(String)

    var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Couldn't load the plugin: \(message)"
        case .missingEntry(let name):
            return "\(name) has no tinycastPluginCreate entry point — rebuild it against TinycastPluginKit."
        case .wrongType(let name):
            return "\(name) doesn't conform to TinycastPlugin — check it's linked against this app's framework."
        }
    }
}

/// Loads a plugin's dylib and hands back its instance.
///
/// dlopen caches by path and a Swift dylib can't be safely dlclosed while its types are still
/// referenced, so opening a *rebuilt* plugin from its canonical path would return the stale image
/// and force a relaunch. Instead we map a **content-addressed copy** in the temp dir: unchanged
/// bytes reuse the one mapping, a rebuild maps the new bytes on the next open (no relaunch), and
/// older copies of that plugin are swept so at most one file per plugin lingers on disk. dlopen
/// still never closes — only a real rebuild costs one more small mapping, reclaimed when the app
/// quits.
enum PluginLoader {
    @MainActor
    static func load(_ install: PluginInstall) throws -> any TinycastPlugin {
        let path = stagedCopy(of: install) ?? install.dylibURL.path
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw PluginLoadError.openFailed(dlerror().map { String(cString: $0) } ?? "unknown error")
        }
        guard let symbol = dlsym(handle, "tinycastPluginCreate") else {
            throw PluginLoadError.missingEntry(install.manifest.name)
        }
        let create = unsafeBitCast(symbol, to: TinycastPluginCreate.self)
        guard let plugin = TinycastPluginRuntime.consume(create()) else {
            throw PluginLoadError.wrongType(install.manifest.name)
        }
        return plugin
    }

    /// Copies the dylib to `…/tinycast-plugin-<identifier>-<sha>.dylib`, reusing an identical
    /// existing copy and sweeping older ones for the same plugin. Returns nil on any failure, so
    /// the caller falls back to the canonical path. The ad-hoc signature is content-based, so the
    /// copy stays valid, and `@rpath/TinycastPluginKit.framework` resolves via the host executable
    /// regardless of where the dylib sits.
    private static func stagedCopy(of install: PluginInstall) -> String? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: install.dylibURL) else { return nil }
        let sha = SHA256.hash(data: data).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
        let slug =
            install.manifest.identifier
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let dir = fm.temporaryDirectory
        let prefix = "tinycast-plugin-\(slug)-"
        let dest = dir.appendingPathComponent("\(prefix)\(sha).dylib")

        if !fm.fileExists(atPath: dest.path) {
            do { try data.write(to: dest, options: .atomic) } catch { return nil }
        }
        if let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for url in entries
            where url.lastPathComponent.hasPrefix(prefix) && url != dest {
                try? fm.removeItem(at: url)  // stale copy of this plugin; a live mapping persists
            }
        }
        return dest.path
    }
}
