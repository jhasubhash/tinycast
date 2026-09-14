import AppKit

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

    private func runPlugin(_ install: PluginInstall) {
        let environment = PluginEnvironment(
            frontmostAppBundleID: paletteCoordinator.targetApp?.bundleIdentifier)
        // Switch the palette over first, so the loading state is what the user sees.
        paletteCoordinator.navigate(to: .plugin)
        // A shortcut fires while hidden, where the plugin has nowhere to render.
        if !paletteCoordinator.isVisible {
            paletteCoordinator.showPalette(mode: .plugin)
        }
        plugins.launch(install, environment: environment)
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
                    message: "Removes the plugin's folder and its commands leave the launcher.",
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
    }
}
