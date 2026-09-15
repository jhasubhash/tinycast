import AppKit
import TinycastPluginKit

/// How a native plugin meets the palette: enabling it, launching one, and stepping back out.
/// The manager owns state; this owns the window moves, so the manager never touches a surface.
@MainActor
final class PluginCoordinator {
    private let plugins: PluginManager
    private let palette: PaletteState
    private let paletteCoordinator: PaletteCoordinator
    private let settingsCoordinator: SettingsCoordinator
    private let settings: AppSettings
    private unowned let core: AppCore

    init(
        plugins: PluginManager,
        palette: PaletteState,
        paletteCoordinator: PaletteCoordinator,
        settingsCoordinator: SettingsCoordinator,
        settings: AppSettings,
        core: AppCore
    ) {
        self.plugins = plugins
        self.palette = palette
        self.paletteCoordinator = paletteCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.settings = settings
        self.core = core

        plugins.onCloseRequested = { [weak self] in
            self?.paletteCoordinator.hidePalette(restoreFocus: false)
        }
        plugins.onMessage = { [weak self] message in self?.core.showMessage(message) }
        plugins.onDidPush = { [weak self] in
            self?.palette.query = ""
            self?.palette.selection = 0
        }
    }

    // MARK: - Feature presence

    /// Applies both switches as they stand — on launch, and after a backup import moves them.
    func applyEnabled() {
        plugins.setShowsInLauncher(settings.pluginsShowInLauncher)
        plugins.setEnabled(settings.pluginsEnabled)
    }

    func applyPluginsLauncherPresence() {
        plugins.setShowsInLauncher(settings.pluginsShowInLauncher)
    }

