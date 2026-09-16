import AppKit
import Carbon.HIToolbox
import QuartzCore
import SwiftUI

@MainActor
final class PaletteWindowController: NSObject, NSWindowDelegate {
    private unowned let core: AppCore
    private var panel: PalettePanel?
    private(set) var previousApp: NSRunningApplication?
    /// Our key window at summon time, so hiding hands focus back to Settings, not a stale app.
    private weak var previousOwnWindow: NSWindow?
    private var popToRootTimer: Timer?
    // Reopen beat the timeout, so select the preserved query.
    private var queryWasPreserved = false
    /// Resolved once per show; the top edge is the one that must not drift.
    private var anchor: CGPoint?
    /// Live only between mouse-down and mouse-up on a drag handle; nil means a move was ours.
    private var drag: DragSession?
    private let dropGuides = PaletteDropGuideController()
    /// ⌘V: `Edit ▸ Paste` claims it before `sendEvent` whenever the board also carries text.
    private var pasteMonitor: Any?
    /// ⌘⎋: the window server claims it, so no keystroke is left for the responder chain to see.
    private lazy var commandEscapeTap = CommandEscapeTap { [weak self] in
        guard let self, self.panel?.isKeyWindow == true else { return false }
        self.core.palette.prepare(mode: .launcher)
        return true
    }

    /// What a drag in flight needs: where home is, and whether releasing now would land there.
    private struct DragSession {
        var home: CGPoint
        var screenFrame: CGRect
        var visibleFrame: CGRect
        var displayKey: String
        var armed = false
        /// The guides wait for this, so a click that never moves the panel doesn't flash them.
        var moved = false
    }

