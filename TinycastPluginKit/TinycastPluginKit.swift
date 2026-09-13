import AppKit
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

    /// The host calls this once, just after your plugin loads, handing you a closure that
    /// invalidates your rows. Call it whenever `results(for:)` would now return something different
    /// — async data arrived, a favourite toggled — and the palette re-asks `results(for:)`. Without
    /// it, rows refresh only when the user types or navigates. Store the closure; a plugin whose
    /// rows never change on their own can ignore this.
    func bind(reload: @escaping () -> Void)

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
    func bind(reload: @escaping () -> Void) {}
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

// MARK: - Surface navigation

/// A plugin surface's own view stack. Push a view to drill in; Escape pops it, and once the stack
/// is back at the root a further Escape leaves the plugin. A surface owns its whole navigation, so
/// the host never draws a back chevron over one — the scaffold does, and Escape drives it.
@MainActor
@Observable
public final class PluginNavigator {
    struct Entry: Identifiable {
        let id = UUID()
        let title: String?
        let view: AnyView
    }

    private(set) var stack: [Entry] = []

    public init() {}

    /// Drill into `view`; `title` shows in the scaffold's back control when set.
    public func push(title: String? = nil, @ViewBuilder _ view: () -> some View) {
        stack.append(Entry(title: title, view: AnyView(view())))
    }

    /// Pop one level; false when already at the root.
    @discardableResult
    public func pop() -> Bool { stack.popLast() != nil }

    public func popToRoot() { stack.removeAll() }

    /// True while a pushed view sits above the root.
    public var canPop: Bool { !stack.isEmpty }

    /// The title to show for the level under the top one, i.e. where a back step lands.
    var backTitle: String? {
        guard canPop else { return nil }
        return stack.count >= 2 ? stack[stack.count - 2].title : nil
    }
}

// MARK: - Command palette

/// One row of a surface's ⌘K command palette. `shortcut` is a display hint only — the palette
/// itself is opened with ⌘K and driven with the arrows and Return.
public struct PluginCommand: Identifiable {
    public let id: String
    public var title: String
    public var subtitle: String?
    public var icon: PluginIcon
    public var shortcut: String?
    public var action: @MainActor () -> Void

    public init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        icon: PluginIcon = .symbol("bolt"),
        shortcut: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.shortcut = shortcut
        self.action = action
    }
}

// MARK: - Scaffold

/// The frame every native plugin surface should wrap its content in. It gives three things the host
/// used to owe a surface and no longer does: a view stack whose back step is Escape, a ⌘K command
/// palette pinned bottom-right whose rows the plugin supplies, and a footer that states both. It
/// claims those keys through a local monitor, so they reach the surface whatever holds focus.
///
/// Escape pops the stack; at the root it falls through to the host, which leaves the plugin. ⌘K
/// toggles the palette; while it is open the arrows and Return drive it and Escape closes it.
@MainActor
public struct PluginScaffold<Root: View>: View {
    private let navigator: PluginNavigator
    private let primaryLabel: String
    private let commands: () -> [PluginCommand]
    private let listKey: (PluginListKey) -> Bool
    private let commandTitle: () -> String?
    private let root: Root

    @State private var paletteOpen = false
    @State private var selection = 0
    @State private var monitor = KeyMonitor()