    /// Native code runs in-process with full privileges, so consent is asked before it can load.
    func setPluginsEnabled(_ enabled: Bool) {
        guard enabled != settings.pluginsEnabled else { return }
        guard enabled else {
            settings.pluginsEnabled = false
            plugins.setEnabled(false)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Enable plugins?",
                    message:
                        "Plugins are native code that runs inside Tinycast with the same access to "
                        + "this Mac that Tinycast itself has. Only enable plugins whose source you "
                        + "trust — a plugin is not sandboxed.",
                    symbol: "puzzlepiece.extension", confirmTitle: "Enable", tone: .neutral,
                    confirmRole: .standard)
            else { return }
            settings.pluginsEnabled = true
            plugins.setEnabled(true)
        }
    }

    // MARK: - Running one plugin

    /// Resolved from the installed set: a shortcut can fire before the launcher ever opened.
    func runPluginCommand(entryID: String) {
        guard settings.pluginsEnabled, let install = plugins.install(forEntryID: entryID) else {
            return
        }
        runPlugin(install)
    }

    func launch(_ app: AppEntry) {
        guard let install = plugins.install(forEntryID: app.id) else { return }
        runPlugin(install)
    }

    private func runPlugin(_ install: PluginInstall, route: [String: String]? = nil) {
        let environment = PluginEnvironment(
            frontmostAppBundleID: paletteCoordinator.targetApp?.bundleIdentifier)
        // Switch the palette over first, so the loading state is what the user sees.
        paletteCoordinator.navigate(to: .plugin)
        // A shortcut fires while hidden, where the plugin has nowhere to render.
        if !paletteCoordinator.isVisible {
            paletteCoordinator.showPalette(mode: .plugin)
        }
        plugins.launch(install, environment: environment, route: route)
    }

    /// Open a plugin straight to a saved deep link — a `tinycast://plugin/…` quicklink resolved here.
    func launchRoute(identifier: String, payload: [String: String]) {
        guard settings.pluginsEnabled, let install = plugins.install(forIdentifier: identifier)
        else { return }
        runPlugin(install, route: payload)
    }

    private func routeLink(for route: PluginRoute) -> String? {
        guard let identifier = plugins.runningIdentifier else { return nil }
        return PluginRouteURL.encode(identifier: identifier, payload: route.payload)
    }

    /// Whether the running view is already on the launcher — matched by route link, not name, so a
    /// renamed pin still resolves.
    func isRoutePinned(_ route: PluginRoute) -> Bool {
        guard let link = routeLink(for: route) else { return false }
        return core.quicklinks.quicklinks.contains { $0.link == link }
    }

    /// The scaffold's Add/Remove command: pin the current view as a Quicklink, or remove every
    /// Quicklink that points at it (name-independent, so dupes and renames both resolve).
    func toggleRoutePin(_ route: PluginRoute) {
        guard let link = routeLink(for: route) else { return }
        let existing = core.quicklinks.quicklinks.filter { $0.link == link }
        guard !existing.isEmpty else { return pin(route, link: link) }
        let name = existing.first?.name ?? route.title
        for quicklink in existing {
            Task { await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id, confirming: false) }
        }
        core.showMessage("Removed “\(name)” from the launcher")
    }

    private func pin(_ route: PluginRoute, link: String) {
        let iconSymbol: String? = {
            if case .symbol(let name) = route.icon { return name } else { return nil }
        }()
        do {
            _ = try core.quicklinks.add(
                Quicklink(name: route.title, link: link, iconSymbol: iconSymbol))
            core.showMessage("Added “\(route.title)” to the launcher")
        } catch {
            core.showMessage("Couldn't add to the launcher", tone: .danger)
        }
    }

    /// The scaffold's "Copy Deep Link" command: put the current view's `tinycast://…` link on the
    /// pasteboard.
    func copyRouteLink(_ route: PluginRoute) {
        guard let link = routeLink(for: route) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        core.showMessage("Copied deep link")
    }

    /// The scaffold's "Pop Out" command: open the current view as its own standalone window and
    /// leave the palette, so the plugin keeps running on screen without the launcher over it.
    func popOut(_ route: PluginRoute) {
        guard let identifier = plugins.runningIdentifier,
            let install = plugins.install(forIdentifier: identifier)
        else { return }
        core.pluginWindowController.open(install: install, route: route)
        exitPluginScreen()
    }

    /// Escape past an empty search field: pop the plugin's own stack, then leave the plugin.
    func exitPluginScreen() {
        if plugins.back() {
            palette.query = ""
            palette.selection = 0
            return
        }
        plugins.stop()
        if !palette.pop() { paletteCoordinator.hidePalette() }
    }

    var canGoBack: Bool { plugins.canGoBack }

    // MARK: - Managing one plugin from Settings

    func confirmUninstall(_ install: PluginInstall) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            guard
                await core.confirm(
                    title: "Uninstall \(install.manifest.name)?",
                    message: "Removes the plugin's folder; its commands and any pinned views leave the launcher.",
                    symbol: "trash", confirmTitle: "Uninstall")
            else { return }
            plugins.uninstall(install)
        }
    }

    /// What no index prunes: a shortcut or a rank keyed to a plugin that is now gone.
    func removePluginReferences(entryIDs: [String]) {
        for entryID in entryIDs {
            let action = HotKeyAction.pluginCommand(entryID: entryID)
            if core.hotKeys.recordingAction == action { core.hotKeys.recordingAction = nil }
            core.hotKeys.setBinding(nil, for: action)
            core.launcherRanking.reset(itemKey: entryID)
        }
        core.favorites.remove(keys: Set(entryIDs))
        core.visibility.removeItemKeys(Set(entryIDs))
        core.aliases.removeKeys(Set(entryIDs))
        // Pinned deep links are quicklinks keyed by the plugin's identifier, not its entry id, so
        // they outlive the entry-id prune above — remove them here or they become dead no-ops.
        let identifiers = Set(entryIDs.compactMap { PluginInstall.identifier(fromEntryID: $0) })
        let orphaned = core.quicklinks.quicklinks.filter { quicklink in
            guard let route = PluginRouteURL.decode(quicklink.link) else { return false }
            return identifiers.contains(route.identifier)
        }
        for quicklink in orphaned {
            Task { await core.quicklinkCoordinator.deleteQuicklink(id: quicklink.id, confirming: false) }
        }
    }
}

/// Encodes a plugin deep link as a `tinycast://plugin/<identifier>?<payload>` URL — stored as an
/// ordinary Quicklink, intercepted at open time and dispatched to the plugin, not the browser.
enum PluginRouteURL {
    private static let scheme = "tinycast"
    private static let host = "plugin"

    static func encode(identifier: String, payload: [String: String]) -> String {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + identifier
        if !payload.isEmpty {
            components.queryItems = payload.sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.string ?? "\(scheme)://\(host)/\(identifier)"
    }

    static func decode(_ link: String) -> (identifier: String, payload: [String: String])? {
        guard let components = URLComponents(string: link),
            components.scheme == scheme, components.host == host
        else { return nil }
        let identifier =
            components.path.hasPrefix("/") ? String(components.path.dropFirst()) : components.path
        guard !identifier.isEmpty else { return nil }
        var payload: [String: String] = [:]
        for item in components.queryItems ?? [] { payload[item.name] = item.value ?? "" }
        return (identifier, payload)
    }
}
