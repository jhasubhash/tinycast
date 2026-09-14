import AppKit
import SwiftUI
import TinycastPluginKit

/// The world a plugin session is handed at launch; the manager rebuilds a `PluginContext` from it
/// on every query so the plugin never reaches for the frontmost app itself.
struct PluginEnvironment: Equatable {
    var frontmostAppBundleID: String?
    var finderSelection: [URL] = []
}

/// One level of a running plugin's own navigation. The root re-asks the plugin on every keystroke;
/// a pushed child list filters locally; a surface hands the whole palette body to the plugin.
enum PluginLevel {
    case root
    case children(parentID: String, rows: [PluginResult])
    case surface(id: String, view: AnyView)
}

/// What the plugin palette is showing for the running plugin.
enum PluginSessionState: Equatable {
    case idle
    case loading
    case active
    case failed(String)
}

/// Owns the installed set and the one running plugin session. The counterpart of `ExtensionManager`
/// for native, compiled plugins — far smaller, because a plugin renders itself.
@MainActor
@Observable
final class PluginManager {
    private(set) var installed: [PluginInstall] = []
    private(set) var state: PluginSessionState = .idle
    private(set) var metadata: PluginMetadata?
    /// The running plugin's navigation stack, innermost last. Empty when nothing runs.
    private(set) var levels: [PluginLevel] = []
    /// Bumped when the running plugin invalidates its rows, so `PluginScreen` re-asks `results`.
    private(set) var resultsRevision = 0

    private(set) var isEnabled = false
    private(set) var showsInLauncher = true

    /// Routed to the coordinator, which owns the window; the manager never touches the palette.
    @ObservationIgnored var onCloseRequested: (() -> Void)?
    @ObservationIgnored var onMessage: ((String) -> Void)?
    /// Fired when a level is pushed, so the coordinator can reset the search field and selection.
    @ObservationIgnored var onDidPush: (() -> Void)?
    /// The entry ids an uninstall invalidated, so another feature can drop what it keyed to them.
    @ObservationIgnored var onDidUninstall: (([String]) -> Void)?

    @ObservationIgnored private weak var appIndex: AppIndex?
    @ObservationIgnored private var loaded: (any TinycastPlugin)?
    @ObservationIgnored private var runningID: String?
    @ObservationIgnored private var environment = PluginEnvironment()
    @ObservationIgnored private var directoryWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var watcherGeneration = 0
    @ObservationIgnored private var rescanTask: Task<Void, Never>?

    func start(appIndex: AppIndex) {
        self.appIndex = appIndex
    }

