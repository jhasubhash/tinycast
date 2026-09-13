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

/// Loads a plugin's dylib and hands back its instance. The handle is deliberately never closed:
/// unloading a Swift dylib whose types are still referenced is unsafe, and dlopen reference-counts,
/// so re-launching the same plugin is cheap.
enum PluginLoader {
    @MainActor
    static func load(_ install: PluginInstall) throws -> any TinycastPlugin {
        guard let handle = dlopen(install.dylibURL.path, RTLD_NOW | RTLD_LOCAL) else {
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
}
