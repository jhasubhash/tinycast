import AppKit
import SwiftUI
import TinycastPluginKit

/// One row of a pop-out window's ⌘K command palette — the window's own controls, not the plugin's.
struct PluginWindowCommand: Identifiable {
    let id = UUID()
    let title: String
    let systemImage: String
    var isDestructive = false
    /// The letter of its ⌘-shortcut (e.g. "w"), shown as a keycap and run from the panel.
    var shortcut: String?
    let action: () -> Void
}

/// The ⌘K palette state for one pop-out window; `@Observable` so the panel's key handling and the
/// SwiftUI overlay stay in step.
@MainActor
@Observable
final class PluginWindowMenu {
    var open = false
    var query = ""
    var selection = 0

    func reset() {
        query = ""
        selection = 0
    }
}

/// A single ordinary character, versus a control or arrow key, so only real text filters the palette.
private func isTypableText(_ text: String) -> Bool {
    guard text.count == 1, let scalar = text.unicodeScalars.first else { return false }
    return scalar.value >= 0x20 && scalar.value != 0x7F && scalar.value < 0xF700
}

/// The palette's rows once the user starts typing: a case-insensitive title match, else everything.
private func visibleCommands(_ all: [PluginWindowCommand], _ query: String) -> [PluginWindowCommand] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return all }
    return all.filter { $0.title.lowercased().contains(needle) }
}

/// A borderless, non-activating floating panel that hosts one plugin's SwiftUI view. It carries no
/// palette header, footer or drag strip — the only host chrome is a ⌘K command palette pinned
/// bottom-right, in the app's own actions-menu shape, for the window's controls. The user moves it by
/// dragging its background, resizes it from any edge, and opens the menu with ⌘K. Multiple can float
/// at once, so a stock plugin can show an ADBE chart and an MSFT chart side by side, and the launcher
/// still opens over them.
final class PluginWindowPanel: NSPanel {
    /// The plugin route this window shows, so the controller can find and drop it on close.
    var identityKey: String?
    /// The window's own ⌘K palette; key handling below drives it, scoped to this panel.
    var commandMenu: PluginWindowMenu?
    var commandsProvider: (() -> [PluginWindowCommand])?

    init(content: NSView, size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        // A plain window by default: it sits among normal windows on its own space, so other apps
        // can cover it — "keep in front" and "show on all spaces" are opt-in, via the menu.
        isFloatingPanel = false
        level = .normal
        // Stay put when the launcher, or anything else, takes focus.
        hidesOnDeactivate = false
        // Open on the space the launcher is showing on, and never switch spaces to reveal it:
        // `.moveToActiveSpace` brings it to the current space instead. It then stays on that space
        // (switching spaces manually leaves it behind); "Show on all spaces" swaps in
        // `.canJoinAllSpaces`. `.fullScreenAuxiliary` lets it appear if summoned over a full-screen app.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Borderless has no title bar to grab, so the whole background is the drag handle.
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isRestorable = false
        contentView = content
        contentMinSize = CGSize(width: 360, height: 360)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// ⌘K toggles the command palette; a command's own ⌘-shortcut (⌘W / ⌘S / ⌘P) runs it. All are
    /// scoped to the key window, so they never leak between several open pop-outs.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.isARepeat,
            event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        if key == "k", let commandMenu {
            commandMenu.open.toggle()
            if commandMenu.open { commandMenu.reset() }
            return true
        }
        if let command = commandsProvider?().first(where: { $0.shortcut == key }) {
            commandMenu?.open = false
            command.action()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// While the palette is open it owns the keyboard — arrows, Return, Escape and typing drive it
    /// rather than reaching the plugin, exactly as the app's own ⌘K menus behave.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let commandMenu, commandMenu.open, handleMenuKey(event) { return }
        super.sendEvent(event)
    }

    private func handleMenuKey(_ event: NSEvent) -> Bool {
        guard let commandMenu, let provider = commandsProvider else { return false }
        let visible = visibleCommands(provider(), commandMenu.query)
        switch Int(event.keyCode) {
        case 53:  // esc
            commandMenu.open = false
        case 125:  // down
            commandMenu.selection = min(commandMenu.selection + 1, max(visible.count - 1, 0))
        case 126:  // up
            commandMenu.selection = max(commandMenu.selection - 1, 0)
        case 36, 76:  // return / keypad enter
            if visible.indices.contains(commandMenu.selection) {
                commandMenu.open = false
                visible[commandMenu.selection].action()
            }
        case 51:  // delete
            if !commandMenu.query.isEmpty {
                commandMenu.query.removeLast()
                commandMenu.selection = 0
            }
        default:
            if let text = event.characters, isTypableText(text) {
                commandMenu.query.append(text)
                commandMenu.selection = 0
            }
        }
        return true
    }
}

/// Owns the set of open plugin pop-out windows, keyed by the plugin route so the same view never
/// opens twice — a second Pop Out of a window already up just raises it. Each window loads its own
/// plugin instance, so its state is independent of the palette's running session and of every other
/// window.
@MainActor
final class PluginWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var windows: [String: Entry] = [:]