    init(core: AppCore) {
        self.core = core
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// What the palette covered when it was summoned, for anything it expands into on dismissal.
    var previousTarget: InjectionTarget? {
        InjectionTarget.behindPalette(ownWindow: previousOwnWindow, app: previousApp)
    }

    func show() {
        Signposts.interval("PaletteWindowController.show") {
            // Summoned over one of our own windows: there is no external paste or focus target.
            let frontmost = NSWorkspace.shared.frontmostApplication
            if frontmost?.processIdentifier == NSRunningApplication.current.processIdentifier {
                previousApp = nil
                // Never the palette itself: a mode switch re-shows it while it already holds key.
                if let key = NSApp.keyWindow, key !== panel { previousOwnWindow = key }
            } else {
                previousApp = frontmost
                previousOwnWindow = nil
            }
            // Once per summon, and from `previousApp`, so the label names the paste target.
            core.palette.pasteTarget = PasteTarget(app: previousApp)
            let panel = ensurePanel()
            // Open disarmed: a pointer already over a row must not highlight it.
            core.palette.disarmHoverHighlight(pointerAt: NSEvent.mouseLocation)
            // Re-resolve the anchor now, then hold it so resizes never move the window.
            anchor = nil
            // Size and place before ordering front, so a compact summon never flashes.
            positionPanel(panel, collapsed: core.paletteCoordinator.paletteIsCollapsed)
            // Flush first-mount layout off-screen, so the safe-area settle isn't visible.
            panel.contentView?.layoutSubtreeIfNeeded()
            core.inputSourceSwitcher.beginSession(
                preferredInputSourceID: core.settings.autoSwitchInputSourceID)
            // Events go stale while the palette is closed, and the countdown only ticks while up.
            core.calendarCoordinator.paletteDidShow()
            core.palette.noteVisible(true)
            core.clipboardStore.setTextSearchActive(true)
            // Only while we are on screen: a system-wide tap has no business outliving the window.
            commandEscapeTap.enable()
            // Non-activating, so summoning never raises our own aux windows behind it.
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            // A never-activated login item can drop the first key request, so re-assert.
            DispatchQueue.main.async { [weak panel] in
                guard let panel, panel.isVisible, !panel.isKeyWindow else { return }
                panel.makeKeyAndOrderFront(nil)
            }
        }
    }

    // Isolated so teardown may touch the main-actor monitor; the block is already weak.
    isolated deinit {
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
    }

    /// The character a bare-⌘ chord names, through the ASCII layout so an IME cannot move it.
    private static func commandCharacter(from event: NSEvent) -> String? {
        guard !event.isARepeat,
            event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
        else { return nil }
        return ASCIIKeyboardLayout.character(for: event)?.lowercased()
            ?? event.charactersIgnoringModifiers?.lowercased()
    }

    /// Shift is allowed, since ⌘+ is a shifted = on most layouts; the base key decides.
    private static func emojiGridZoom(from event: NSEvent) -> EmojiGridZoom? {
        guard !event.isARepeat, event.modifierFlags.isDisjoint(with: [.option, .control]) else {
            return nil
        }
        switch ASCIIKeyboardLayout.character(for: event) {
        case "0": return .actualSize
        case "=", "+": return .zoomIn
        case "-": return .zoomOut
        default: return nil
        }
    }

    /// A local monitor sees the key before menu dispatch; returning nil swallows it.
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self, self.panel?.isKeyWindow == true,
                Self.commandCharacter(from: event) == "v"
            else { return event }
            return self.attachPastedFile() ? nil : event
        }
    }

    /// Read once here: ⌘V is a keystroke path, and both routes want the same answer.
    private func attachPastedFile() -> Bool {
        let files = PasteboardFiles.urls(on: .general)
        switch core.palette.mode {
        case .ai: return core.aiChatCoordinator.attachPastedFile(files: files)
        case .launcher: return core.aiChatCoordinator.attachPastedFileFromLauncher(files: files)
        default: return false
        }
    }

    func hide(restoreFocus: Bool) {
        panel?.orderOut(nil)
        commandEscapeTap.disable()
        core.inputSourceSwitcher.endSession()
        core.calendarCoordinator.paletteDidHide()
        core.palette.noteVisible(false)
        core.clipboardStore.setTextSearchActive(false)
        // Drop the anchor, so the next summon re-resolves for the screen in use then.
        anchor = nil
        // The guides must never outlive the panel they point at.
        drag = nil
        dropGuides.hide()
        // Drop the multi-MB preview bitmaps, so idle RAM returns near baseline.
        ImageThumbnail.purgePreviews()
        FilePreviewThumbnail.purgePreviews()
        IconCache.purgeFitted()
        schedulePopToRoot()
        guard restoreFocus else { return }
        // Our own window first: it is still open, and activating another app would bury it.
        if let own = previousOwnWindow, own.isVisible {
            own.makeKeyAndOrderFront(nil)
        } else {
            previousApp?.activate()
        }
    }

    /// Pop to Root Search: reset now, or after the delay unless a reopen consumes it.
    private func schedulePopToRoot() {
        // Don't pop to root if an extension is waiting for OAuth authorization in the browser.
        guard !core.extensions.isAuthorizing else { return }
        popToRootTimer?.invalidate()
        let timeout = core.settings.popToRootTimeout
        guard timeout != .immediately else {
            popToRoot()
            return
        }
        popToRootTimer = Timer.scheduledTimer(withTimeInterval: timeout.interval, repeats: false) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.core.extensions.isAuthorizing else { return }
                self.popToRootTimer = nil
                self.popToRoot()
            }
        }
    }

    /// The screen only: a conversation is not a typed query, and `Opens To` decides its lifetime.
    private func popToRoot() {
        core.palette.prepare(mode: .launcher)
    }

    /// Skip the Pop to Root Search delay, for a close that means to reset as well as hide.
    func popToRootNow() {
        guard !core.extensions.isAuthorizing else { return }
        popToRootTimer?.invalidate()
        popToRootTimer = nil
        popToRoot()
    }

    /// True while a hidden palette still holds pre-close state; consuming cancels the reset.
    func consumePreservedState() -> Bool {
        guard let timer = popToRootTimer else { return false }
        timer.invalidate()
        popToRootTimer = nil
        queryWasPreserved = true
        return true
    }

    /// Paste into the previous app while the palette stays frontmost.
    @discardableResult
    func pasteKeepingWindowOpen(_ item: ClipboardItem, store: ClipboardStore) -> Bool {
        Paster.pasteInPlace(item, store: store, into: previousApp)
    }

    /// String flavor of the above, for emoji/symbol pastes.
    func pasteStringKeepingWindowOpen(_ text: String) {
        Paster.pasteStringInPlace(text, into: previousApp)
    }

    // MARK: - NSWindowDelegate

    /// Not for one of our own dialogs: hiding would tear down a command mid-`confirmAlert`.
    func windowDidResignKey(_ notification: Notification) {
        guard isVisible, !core.isShowingDialog else { return }
        // The floating AI bar can be pinned to survive a click into another app.
        if core.palette.aiBar, core.settings.aiBarStaysOpen { return }
        core.paletteCoordinator.hidePalette(restoreFocus: false)
    }

    /// Re-bump a turn later: on the first show a synchronous bump lands before `onChange`.
    func windowDidBecomeKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            core.palette.focusToken = UUID()
            // A re-summon leaves first responder where it was, so neither of these gets an event.
            panel?.trackComposition()
            if let context = panel?.fieldEditorContext {
                core.inputSourceSwitcher.applySession(to: context)
            }
            if queryWasPreserved {
                queryWasPreserved = false
                panel?.selectAllFieldEditorText()
            }
        }
    }

    /// A drag re-anchors the session, so the next resize grows from where the user left it.
    func windowDidMove(_ notification: Notification) {
        guard let panel else { return }
        // The anchor is the bar's top edge. Growing up moves the window's top on resize, so derive
        // it from the fixed bottom instead — otherwise a resize re-anchors to the expanded top.
        let frame = panel.frame
        let top =
            core.palette.aiBarGrowsUp ? frame.minY + metrics.size.compactHeight : frame.maxY
        let moved = CGPoint(x: frame.minX, y: top)
        anchor = moved
        guard drag != nil else { return }
        trackDrag(to: moved)
    }

    // MARK: - Dragging

    /// A press on a drag handle passed the slop that makes it a drag; the guides follow the move.
    func beginDrag() {
        guard let screen = panel?.screen ?? targetScreen() else { return }
        drag = DragSession(
            home: defaultAnchor(on: screen), screenFrame: screen.frame,
            visibleFrame: screen.visibleFrame, displayKey: screen.displayKey)
    }

    /// Release: snap home and forget the stored position, or remember where it was dropped.
    func endDrag() {
        let session = drag
        // Cleared before the snap, so `positionPanel`'s own move isn't read as more dragging.
        drag = nil
        dropGuides.hide()
        guard let panel, let session, session.moved else { return }
        guard session.armed else {
            setStoredPosition(
                anchor.map { PalettePlacement.offset(of: $0, on: session.visibleFrame) },
                on: session.displayKey)
            // A drag can carry the bar across the fold; re-resolve which way it grows so the menus
            // and the docked composer follow it without waiting for the next resize.
            if let anchor { core.palette.aiBarGrowsUp = growsUpward(anchor: anchor) }
            return
        }
        anchor = session.home
        positionPanel(panel, collapsed: core.paletteCoordinator.paletteIsCollapsed)
        setStoredPosition(nil, on: session.displayKey)
    }

    /// Keep the guides on the panel's screen, armed only while a release would snap it home.
    private func trackDrag(to moved: CGPoint) {
        guard var session = drag else { return }
        if let screen = panel?.screen, screen.frame != session.screenFrame {
            session.screenFrame = screen.frame
            session.visibleFrame = screen.visibleFrame
            session.displayKey = screen.displayKey
            session.home = defaultAnchor(on: screen)
        }
        session.armed = PalettePlacement.isSnapping(
            moved, to: session.home, within: Theme.Size.paletteSnapDistance)
        if session.moved {
            dropGuides.move(home: session.home, screenFrame: session.screenFrame)
            dropGuides.setArmed(session.armed)
        } else {
            session.moved = true
            dropGuides.show(
                home: session.home, width: metrics.size.panelWidth,
                screenFrame: session.screenFrame, armed: session.armed)
        }
        drag = session
    }

    // MARK: - Private

    private func ensurePanel() -> PalettePanel {
        if let panel { return panel }
        let root = RootPaletteView().paletteEnvironment(core)
        let panel = PalettePanel(rootView: root)
        panel.delegate = self
        panel.paletteState = core.palette
        // The switch is scoped to the palette's own editing context, never applied globally.
        panel.onFieldEditorFocused = { [weak self] context in
            self?.core.inputSourceSwitcher.applySession(to: context)
        }
        // A menu filters as you type: printable text and backspace edit its query, while the arrows,
        // Return, Tab and Escape fall through to the menu's own key handlers.
        panel.onMenuFilterKey = { [weak self] event in
            guard let core = self?.core, core.palette.menuOpen else { return false }
            guard event.modifierFlags.isDisjoint(with: [.command, .option, .control]) else {
                return false
            }
            if Int(event.keyCode) == kVK_Delete {
                guard !core.palette.menuFilterQuery.isEmpty else { return false }
                core.palette.menuFilterQuery.removeLast()
                return true
            }
            guard let text = event.characters, text.count == 1,
                let scalar = text.unicodeScalars.first,
                scalar.value >= 0x20, scalar.value != 0x7F, scalar.value < 0xF700
            else { return false }
            core.palette.menuFilterQuery.append(text)
            return true
        }
        // Backspace takes Escape's back step but never closes: a root screen falls to the launcher.
        panel.onBareBackspace = { [weak self] in
            guard let core = self?.core, core.palette.query.isEmpty else { return false }
            // A form field owns the key: the text it deletes is the field's, not a query's.
            if core.palette.isEditingField { return false }
            // A plugin surface owns the whole panel and its own keyboard, search field included;
            // the host cannot see whether that field still holds text, so the key is the
            // surface's to consume. Escape is a surface's documented way back out.
            if core.palette.mode == .plugin, core.plugins.surface != nil { return false }
            // A plugin's list levels step back one at a time, like an extension's screens do.
            if core.palette.mode == .plugin, core.pluginCoordinator.canGoBack {
                core.pluginCoordinator.exitPluginScreen()
                return true
            }
            // The argument form steps back through the answers first, one key per field.
            if core.palette.mode == .customCommandArguments,
                let previous = core.customCommandArguments.retreat()
            {
                core.palette.query = previous
                core.palette.selection = 0
                return true
            }
            if core.palette.mode == .extensionCommand {
                core.extensionCoordinator.exitExtensionScreen()
                return true
            }
            if core.palette.mode == .ai, core.aiChatCoordinator.removeLastAttachment() {
                return true
            }
            // The dedicated bar is its own root, not a step off the launcher: an empty backspace
            // stays in it rather than falling back to the command bar.
            if core.palette.aiBar { return true }
            if core.palette.pop() { return true }
            guard core.palette.mode != .launcher else { return false }
            core.palette.prepare(mode: .launcher)
            return true
        }
        installPasteMonitor()
        // Handled at the panel: a focused preview answers Escape before the palette's own handler.
        panel.onEscape = { [weak self] in
            guard let self, core.palette.fileSearchQuickLook else { return false }
            core.palette.fileSearchQuickLook = false
            return true
        }
        // Handled at the panel: the field editor or a missing main menu eats these first.
        panel.onCommandShortcut = { [weak self] event in
            guard let self else { return false }
            if self.core.palette.mode == .emoji, let zoom = Self.emojiGridZoom(from: event) {
                self.core.palette.noteEmojiGridZoom(zoom)
                return true
            }
            guard Self.commandCharacter(from: event) != nil else { return false }
            if self.core.palette.mode == .launcher || self.core.palette.mode == .clipboard,
                let index = FavoriteSlots.index(forKeyCode: event.keyCode)
            {
                self.core.palette.noteFavoriteSlot(index)
                return true
            }
            guard let character = Self.commandCharacter(from: event) else { return false }
            switch character {
            case ",":
                // In AI Chat, ⌘, lands on the AI pane the actions menu advertises, not General.
                if self.core.palette.mode == .ai {
                    self.core.aiChatCoordinator.showSettings()
                } else {
                    self.core.settingsCoordinator.showSettings()
                }
                return true
            // Pin. Swallowed on every screen, since ⌘. only ever means cancel to a search field.
            case ".":
                self.core.palette.notePinChord()
                return true
            case "w":
                self.core.paletteCoordinator.hidePalette()
                return true
            default:
                return false
            }
        }
        // Typed keys while an inline ⌘K editor is open on a row: edit the draft, commit on ↵.
        panel.onMenuInlineKey = { [weak self] event in
            guard let self, event.modifierFlags.isDisjoint(with: [.command, .control]) else {
                return false
            }
            if let key = core.palette.aliasEditKey {
                return applyInlineEdit(
                    event, draft: { core.palette.aliasDraft },
                    set: { core.palette.aliasDraft = $0 },
                    commit: { core.aliases.setAlias(core.palette.aliasDraft, for: key) },
                    end: { core.palette.aliasEditKey = nil })
            }
            if let id = core.palette.renameEditID {
                return applyInlineEdit(
                    event, draft: { core.palette.renameDraft },
                    set: { core.palette.renameDraft = $0 },
                    commit: {
                        core.quicklinkCoordinator.renameQuicklink(id: id, to: core.palette.renameDraft)
                    },
                    end: { core.palette.renameEditID = nil })
            }
            return false
        }
        self.panel = panel
        return panel
    }

    /// One inline ⌘K field editor's keystrokes: Escape cancels, ↵ commits then ends, ⌫ backspaces,
    /// printable characters append. Shared by the alias and quicklink-rename rows.
    private func applyInlineEdit(
        _ event: NSEvent, draft: () -> String, set: (String) -> Void,
        commit: () -> Void, end: () -> Void
    ) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            end()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            commit()
            end()
        case kVK_Delete:
            var value = draft()
            if !value.isEmpty {
                value.removeLast()
                set(value)
            }
        default:
            let printable = (event.characters ?? "").unicodeScalars.filter {
                $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value)
            }
            if !printable.isEmpty { set(draft() + String(String.UnicodeScalarView(printable))) }
        }
        return true
    }

    /// Resize to the given state; the AI bar animates its grow/shrink, everything else snaps.
    func applyCollapsed(_ collapsed: Bool) {
        guard let panel else { return }
        positionPanel(panel, collapsed: collapsed, animated: core.palette.aiBar && panel.isVisible)
    }

    /// A new width invalidates the placement the cached anchor encoded, so re-resolve it.
    func applyInterfaceSize() {
        guard let panel else { return }
        anchor = nil
        positionPanel(panel, collapsed: core.paletteCoordinator.paletteIsCollapsed)
    }

    /// Size to height and place against the session anchor; the AI bar may grow up instead of down.
    private func positionPanel(_ panel: NSPanel, collapsed: Bool, animated: Bool = false) {
        guard let anchor = resolveAnchor() else { return }
        let size = metrics.size
        // The AI composer grows the collapsed bar until it hits its scroll threshold; else 0.
        let height =
            collapsed ? size.compactHeight + core.palette.aiComposerExtraHeight : size.panelHeight
        let growsUp = growsUpward(anchor: anchor)
        // The view docks the composer at the bottom when the bar grows up, so publish the direction.
        core.palette.aiBarGrowsUp = growsUp
        // Growing up keeps the bar's bottom edge fixed; every other placement keeps its top.
        let originY = growsUp ? anchor.y - size.compactHeight : anchor.y - height
        // An active Assistant may pin its own width; otherwise the shared one.
        let width = core.palette.activeAssistantID
            .flatMap { core.assistants.assistant(id: $0)?.width } ?? size.panelWidth
        let frame = NSRect(x: anchor.x, y: originY, width: width, height: height)
        guard animated else {
            panel.setFrame(frame, display: true)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Theme.Duration.aiBarResize
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }
    }

    /// An AI bar placed low grows into the space above it, so its transcript never runs off-screen.
    private func growsUpward(anchor: CGPoint) -> Bool {
        guard core.palette.aiBar,
            let visibleFrame = (panel?.screen ?? targetScreen())?.visibleFrame
        else { return false }
        return anchor.y - metrics.size.panelHeight < visibleFrame.minY
    }

    /// The display to anchor to; never `NSScreen.main`, which follows the focused window.
    private func targetScreen() -> NSScreen? {
        core.settings.openOnCursorScreen ? NSScreen.underCursor : NSScreen.primary
    }

    /// Cached until hide, so both placements read one `visibleFrame`; a drag outranks the setting.
    private func resolveAnchor() -> CGPoint? {
        if let anchor { return anchor }
        let resolved = targetScreen().flatMap { restoredAnchor(on: $0) ?? defaultAnchor(on: $0) }
        anchor = resolved
        return resolved
    }

    /// Each surface keeps its own placement: an active Assistant's own, else the AI bar's, else the
    /// launcher's, so dragging one never moves another.
    private func storedPosition(on display: String) -> CGPoint? {
        if let id = core.palette.activeAssistantID {
            return core.assistants.assistant(id: id)?.position(on: display)
        }
        return core.palette.aiBar
            ? core.settings.aiBarPosition(on: display) : core.settings.palettePosition(on: display)
    }

    private func setStoredPosition(_ offset: CGPoint?, on display: String) {
        if let id = core.palette.activeAssistantID {
            core.assistants.setPosition(offset, for: id, on: display)
        } else if core.palette.aiBar {
            core.settings.setAIBarPosition(offset, on: display)
        } else {
            core.settings.setPalettePosition(offset, on: display)
        }
    }

    /// This display's own corner, unless too little of the bar would stay grabbable.
    private func restoredAnchor(on screen: NSScreen) -> CGPoint? {
        guard let offset = storedPosition(on: screen.displayKey) else { return nil }
        return PalettePlacement.restored(
            PalettePlacement.anchor(for: offset, on: screen.visibleFrame),
            graspable: CGSize(width: metrics.size.panelWidth, height: metrics.size.compactHeight),
            visibleFrame: screen.visibleFrame,
            minimumVisible: Theme.Size.paletteMinimumVisible)
    }

    /// The untouched placement on one display; the summon path and the drop guides share it.
    private func defaultAnchor(on screen: NSScreen) -> CGPoint {
        PalettePlacement.defaultAnchor(
            in: screen.visibleFrame, width: metrics.size.panelWidth,
            topMarginFraction: Theme.Size.paletteTopMarginFraction)
    }

    private var metrics: InterfaceMetrics { core.settings.interfaceSize.metrics }
}

extension NSScreen {
    /// Survives a replug; the display ID is a session-only fallback.
    fileprivate var displayKey: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let id = number?.uint32Value else { return "primary" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
            let string = CFUUIDCreateString(nil, uuid) as String?
        else { return String(id) }
        return string.lowercased()
    }
}
