import SwiftUI

/// The alias / shortcut editors that live on their own rows in the ⌘K action panel. Both read live
/// state from the environment, so the hosted menu tree redraws them as the draft or binding changes.
enum LauncherInlineEditor {
    /// The trailing box for the "Change Alias" row, as the accessory builder a `PopoverMenuItem` takes.
    @MainActor
    static func aliasBox(key: String) -> @MainActor @Sendable () -> AnyView {
        { AnyView(MenuAliasBox(key: key)) }
    }

    /// The trailing box for the "Change Shortcut" row: the shipped recorder, live-bound to the key.
    @MainActor
    static func shortcutBox(action: HotKeyAction) -> @MainActor @Sendable () -> AnyView {
        { AnyView(ShortcutRecorder(action: action, recordingAccent: false, showsConflictInline: true)) }
    }
}

/// Shows the saved alias, or the live draft with a caret while its row's editor is open.
private struct MenuAliasBox: View {
    let key: String
    @Environment(\.metrics) private var metrics
    @Environment(PaletteState.self) private var palette
    @Environment(AliasStore.self) private var aliases

    private var editing: Bool { palette.aliasEditKey == key }
    private var value: String { editing ? palette.aliasDraft : (aliases.alias(for: key) ?? "") }

    var body: some View {
        HStack(spacing: 1) {
            Text(value.isEmpty ? "Add Alias" : value)
                .font(metrics.typography.keyCap)
                .foregroundStyle(textColor)
                .lineLimit(1)
                .truncationMode(.tail)
            if editing {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Theme.Colors.textSecondary)
                    .frame(width: 1.5, height: metrics.scaled(12))
            }
        }
        .frame(width: metrics.scaled(112), height: metrics.scaled(20))
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
                .fill(Theme.Colors.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.menuRow, style: .continuous)
                .strokeBorder(Theme.Colors.cardStroke, lineWidth: 1))
    }

    /// Faded until the row is being edited, so it reads as settled once ↵ or a click outside commits.
    private var textColor: Color {
        if value.isEmpty { return Theme.Colors.textTertiary }
        return editing ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
    }
}