    /// A plugin instance is retained for its window's life: the hosted view holds closures into it.
    private final class Entry {
        let panel: PluginWindowPanel
        let plugin: any TinycastPlugin
        init(panel: PluginWindowPanel, plugin: any TinycastPlugin) {
            self.panel = panel
            self.plugin = plugin
        }
    }

    init(core: AppCore) {
        self.core = core
    }

    /// Opens `install`'s current view as a standalone window, restoring it through `route`. A window
    /// already showing this exact route is raised instead of duplicated.
    func open(install: PluginInstall, route: PluginRoute) {
        let key = PluginRouteURL.encode(identifier: install.manifest.identifier, payload: route.payload)
        if let existing = windows[key] {
            existing.panel.makeKeyAndOrderFront(nil)
            existing.panel.orderFrontRegardless()
            return
        }

        let plugin: any TinycastPlugin
        do {
            plugin = try PluginLoader.load(install)
        } catch {
            core.showMessage("Couldn't open \(install.manifest.name) in a window", tone: .danger)
            return
        }

        let context = PluginContext(
            frontmostAppBundleID: core.paletteCoordinator.targetApp?.bundleIdentifier,
            route: route.payload,
            presentation: .window)
        guard let view = plugin.rootSurface(context: context) else {
            core.showMessage("\(install.manifest.name) has no window view", tone: .danger)
            return
        }

        let menu = PluginWindowMenu()
        let chrome = PluginWindowChrome(menu: menu, commands: { [weak self] in
            self?.windowCommands(key: key) ?? []
        }) {
            // Only Escape is bridged: a windowed surface owns none of the palette's other host hooks.
            view.environment(\.pluginExit) { [weak self] in self?.close(key: key) }
        }
        // The launcher's own environment, so the backdrop tracks the app's theme and transparency.
        let content = NSHostingView(
            rootView: chrome
                .environment(core.settings)
                .environment(\.metrics, core.settings.interfaceSize.metrics))
        content.sizingOptions = []

        // Opens at the size the surface fills inside the launcher; the user resizes from there.
        let size = defaultSize()
        let panel = PluginWindowPanel(content: content, size: size)
        panel.identityKey = key
        panel.commandMenu = menu
        panel.commandsProvider = { [weak self] in self?.windowCommands(key: key) ?? [] }
        panel.delegate = self
        panel.setFrameAutosaveName(Self.autosaveName(for: key))
        if !panel.setFrameUsingName(Self.autosaveName(for: key)) { positionOnCursorScreen(panel, size: size) }

        windows[key] = Entry(panel: panel, plugin: plugin)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close(key: String) {
        guard let entry = windows.removeValue(forKey: key) else { return }
        entry.panel.orderOut(nil)
        entry.panel.close()
    }

    func closeAll() {
        for key in Array(windows.keys) { close(key: key) }
    }

    // MARK: - The window's ⌘K commands

    /// Re-read every time the palette opens, so each row's label reflects the live window state.
    private func windowCommands(key: String) -> [PluginWindowCommand] {
        guard let panel = windows[key]?.panel else { return [] }
        let allSpaces = panel.collectionBehavior.contains(.canJoinAllSpaces)
        let inFront = panel.level == .floating
        return [
            PluginWindowCommand(
                title: allSpaces ? "Show on This Space Only" : "Show on All Spaces",
                systemImage: allSpaces ? "square.on.square.dashed" : "square.on.square",
                shortcut: "s",
                action: { [weak self] in self?.setShowsOnAllSpaces(!allSpaces, key: key) }),
            PluginWindowCommand(
                title: inFront ? "Don't Keep in Front" : "Keep in Front of Other Apps",
                systemImage: inFront ? "pin.slash" : "pin",
                shortcut: "p",
                action: { [weak self] in self?.setKeepsInFront(!inFront, key: key) }),
            PluginWindowCommand(
                title: "Close Window", systemImage: "xmark", isDestructive: true,
                shortcut: "w",
                action: { [weak self] in self?.close(key: key) }),
        ]
    }

    private func setShowsOnAllSpaces(_ on: Bool, key: String) {
        guard let panel = windows[key]?.panel else { return }
        if on {
            panel.collectionBehavior.remove(.moveToActiveSpace)
            panel.collectionBehavior.insert(.canJoinAllSpaces)
        } else {
            panel.collectionBehavior.remove(.canJoinAllSpaces)
            panel.collectionBehavior.insert(.moveToActiveSpace)
        }
    }

    private func setKeepsInFront(_ on: Bool, key: String) {
        windows[key]?.panel.level = on ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    /// The red button, ⌘W and a programmatic close all land here; drop the entry so it can reopen.
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? PluginWindowPanel, let key = panel.identityKey
        else { return }
        windows.removeValue(forKey: key)
    }

    // MARK: - Private

    /// The size the plugin surface fills inside the launcher, so a pop-out opens matching it.
    private func defaultSize() -> CGSize {
        let size = core.settings.interfaceSize.metrics.size
        return CGSize(width: size.panelWidth, height: size.panelHeight)
    }

    private func positionOnCursorScreen(_ panel: NSPanel, size: CGSize) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return panel.center() }
        let origin = CGPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    /// A defaults-safe autosave key: AppKit stores the frame under "NSWindow Frame <name>".
    private static func autosaveName(for key: String) -> String {
        let slug = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "TinycastPluginWindow-" + String(slug)
    }
}

