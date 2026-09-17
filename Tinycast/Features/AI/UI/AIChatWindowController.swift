import AppKit
import SwiftUI

/// Owns the set of AI Chat pop-out windows, one per scope - the default bar and each Assistant get
/// their own. Popping out a scope already on screen raises its window; a different scope opens a
/// second window beside it rather than replacing the first. Each window runs its own conversation
/// (`AIChatState`) and store, pinned to the scope it detached with, so it keeps showing that chat
/// and model even as the launcher switches assistants. Popping out leaves the palette (mirrors
/// `PluginWindowController`).
@MainActor
final class AIChatWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var windows: [String: Entry] = [:]

    /// A pop-out's conversation, store and coordinator live as long as its window: the hosted view
    /// holds closures into them, and the ⌘K commands read them by key.
    private final class Entry {
        let panel: PopOutWindowPanel
        let chat: AIChatState
        let history: ChatHistoryStore
        let coordinator: AIChatCoordinator
        init(
            panel: PopOutWindowPanel, chat: AIChatState, history: ChatHistoryStore,
            coordinator: AIChatCoordinator
        ) {
            self.panel = panel
            self.chat = chat
            self.history = history
            self.coordinator = coordinator
        }
    }

    /// Persisted so the pop-outs a user leaves open reappear on the next launch; each window's size
    /// and position ride the native per-window frame autosave. Kept in plain defaults, never a
    /// settings backup — window geometry is machine-local, like the palette's own position.
    private static let persistenceKey = "aiChat.windows"
    private var didRestore = false

    private struct PersistedWindow: Codable {
        /// The scope key: "default" for the bar, else the Assistant's UUID string.
        var scope: String
        var allSpaces: Bool
        var keepInFront: Bool
    }

    init(core: AppCore) {
        self.core = core
    }

    /// Detach `session` into a standalone window pinned to `scope`. A window already showing this
    /// scope adopts the new conversation and is raised; a new scope opens its own window.
    func popOut(scope: UUID?, session: ChatSession) {
        let key = Self.key(for: scope)
        if let existing = windows[key] {
            existing.coordinator.pin(to: scope, adopting: session)
            existing.panel.makeKeyAndOrderFront(nil)
            existing.panel.orderFrontRegardless()
            return
        }
        let entry = makeEntry(scope: scope, key: key)
        entry.coordinator.pin(to: scope, adopting: session)
        windows[key] = entry
        entry.panel.makeKeyAndOrderFront(nil)
        entry.panel.orderFrontRegardless()
        persist()
    }

    func close(key: String) {
        guard let entry = windows.removeValue(forKey: key) else { return }
        entry.chat.cancel()
        entry.panel.orderOut(nil)
        entry.panel.close()
        persist()
    }

    func closeAll() {
        for key in Array(windows.keys) { close(key: key) }
    }

    /// Reopen the pop-outs saved from last launch, once AI history has actually loaded. Each rebuilds
    /// its scope's most recent conversation; a saved Assistant that no longer exists is skipped.
    func restoreIfNeeded() {
        guard !didRestore else { return }
        didRestore = true
        for saved in loadPersisted() {
            let scope: UUID?
            if saved.scope == "default" {
                scope = nil
            } else if let id = UUID(uuidString: saved.scope),
                core.assistants.assistant(id: id) != nil {
                scope = id
            } else {
                continue
            }
            let entry = makeEntry(scope: scope, key: saved.scope)
            entry.coordinator.restore(to: scope)
            windows[saved.scope] = entry
            // Restore without stealing key: makeKey would activate Tinycast and pull focus at launch.
            entry.panel.orderFrontRegardless()
            if saved.allSpaces { setShowsOnAllSpaces(true, key: saved.scope) }
            if saved.keepInFront { setKeepsInFront(true, key: saved.scope) }
        }
        persist()
    }

    private func persist() {
        let items = windows.map { key, entry in
            PersistedWindow(
                scope: key,
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

    /// Builds a scope's window with its own conversation, store and pinned coordinator, ready to be
    /// tracked and ordered front by the caller.
    private func makeEntry(scope: UUID?, key: String) -> Entry {
        let history = ChatHistoryStore(directory: AppPaths.applicationSupport())
        let chat = AIChatState(history: history)
        let coordinator = AIChatCoordinator(
            chat: chat, history: history, scope: .pinned(scope), settings: core.settings,
            appIndex: core.appIndex, palette: core.palette,
            paletteCoordinator: core.paletteCoordinator,
            settingsCoordinator: core.settingsCoordinator, core: core)
        let menu = PopOutWindowMenu()
        let root = AIChatPopOutRoot(
            chat: chat, settings: core.aiSettings, coordinator: coordinator,
            menu: menu, commands: { [weak self] in self?.windowCommands(key: key) ?? [] })
        // The launcher's own environment, so the backdrop tracks the app's theme and transparency,
        // and its own model menu — reused as-is for this window's model switcher — resolves.
        let content = NSHostingView(
            rootView: root
                .environment(core.settings)
                .environment(core.palette)
                .environment(\.metrics, core.settings.interfaceSize.metrics))
        content.sizingOptions = []

        // Opens at the size chat fills inside the launcher; the user resizes from there.
        let size = defaultSize()
        let panel = PopOutWindowPanel(content: content, size: size)
        panel.identityKey = key
        panel.commandMenu = menu
        panel.commandsProvider = { [weak self] in self?.windowCommands(key: key) ?? [] }
        panel.delegate = self
        panel.setFrameAutosaveName(Self.autosaveName(for: key))
        if !panel.setFrameUsingName(Self.autosaveName(for: key)) { positionPopOutWindow(panel, size: size) }
        return Entry(panel: panel, chat: chat, history: history, coordinator: coordinator)
    }

    // MARK: - The window's ⌘K commands

    /// Re-read every time the palette opens, so each row's label reflects the live window and chat
    /// state. Only what stands on its own without the palette behind it: no Chat History, which
    /// browses by reopening the palette itself.
    private func windowCommands(key: String) -> [PopOutWindowCommand] {
        guard let entry = windows[key] else { return [] }
        let panel = entry.panel
        let allSpaces = panel.collectionBehavior.contains(.canJoinAllSpaces)
        let inFront = panel.level == .floating
        var items: [PopOutWindowCommand] = []
        if entry.chat.isStreaming {
            items.append(
                PopOutWindowCommand(
                    title: "Stop Response", systemImage: "stop.fill",
                    action: { [weak self] in self?.windows[key]?.coordinator.stopResponse() }))
        }
        items.append(
            PopOutWindowCommand(
                title: "New Chat", systemImage: "plus.bubble", shortcut: "n",
                action: { [weak self] in self?.windows[key]?.coordinator.startNewChat() }))
        if entry.chat.lastAssistantText != nil {
            items.append(
                PopOutWindowCommand(
                    title: "Copy Last Response", systemImage: "doc.on.doc",
                    action: { [weak self] in self?.windows[key]?.coordinator.copyLastResponse() }))
        }
        items.append(
            PopOutWindowCommand(
                title: "AI Settings", systemImage: "slider.horizontal.3",
                action: { [weak self] in self?.windows[key]?.coordinator.showSettings() }))
        items.append(
            PopOutWindowCommand(
                title: allSpaces ? "Show on This Space Only" : "Show on All Spaces",
                systemImage: allSpaces ? "square.on.square.dashed" : "square.on.square",
                shortcut: "s",
                action: { [weak self] in self?.setShowsOnAllSpaces(!allSpaces, key: key) }))
        items.append(
            PopOutWindowCommand(
                title: inFront ? "Don't Keep in Front" : "Keep in Front of Other Apps",
                systemImage: inFront ? "pin.slash" : "pin",
                shortcut: "p",
                action: { [weak self] in self?.setKeepsInFront(!inFront, key: key) }))
        items.append(
            PopOutWindowCommand(
                title: "Close Window", systemImage: "xmark", isDestructive: true, shortcut: "w",
                action: { [weak self] in self?.close(key: key) }))
        return items
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
        windows[key]?.chat.cancel()
        windows.removeValue(forKey: key)
        persist()
    }

    // MARK: - Private

    /// The size chat fills inside the launcher, so a pop-out opens matching it.
    private func defaultSize() -> CGSize {
        let size = core.settings.interfaceSize.metrics.size
        return CGSize(width: size.panelWidth, height: size.panelHeight)
    }

    private static func key(for scope: UUID?) -> String {
        scope?.uuidString ?? "default"
    }

    /// A defaults-safe autosave key: AppKit stores the frame under "NSWindow Frame <name>".
    private static func autosaveName(for key: String) -> String {
        let slug = key.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return "TinycastAIChatWindow-" + String(slug)
    }
}
