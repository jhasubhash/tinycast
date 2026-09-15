import SwiftUI

/// Which of the composer's own menu buttons is open; `AIChatPopOutRoot` keeps at most one.
enum AIChatMenuKind: Hashable {
    case model
    case reasoning
}

/// Where each composer menu button sits, read at the pop-out's root to place that button's own
/// popover precisely. A plain sibling overlay can't reach across `PopOutWindowChrome`'s rounded
/// clip with a button's live frame otherwise, and a fixed offset would drift with the model or
/// reasoning title's own width.
private struct AIChatMenuAnchors: PreferenceKey {
    static var defaultValue: [AIChatMenuKind: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [AIChatMenuKind: Anchor<CGRect>],
        nextValue: () -> [AIChatMenuKind: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// The AI Chat pop-out's true root. `PopOutWindowChrome` clips its content to the window's rounded
/// corners, which would slice off a menu popover opened near that edge — so this hosts each one as
/// a sibling *above* the clip instead of letting `AIChatWindowView` render them itself, anchored to
/// the real button position via `AIChatMenuAnchors`.
struct AIChatPopOutRoot: View {
    let chat: AIChatState
    let settings: AISettingsStore
    let coordinator: AIChatCoordinator
    let menu: PopOutWindowMenu
    let commands: () -> [PopOutWindowCommand]

    @Environment(\.metrics) private var metrics
    @State private var openMenu: AIChatMenuKind?
    @State private var menuSelection = 0
    @State private var menuHeight: CGFloat = 0

    var body: some View {
        PopOutWindowChrome(menu: menu, commands: commands) {
            AIChatWindowView(
                chat: chat, settings: settings, coordinator: coordinator,
                isModelMenuOpen: openMenu == .model, isReasoningMenuOpen: openMenu == .reasoning,
                toggleModelMenu: toggleModel, toggleReasoningMenu: toggleReasoning,
                handleMenuKey: handleMenuKey)
        }
        // Click anywhere off an open menu closes it, as the actions palette's own scrim does.
        .overlay {
            if openMenu != nil {
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onEnded { _ in openMenu = nil })
                    .onRightClick { openMenu = nil }
            }
        }
        .overlayPreferenceValue(AIChatMenuAnchors.self) { anchors in
            GeometryReader { proxy in
                if let openMenu, let anchor = anchors[openMenu] {
                    let rect = proxy[anchor]
                    // Alignment guides don't reposition a lone child across a `GeometryReader`, so
                    // the menu's own height is measured and its top-left is offset to sit the whole
                    // popover 8pt above the button — hidden for the one frame before that height is
                    // known, so it never flashes at the reader's origin.
                    menuView(for: openMenu)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                        .offset(x: rect.minX, y: rect.minY - menuHeight - metrics.spacing.sm)
                        .opacity(menuHeight > 0 ? 1 : 0)
                        .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                }
            }
        }
    }

    /// The exact catalog the palette's own switchers show — same sections, brand icons and
    /// reasoning ladder — just anchored above this window's own buttons.
    @ViewBuilder
    private func menuView(for kind: AIChatMenuKind) -> some View {
        let content: PopoverMenuContent =
            switch kind {
            case .model: AIModelMenu.models(coordinator: coordinator)
            case .reasoning: AIModelMenu.reasoning(coordinator: coordinator, settings: settings)
            }
        PopoverMenu(
            header: content.header, items: content.items, selection: $menuSelection,
            width: metrics.size.menuWidth,
            onActivate: { index in
                openMenu = nil
                content.items[index].action()
            })
    }

    private func toggleModel() {
        guard openMenu != .model else {
            openMenu = nil
            return
        }
        let refreshTask = coordinator.prepareModelSwitcher()
        openMenu = .model
        menuSelection = AIModelMenu.modelHighlight(coordinator: coordinator, settings: settings)
        Task { @MainActor in
            await refreshTask.value
            guard openMenu == .model else { return }
            menuSelection = AIModelMenu.modelHighlight(coordinator: coordinator, settings: settings)
        }
    }

    private func toggleReasoning() {
        guard openMenu != .reasoning else {
            openMenu = nil
            return
        }
        openMenu = .reasoning
        menuSelection = AIModelMenu.reasoningHighlight(coordinator: coordinator, settings: settings)
    }

    private func handleMenuKey(_ key: KeyEquivalent) {
        guard let openMenu else { return }
        let items: [PopoverMenuItem] =
            switch openMenu {
            case .model: AIModelMenu.models(coordinator: coordinator).items
            case .reasoning: AIModelMenu.reasoning(coordinator: coordinator, settings: settings).items
            }
        switch key {
        case .upArrow:
            menuSelection = max(0, menuSelection - 1)
        case .downArrow:
            menuSelection = min(max(items.count - 1, 0), menuSelection + 1)
        case .escape:
            self.openMenu = nil
        case .return:
            self.openMenu = nil
            if items.indices.contains(menuSelection) { items[menuSelection].action() }
        default:
            break
        }
    }
}

/// AI Chat's pop-out window content: the same transcript the palette's own AI screen shows, with a
/// composer docked at the bottom. Deliberately its own text field, not the palette's search field —
/// the window has to work with the palette hidden, or showing something else entirely, so it can't
/// share that field's state.
struct AIChatWindowView: View {
    let chat: AIChatState
    let settings: AISettingsStore
    let coordinator: AIChatCoordinator
    let isModelMenuOpen: Bool
    let isReasoningMenuOpen: Bool
    let toggleModelMenu: () -> Void
    let toggleReasoningMenu: () -> Void
    let handleMenuKey: (KeyEquivalent) -> Void

    @Environment(\.metrics) private var metrics
    @State private var draft = ""
    @State private var hostWindow: NSWindow?
    @FocusState private var focused: Bool

    private var anyMenuOpen: Bool { isModelMenuOpen || isReasoningMenuOpen }

    var body: some View {
        VStack(spacing: 0) {
            AIChatView(
                chat: chat, settings: settings, availability: coordinator.availability,
                showReasoning: coordinator.activeAssistant?.showReasoning ?? settings.showReasoning,
                onConfigure: coordinator.showSettings, onAppear: coordinator.prepareForChat)
            composer
        }
        .background(WindowReader { hostWindow = $0 })
        // Attached above the composer's own controls, so it still fires once a menu button — not
        // the text field — holds focus.
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .escape], phases: .down) { press in
            guard anyMenuOpen else { return .ignored }
            handleMenuKey(press.key)
            return .handled
        }
        .onAppear { focused = true }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            textField
            statusRow
        }
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.md)
    }

    /// An empty title, plus its own overlay for the prompt: SwiftUI's native placeholder distorts
    /// the caret on a vertical-axis field, exactly as it would on the palette's own composer.
    private var textField: some View {
        TextField("", text: $draft, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...8)
            .font(.system(size: 16))
            .tint(Theme.Colors.textPrimary)
            .focused($focused)
            .background(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Ask anything…")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .allowsHitTesting(false)
                }
            }
            // Plain ↵ sends (or stops a streaming reply); ⇧↵ drops a line break instead — the
            // field's own vertical axis never turns Return into one on its own here.
            .onKeyPress(keys: [.return], phases: .down) { press in
                guard !anyMenuOpen else { return .ignored }
                if press.modifiers == .shift {
                    _ = (hostWindow as? PopOutWindowPanel)?.insertIntoField("\n")
                    return .handled
                }
                guard press.modifiers.isEmpty else { return .ignored }
                send()
                return .handled
            }
    }

    private var statusRow: some View {
        HStack(spacing: metrics.spacing.xs) {
            AIModelButton(
                title: coordinator.selectedModelTitle, icon: coordinator.selectedModelIcon,
                isOpen: isModelMenuOpen, action: toggleModelMenu
            )
            .anchorPreference(key: AIChatMenuAnchors.self, value: .bounds) { [.model: $0] }
            if !coordinator.reasoningEfforts.isEmpty {
                AIReasoningButton(
                    title: coordinator.selectedReasoningTitle, isOpen: isReasoningMenuOpen,
                    action: toggleReasoningMenu
                )
                .anchorPreference(key: AIChatMenuAnchors.self, value: .bounds) { [.reasoning: $0] }
            }
            Spacer(minLength: 0)
        }
    }

    private func send() {
        if chat.isStreaming {
            coordinator.stopResponse()
            return
        }
        guard coordinator.send(draft) else { return }
        draft = ""
    }
}