    // MARK: - Switches

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        guard enabled else {
            stopWatching()
            stop()
            installed = []
            appIndex?.setPluginCommands([])
            return
        }
        refresh()
        armDirectoryWatcher()
    }

    // MARK: - Live install detection

    /// Watches the plugins folder so a plugin dropped in while Tinycast runs appears without a
    /// relaunch. Mirrors `SnippetsStore`'s directory watcher. Updating a *loaded* dylib still needs
    /// a restart — `dlopen` reference-counts and the old image stays mapped.
    private func armDirectoryWatcher() {
        directoryWatcher?.cancel()
        let descriptor = Darwin.open(PluginCatalog.pluginsDirectory().path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watcherGeneration &+= 1
        let generation = watcherGeneration
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.handleDirectoryChange(generation: generation) }
        }
        source.setCancelHandler { Darwin.close(descriptor) }
        directoryWatcher = source
        source.resume()
    }

    private func handleDirectoryChange(generation: Int) {
        guard isEnabled, generation == watcherGeneration else { return }
        let events = directoryWatcher?.data ?? []
        // The folder itself was replaced; re-arm against the fresh inode (scan recreates it).
        if !events.isDisjoint(with: [.delete, .rename, .revoke]) { armDirectoryWatcher() }
        // Debounced: a burst of file copies from one install collapses into a single rescan.
        rescanTask?.cancel()
        rescanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.isEnabled else { return }
            self.refresh()
        }
    }

    private func stopWatching() {
        watcherGeneration &+= 1
        rescanTask?.cancel()
        rescanTask = nil
        directoryWatcher?.cancel()
        directoryWatcher = nil
    }

    func setShowsInLauncher(_ shows: Bool) {
        guard shows != showsInLauncher else { return }
        showsInLauncher = shows
        publishLauncherEntries()
    }

    func refresh() {
        guard isEnabled else { return }
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { PluginCatalog.scan() }.value
            guard let self, found != self.installed else { return }
            self.installed = found
            self.publishLauncherEntries()
        }
    }

    // MARK: - Launcher rows

    private func publishLauncherEntries() {
        guard isEnabled, showsInLauncher else {
            appIndex?.setPluginCommands([])
            return
        }
        let entries = installed.map { install in
            AppEntry(
                id: install.entryID,
                name: install.manifest.name,
                url: install.directory,
                bundleID: nil,
                kind: .plugin,
                subtitle: install.manifest.subtitle,
                iconOverride: .symbol(install.manifest.icon ?? "puzzlepiece.extension"))
        }
        appIndex?.setPluginCommands(entries)
    }

    func install(forEntryID entryID: String) -> PluginInstall? {
        guard let identifier = PluginInstall.identifier(fromEntryID: entryID) else { return nil }
        return installed.first { $0.manifest.identifier == identifier }
    }

    /// The identifier of the plugin currently running, so its current view can be pinned.
    var runningIdentifier: String? {
        installed.first { $0.id == runningID }?.manifest.identifier
    }

    func install(forIdentifier identifier: String) -> PluginInstall? {
        installed.first { $0.manifest.identifier == identifier }
    }

    // MARK: - Session

    /// Loads the plugin and enters its root. Any previous session is torn down first, exactly as
    /// `ExtensionManager.run` does, so an orphaned surface never outlives the switch.
    func launch(_ install: PluginInstall, environment: PluginEnvironment, route: [String: String]? = nil) {
        stop()
        self.environment = environment
        state = .loading
        do {
            let plugin = try PluginLoader.load(install)
            loaded = plugin
            runningID = install.id
            metadata = type(of: plugin).metadata
            // A surface plugin opens straight into its screen; no root row list to step through.
            if let root = plugin.rootSurface(context: context(query: "", route: route)) {
                levels = [.surface(id: "__root__", view: root)]
            } else {
                levels = [.root]
            }
            plugin.bind { [weak self] in self?.reloadRows() }
            state = .active
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        loaded = nil
        runningID = nil
        metadata = nil
        levels = []
        state = .idle
    }

    /// Pops one of the plugin's own levels; false when already at the root.
    @discardableResult
    func back() -> Bool {
        guard levels.count > 1 else { return false }
        levels.removeLast()
        return true
    }

    var canGoBack: Bool { levels.count > 1 }

    /// The SwiftUI screen the plugin wants shown, or nil when the current level is a list.
    var surface: AnyView? {
        if case .surface(_, let view) = levels.last { return view }
        return nil
    }

    /// The plugin says its rows changed; a bump re-renders `PluginScreen`, which re-asks `rows`.
    func reloadRows() {
        resultsRevision &+= 1
    }

    /// The rows for the current level: the root re-asks the plugin, a child list filters its cache.
    func rows(query: String) -> [PluginResult] {
        _ = resultsRevision  // observe, so a plugin-driven reload re-asks results below
        guard let plugin = loaded, let level = levels.last else { return [] }
        switch level {
        case .root:
            return plugin.results(for: context(query: query))
        case .children(_, let rows):
            return Self.filter(rows, query: query)
        case .surface:
            return []
        }
    }

    func activate(_ result: PluginResult, query: String) {
        guard let plugin = loaded else { return }
        switch result.action {
        case .none:
            break
        case .openURL(let url):
            NSWorkspace.shared.open(url)
            onCloseRequested?()
        case .run(let id):
            Task { [weak self] in
                guard let self else { return }
                let outcome = await plugin.perform(resultID: id, context: self.context(query: query))
                if let message = outcome.message { self.onMessage?(message) }
                if outcome.closesLauncher { self.onCloseRequested?() }
            }
        case .children(let id):
            Task { [weak self] in
                guard let self else { return }
                let rows = await plugin.children(of: id, context: self.context(query: query))
                self.levels.append(.children(parentID: id, rows: rows))
                self.onDidPush?()
            }
        case .surface(let id):
            levels.append(.surface(id: id, view: plugin.surface(for: id, context: context(query: query))))
            onDidPush?()
        }
    }

    // MARK: - Uninstall

    func uninstall(_ install: PluginInstall) {
        if runningID == install.id { stop() }
        try? FileManager.default.removeItem(at: install.directory)
        onDidUninstall?([install.entryID])
        refresh()
    }

    // MARK: - Helpers

    private func context(query: String, route: [String: String]? = nil) -> PluginContext {
        PluginContext(
            query: query,
            frontmostAppBundleID: environment.frontmostAppBundleID,
            finderSelection: environment.finderSelection,
            route: route)
    }

    private static func filter(_ rows: [PluginResult], query: String) -> [PluginResult] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { row in
            row.title.lowercased().contains(needle)
                || (row.subtitle?.lowercased().contains(needle) ?? false)
                || row.keywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
