import AppKit
import SwiftUI

/// One row of a pop-out window's own ⌘K command palette — the window's controls, not whatever it
/// hosts. Shared by every pop-out (native plugins, AI Chat), keyed by nothing but its own list: each
/// controller supplies the rows current for its one window.
struct PopOutWindowCommand: Identifiable {
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
final class PopOutWindowMenu {
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
private func visibleCommands(_ all: [PopOutWindowCommand], _ query: String) -> [PopOutWindowCommand] {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    guard !needle.isEmpty else { return all }
    return all.filter { $0.title.lowercased().contains(needle) }
}

/// A borderless floating panel that hosts one SwiftUI view as its own standalone
/// window. It carries no palette header, footer or drag strip — the only host chrome is a ⌘K command
/// palette pinned bottom-right, in the app's own actions-menu shape, for the window's controls. The
/// user moves it by dragging its background, resizes it from any edge, and opens the menu with ⌘K.
/// Multiple can float at once — a stock plugin's ADBE chart beside its MSFT chart, say.
final class PopOutWindowPanel: NSPanel {
    /// The identity this window shows, so its controller can find and drop it on close.
    var identityKey: String?
    /// The window's own ⌘K palette; key handling below drives it, scoped to this panel.
    var commandMenu: PopOutWindowMenu?
    var commandsProvider: (() -> [PopOutWindowCommand])?

    // Not nonactivating: it yields key when Tinycast deactivates, so the displaced app refocuses.
    init(content: NSView, size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .resizable, .fullSizeContentView],
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

    /// SwiftUI's text fields all edit through the window's one shared field editor.
    private var fieldEditor: NSTextView? { firstResponder as? NSTextView }

    /// Insert text at the field editor's caret — a composer's own Shift+↵ line break.
    @discardableResult
    func insertIntoField(_ text: String) -> Bool {
        guard let editor = fieldEditor else { return false }
        editor.insertText(text, replacementRange: editor.selectedRange())
        return true
    }

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
    /// rather than reaching the hosted view, exactly as the app's own ⌘K menus behave.
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

/// Centres a fresh pop-out on whichever screen the cursor is over, matching where the launcher itself
/// tends to be summoned.
func positionPopOutWindow(_ panel: NSPanel, size: CGSize) {
    let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    guard let visible = screen?.visibleFrame else { return panel.center() }
    let origin = CGPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
    panel.setFrame(NSRect(origin: origin, size: size), display: false)
}

/// A pop-out's window chrome: the same dark scrim-over-blur backdrop the palette draws, so a
/// transparent hosted surface reads identically here, plus a ⌘K command palette pinned bottom-right
/// in the app's actions-menu shape. No header, footer or toolbar — the content owns the rest.
struct PopOutWindowChrome<Content: View>: View {
    private let menu: PopOutWindowMenu
    private let commands: () -> [PopOutWindowCommand]
    private let content: Content

    @Environment(AppSettings.self) private var settings
    @Environment(\.metrics) private var metrics
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        menu: PopOutWindowMenu,
        commands: @escaping () -> [PopOutWindowCommand],
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
                    PopOutWindowPalette(menu: menu, commands: commands())
                        .padding(.trailing, 12)
                        .padding(.bottom, 56)
                        .transition(
                            .scale(scale: 0.96, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            // The same subtle scale-and-fade the launcher's own ⌘K menu closes with.
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: menu.open)
            .onHover { hovering = $0 }
    }

    /// The "Actions ⌘K" pill, the app's own footer convention — hover-revealed so it never sits on
    /// the hosted content, and a mouse route to the same palette ⌘K opens.
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
private struct PopOutWindowPalette: View {
    let menu: PopOutWindowMenu
    let commands: [PopOutWindowCommand]

    private var visible: [PopOutWindowCommand] { visibleCommands(commands, menu.query) }

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

    private func row(_ command: PopOutWindowCommand, selected: Bool) -> some View {
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
struct WindowKeyCap: View {
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