    /// - Parameters:
    ///   - navigator: the surface's view stack; make one `@State` in your surface and pass it here.
    ///   - primaryActionLabel: what Return does on the current view, shown in the footer (e.g. "Open").
    ///   - commands: the ⌘K rows for whatever view is on top; re-read every time the palette opens.
    ///   - commandTitle: the heading atop the ⌘K palette — what the commands act on, e.g. a ticker.
    ///   - listKey: ↑/↓/Return for a list on the current view, driven by the scaffold's own monitor
    ///     so it never depends on which control holds focus. Return true when you consumed the key.
    public init(
        navigator: PluginNavigator,
        primaryActionLabel: String = "",
        commands: @escaping () -> [PluginCommand] = { [] },
        commandTitle: @escaping () -> String? = { nil },
        listKey: @escaping (PluginListKey) -> Bool = { _ in false },
        @ViewBuilder root: () -> Root
    ) {
        self.navigator = navigator
        self.primaryLabel = primaryActionLabel
        self.commands = commands
        self.commandTitle = commandTitle
        self.listKey = listKey
        self.root = root()
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            VStack(spacing: 0) {
                stackedViews
                footer
            }
            if paletteOpen {
                CommandPaletteView(
                    header: commandTitle(), commands: currentCommands, selection: $selection, run: run)
                    .padding(.trailing, 12)
                    .padding(.bottom, 44)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { monitor.start(handler: handleKey) }
        .onDisappear { monitor.stop() }
    }

    private var stackedViews: some View {
        ZStack {
            root
                .opacity(navigator.canPop ? 0 : 1)
                .allowsHitTesting(!navigator.canPop)
            ForEach(navigator.stack) { entry in
                let isTop = entry.id == navigator.stack.last?.id
                entry.view
                    .opacity(isTop ? 1 : 0)
                    .allowsHitTesting(isTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if navigator.canPop {
                Label("Back", systemImage: "chevron.left")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                KeyCap(text: "esc")
            }
            Spacer(minLength: 0)
            if !primaryLabel.isEmpty {
                Text(primaryLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                KeyCap(text: "↩")
            }
            if !currentCommands.isEmpty {
                if !primaryLabel.isEmpty {
                    Rectangle().fill(.secondary.opacity(0.25)).frame(width: 1, height: 14)
                }
                Button {
                    paletteOpen.toggle()
                    selection = 0
                } label: {
                    HStack(spacing: 6) {
                        Text("Actions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        KeyCap(text: "⌘").padding(.trailing, -3)
                        KeyCap(text: "K")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .background(.thinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(.secondary.opacity(0.18)).frame(height: 1) }
    }

    private var currentCommands: [PluginCommand] { commands() }

    private func run(_ index: Int) {
        let rows = currentCommands
        guard rows.indices.contains(index) else { return }
        paletteOpen = false
        rows[index].action()
    }

    /// Returns true to swallow the key, false to let the host see it.
    private func handleKey(_ chord: KeyChord) -> Bool {
        guard NSApp.keyWindow != nil else { return false }

        if chord.command, chord.chars == "k" {
            guard !currentCommands.isEmpty else { return false }
            paletteOpen.toggle()
            selection = 0
            return true
        }

        if paletteOpen {
            switch chord.keyCode {
            case 53: paletteOpen = false
            case 125: selection = min(selection + 1, max(currentCommands.count - 1, 0))
            case 126: selection = max(selection - 1, 0)
            case 36, 76: run(selection)
            default: break
            }
            return true
        }

        if chord.bare {
            switch chord.keyCode {
            case 125: if listKey(.down) { return true }
            case 126: if listKey(.up) { return true }
            case 36, 76: if listKey(.submit) { return true }
            case 53: return navigator.pop()
            default: break
            }
        }
        return false
    }
}

/// A list key the scaffold routes to the current view through its own monitor, so a plugin's list
/// navigates whatever holds focus — the search field, or nothing at all.
public enum PluginListKey: Sendable {
    case up
    case down
    case submit
}

/// The Sendable slice of a key event the scaffold's monitor hands to the main actor: an `NSEvent`
/// itself is not Sendable, so only these primitives cross the hop.
private struct KeyChord: Sendable {
    let keyCode: UInt16
    let command: Bool
    let bare: Bool
    let chars: String?
}

/// Holds a local key monitor for a scaffold's lifetime; a class so `@State` can own it across the
/// view's value-type redraws and tear it down on disappear.
@MainActor
private final class KeyMonitor {
    private var token: Any?

    func start(handler: @escaping @MainActor (KeyChord) -> Bool) {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let chord = KeyChord(
                keyCode: event.keyCode,
                command: mods == .command,
                bare: mods.isEmpty,
                chars: event.charactersIgnoringModifiers?.lowercased())
            return MainActor.assumeIsolated { handler(chord) } ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    isolated deinit { if let token { NSEvent.removeMonitor(token) } }
}

/// The ⌘K palette: a titled panel in the shape of an extension's actions menu — a subtle
/// selection wash, hierarchical glyphs and outline keycaps, never a bright accent fill.
@MainActor
private struct CommandPaletteView: View {
    let header: String?
    let commands: [PluginCommand]
    @Binding var selection: Int
    let run: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let header, !header.isEmpty {
                Text(header)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
            }
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                row(command, selected: index == selection)
                    .onTapGesture { run(index) }
            }
        }
        .padding(6)
        .frame(width: 300)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private func row(_ command: PluginCommand, selected: Bool) -> some View {
        HStack(spacing: 8) {
            glyph(command.icon).frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title).font(.body).lineLimit(1)
                if let subtitle = command.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                HStack(spacing: 2) {
                    ForEach(Array(shortcut.enumerated()), id: \.offset) { _, ch in
                        KeyCap(text: String(ch), outline: true)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Color.primary.opacity(0.10) : .clear))
    }

    @ViewBuilder
    private func glyph(_ icon: PluginIcon) -> some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name).font(.body)
                .symbolRenderingMode(.hierarchical).foregroundStyle(.secondary)
        case .file(let url):
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
        }
    }
}

/// A keycap chip: `.outline` for a row's shortcut hint, filled for the footer's own keys — the
/// same two faces `KeyCapChip` wears in the host, restated here because chrome never crosses over.
private struct KeyCap: View {
    let text: String
    var outline: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, 4)
            .background {
                let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
                if outline {
                    shape.strokeBorder(.primary.opacity(0.20), lineWidth: 1)
                } else {
                    shape.fill(.primary.opacity(0.08))
                }
            }
    }
}
