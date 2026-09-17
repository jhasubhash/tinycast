import AppKit
import SwiftUI
import TinycastPluginKit

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
        let panel: PopOutWindowPanel
        let plugin: any TinycastPlugin
        init(panel: PopOutWindowPanel, plugin: any TinycastPlugin) {
            self.panel = panel
            self.plugin = plugin
        }
    }

    /// Persisted so the pop-outs a user leaves open reappear on the next launch; each window's size
    /// and position ride the native per-window frame autosave. Kept in plain defaults, never a
    /// settings backup — window geometry is machine-local, like the palette's own position.
    private static let persistenceKey = "plugin.windows"
    private var didRestore = false

    private struct PersistedWindow: Codable {
        var route: String
        var allSpaces: Bool
        var keepInFront: Bool
    }

    init(core: AppCore) {
        self.core = core
    }

    /// Opens `install`'s current view as a standalone window, restoring it through `route`. A window
    /// already showing this exact route is raised instead of duplicated.
    func open(install: PluginInstall, route: PluginRoute, activating: Bool = true) {
        let key = PluginRouteURL.encode(identifier: install.manifest.identifier, payload: route.payload)
        if let existing = windows[key] {
            if activating { existing.panel.makeKeyAndOrderFront(nil) }
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

        let menu = PopOutWindowMenu()
        let chrome = PopOutWindowChrome(menu: menu, commands: { [weak self] in
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
        let panel = PopOutWindowPanel(content: content, size: size)
        panel.identityKey = key
        panel.commandMenu = menu
        panel.commandsProvider = { [weak self] in self?.windowCommands(key: key) ?? [] }
        panel.delegate = self
        panel.setFrameAutosaveName(Self.autosaveName(for: key))
        if !panel.setFrameUsingName(Self.autosaveName(for: key)) {
            positionPopOutWindow(panel, size: size)
        }

        windows[key] = Entry(panel: panel, plugin: plugin)
        if activating { panel.makeKeyAndOrderFront(nil) }
        panel.orderFrontRegardless()
        persist()
    }

    func close(key: String) {
        guard let entry = windows.removeValue(forKey: key) else { return }
        entry.panel.orderOut(nil)
        entry.panel.close()
        persist()
    }

    func closeAll() {
        for key in Array(windows.keys) { close(key: key) }
    }

    /// Reopen the pop-outs saved from last launch, once the plugin catalog has loaded. Frame autosave
    /// restores each window's size and position; the saved flags restore its space and level options.
    func restoreWindows() {
        guard !didRestore else { return }
        didRestore = true
        for saved in loadPersisted() {
            guard let route = PluginRouteURL.decode(saved.route),
                let install = core.plugins.install(forIdentifier: route.identifier)
            else { continue }
            open(install: install, route: PluginRoute(payload: route.payload, title: ""), activating: false)
            if saved.allSpaces { setShowsOnAllSpaces(true, key: saved.route) }
            if saved.keepInFront { setKeepsInFront(true, key: saved.route) }
        }
        persist()
    }

    private func persist() {
        let items = windows.map { key, entry in
            PersistedWindow(
                route: key,
                allSpaces: entry.panel.collectionBehavior.contains(.canJoinAllSpaces),
                keepInFront: entry.panel.level == .floating)
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.persistenceKey)
    }

    private func loadPersisted() -> [PersistedWindow] {
        guard let data = UserDefaults.standard.data(forKey: Self.persistenceKey),
            let items = try? JSONDecoder().decode([PersistedWindow].self, from: data)
        else { return [] }
        return items
    }

    // MARK: - The window's ⌘K commands

    /// Re-read every time the palette opens, so each row's label reflects the live window state.
    private func windowCommands(key: String) -> [PopOutWindowCommand] {
        guard let panel = windows[key]?.panel else { return [] }
        let allSpaces = panel.collectionBehavior.contains(.canJoinAllSpaces)
        let inFront = panel.level == .floating
        return [
            PopOutWindowCommand(
                title: allSpaces ? "Show on This Space Only" : "Show on All Spaces",
                systemImage: allSpaces ? "square.on.square.dashed" : "square.on.square",
                shortcut: "s",
                action: { [weak self] in self?.setShowsOnAllSpaces(!allSpaces, key: key) }),
            PopOutWindowCommand(
                title: inFront ? "Don't Keep in Front" : "Keep in Front of Other Apps",
                systemImage: inFront ? "pin.slash" : "pin",
                shortcut: "p",
                action: { [weak self] in self?.setKeepsInFront(!inFront, key: key) }),
            PopOutWindowCommand(
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
        persist()
    }

    private func setKeepsInFront(_ on: Bool, key: String) {
        windows[key]?.panel.level = on ? .floating : .normal
        persist()
    }

    // MARK: - NSWindowDelegate

    /// The red button, ⌘W and a programmatic close all land here; drop the entry so it can reopen.
    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? PopOutWindowPanel, let key = panel.identityKey
        else { return }
        windows.removeValue(forKey: key)
    }

    // MARK: - Private

    /// The size the plugin surface fills inside the launcher, so a pop-out opens matching it.
    private func defaultSize() -> CGSize {
        let size = core.settings.interfaceSize.metrics.size
        return CGSize(width: size.panelWidth, height: size.panelHeight)
    }

    /// A defaults-safe autosave key: AppKit stores the frame under "NSWindow Frame <name>".
    private static func autosaveName(for key: String) -> String {
        let slug = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "TinycastPluginWindow-" + String(slug)
    }
}