/// The pop-out's window chrome: the same dark scrim-over-blur backdrop the palette draws, so a
/// transparent plugin surface reads identically here, plus a ⌘K command palette pinned bottom-right
/// in the app's actions-menu shape. No header, footer or toolbar — the plugin owns the rest.
private struct PluginWindowChrome<Content: View>: View {
    private let menu: PluginWindowMenu
    private let commands: () -> [PluginWindowCommand]
    private let content: Content

    @Environment(AppSettings.self) private var settings
    @Environment(\.metrics) private var metrics
    @State private var hovering = false

    init(
        menu: PluginWindowMenu,
        commands: @escaping () -> [PluginWindowCommand],
        @ViewBuilder content: () -> Content
    ) {
        self.menu = menu
        self.commands = commands
        self.content = content()
    }

    var body: some View {
        content
            .background {
                Theme.Colors.panelScrim(transparency: settings.paletteTransparency)
                    .background(VisualEffectView())
            }
            .clipShape(RoundedRectangle(cornerRadius: metrics.radius.panel, style: .continuous))
            // A click anywhere off the palette closes it, as the app's own ⌘K menus do. Sits below
            // the pill and the palette overlays (added after), so their own clicks still register.
            .overlay {
                if menu.open {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in menu.open = false })
                        .onRightClick { menu.open = false }
                }
            }
            .overlay(alignment: .bottomTrailing) { actionsButton }
            .overlay(alignment: .bottomTrailing) {
                if menu.open {
                    PluginWindowPalette(menu: menu, commands: commands())
                        .padding(.trailing, 12)
                        .padding(.bottom, 56)
                        .transition(.opacity)
                }
            }
            .onHover { hovering = $0 }
    }

    /// The "Actions ⌘K" pill, the app's own footer convention — hover-revealed so it never sits on
    /// the plugin's content, and a mouse route to the same palette ⌘K opens.
    private var actionsButton: some View {
        Button {
            menu.open.toggle()
            if menu.open { menu.reset() }
        } label: {
            HStack(spacing: 6) {
                Text("Actions").font(.callout.weight(.medium)).foregroundStyle(.secondary)
                WindowKeyCap(text: "⌘")
                WindowKeyCap(text: "K")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(12)
        .opacity(hovering || menu.open ? 1 : 0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
        .animation(.easeInOut(duration: 0.12), value: menu.open)
    }
}

/// The ⌘K palette itself, in the shape of the app's actions menu: a frosted rounded panel with a
/// search field, hierarchical row glyphs and a subtle selection wash — never a bright accent fill.
private struct PluginWindowPalette: View {
    let menu: PluginWindowMenu
    let commands: [PluginWindowCommand]

    private var visible: [PluginWindowCommand] { visibleCommands(commands, menu.query) }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            searchField
            if visible.isEmpty {
                Text("No matching actions")
                    .font(.callout).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 36)
            } else {
                ForEach(Array(visible.enumerated()), id: \.element.id) { index, command in
                    row(command, selected: index == menu.selection)
                        .onTapGesture {
                            menu.open = false
                            command.action()
                        }
                }
            }
        }
        .padding(6)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.primary.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            if menu.query.isEmpty {
                Text("Search actions…").foregroundStyle(.tertiary)
            } else {
                Text(menu.query).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
        }
        .font(.body).lineLimit(1)
        .padding(.horizontal, 8).frame(minHeight: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(.primary.opacity(0.08)).frame(height: 1) }
        .padding(.bottom, 2)
    }

    private func row(_ command: PluginWindowCommand, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: command.systemImage)
                .font(.body).symbolRenderingMode(.hierarchical)
                .foregroundStyle(command.isDestructive ? Color.red : .secondary)
                .frame(width: 20, height: 20)
            Text(command.title)
                .font(.body).lineLimit(1)
                .foregroundStyle(command.isDestructive ? Color.red : .primary)
            Spacer(minLength: 8)
            if let shortcut = command.shortcut {
                HStack(spacing: 2) {
                    WindowKeyCap(text: "⌘")
                    WindowKeyCap(text: shortcut.uppercased())
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
}

/// A small outlined keycap for the "Actions ⌘K" pill, matching the app's footer caps.
private struct WindowKeyCap: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            .frame(minWidth: 16, minHeight: 16).padding(.horizontal, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(.primary.opacity(0.20), lineWidth: 1))
    }
}
