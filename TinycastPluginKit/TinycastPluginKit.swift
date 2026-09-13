import SwiftUI

// MARK: - Metadata

/// What a plugin calls itself in the launcher, resolved before the dylib is ever loaded so the
/// row can exist without paying for the code behind it. The shipped `manifest.json` mirrors these.
public struct PluginMetadata: Sendable, Equatable {
    public var name: String
    public var subtitle: String
    /// An SF Symbol name; the launcher tile falls back to it when no artwork is supplied.
    public var icon: String

    public init(name: String, subtitle: String = "", icon: String = "puzzlepiece.extension") {
        self.name = name
        self.subtitle = subtitle
        self.icon = icon
    }
}

// MARK: - Context

/// Everything the host knows about the moment a plugin is asked for rows or runs an action.
/// A plugin takes the world as a parameter — it never reaches for the frontmost app itself.
public struct PluginContext: Sendable, Equatable {
    /// What the user has typed into the palette while the plugin owns it. Never `nil`; empty at root.
    public var query: String
    /// The app that was frontmost when the palette opened — an action's paste/return target.
    public var frontmostAppBundleID: String?
    /// The Finder selection when Finder was frontmost, else empty.
    public var finderSelection: [URL]

    public init(query: String = "", frontmostAppBundleID: String? = nil, finderSelection: [URL] = []) {
        self.query = query
        self.frontmostAppBundleID = frontmostAppBundleID
        self.finderSelection = finderSelection
    }
}

// MARK: - Icons

/// A row's glyph. Kept to values the host can resolve off-main; render an `NSImage` inside a surface
/// instead when you need bespoke artwork.
@frozen public enum PluginIcon: Sendable, Equatable {
    case symbol(String)
    case file(URL)
}

// MARK: - Results

/// What activating a row does. The host, not the plugin, drives the palette — the plugin only says
/// which of these should happen, and the host calls back into `perform`/`children`/`surface`.
@frozen public enum PluginAction: Sendable, Equatable {
    /// Inert: a header or a row that only matters as a parent for its children.
    case none
    /// Open a URL and close the launcher.
    case openURL(URL)
    /// Run headless: the host calls `perform(resultID:context:)` and honours its result.
    case run(id: String)
    /// Drill in: the host calls `children(of:context:)` and pushes the returned rows.
    case children(id: String)
    /// Take the palette over with SwiftUI: the host calls `surface(for:context:)`.
    case surface(id: String)
}

/// One launcher row a plugin produces. A value type by design: it crosses the dyly boundary as data,
/// so a plugin can hand back rows built off the main actor.
public struct PluginResult: Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String?
    /// A right-aligned hint — a shortcut, a branch, a price.
    public var trailingText: String?
    public var icon: PluginIcon
    /// Extra strings the palette matches against beyond `title`/`subtitle`.
    public var keywords: [String]
    public var action: PluginAction

    public init(
        id: String,
        title: String,
        subtitle: String? = nil,
        trailingText: String? = nil,
        icon: PluginIcon = .symbol("circle"),
        keywords: [String] = [],
        action: PluginAction = .none
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.icon = icon
        self.keywords = keywords
        self.action = action
    }
}

/// The outcome of a `.run` action. `message` shows in the host's HUD.
public struct PluginActionResult: Sendable, Equatable {
    public var closesLauncher: Bool
    public var message: String?

    public init(closesLauncher: Bool = true, message: String? = nil) {
        self.closesLauncher = closesLauncher
        self.message = message
    }

    /// Ran and finished — dismiss the launcher.
    public static let close = PluginActionResult(closesLauncher: true)
    /// Stay on the current list, e.g. after toggling something the rows reflect.
    public static let keepOpen = PluginActionResult(closesLauncher: false)
}

// MARK: - The plugin contract

/// A native Tinycast plugin. Conform an `NSObject` subclass or a plain `final class`, expose it
/// through a `@_cdecl("tinycastPluginCreate")` entry point (see `TinycastPluginRuntime.export`),
/// and build the package as a dynamic library.
///
/// The host runs every call on the main actor; heavy work belongs on a `Task.detached` you await.
@MainActor
public protocol TinycastPlugin: AnyObject {
    init()

    /// Fixed identity, read once when the plugin loads.
    static var metadata: PluginMetadata { get }

    /// The rows shown at the plugin's root, re-asked on every keystroke — filter on `context.query`.
    func results(for context: PluginContext) -> [PluginResult]

    /// Rows for a `.children` action. Runs async so it can hit the network or disk.
    func children(of resultID: String, context: PluginContext) async -> [PluginResult]

    /// Run a `.run` action. Runs async; return `.close`/`.keepOpen` (optionally with a message).
    func perform(resultID: String, context: PluginContext) async -> PluginActionResult

    /// The SwiftUI screen for a `.surface` action — the plugin owns the whole palette body.
    func surface(for resultID: String, context: PluginContext) -> AnyView
}

public extension TinycastPlugin {
    func children(of resultID: String, context: PluginContext) async -> [PluginResult] { [] }
    func perform(resultID: String, context: PluginContext) async -> PluginActionResult { .close }
    func surface(for resultID: String, context: PluginContext) -> AnyView { AnyView(EmptyView()) }
}

// MARK: - Loader handshake

/// The C entry point signature the host `dlsym`s. A plugin dylib must export exactly one symbol
/// named `tinycastPluginCreate` with this type.
public typealias TinycastPluginCreate = @convention(c) () -> UnsafeMutableRawPointer

/// The bridge between a plugin's `@_cdecl` entry point and the host loader.
public enum TinycastPluginRuntime {
    /// Wrap a freshly-made plugin for the host. Call this — and only this — from your entry point:
    ///
    /// ```swift
    /// @_cdecl("tinycastPluginCreate")
    /// public func tinycastPluginCreate() -> UnsafeMutableRawPointer {
    ///     TinycastPluginRuntime.export { MyPlugin() }
    /// }
    /// ```
    ///
    /// The host always calls the entry point on the main thread, so constructing a `@MainActor`
    /// plugin here is safe.
    public static func export(_ make: @MainActor () -> any TinycastPlugin) -> UnsafeMutableRawPointer {
        // The retained pointer leaves the isolated region as a bit pattern: a raw pointer's own
        // Sendable conformance is unavailable under Swift 6, but `UInt` crosses freely.
        let bits: UInt = MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(make() as AnyObject).toOpaque())
        }
        return UnsafeMutableRawPointer(bitPattern: bits)!
    }

    /// The host side of `export`: turn the opaque pointer back into a plugin. Balances the retain.
    public static func consume(_ pointer: UnsafeMutableRawPointer) -> (any TinycastPlugin)? {
        Unmanaged<AnyObject>.fromOpaque(pointer).takeRetainedValue() as? any TinycastPlugin
    }
}
