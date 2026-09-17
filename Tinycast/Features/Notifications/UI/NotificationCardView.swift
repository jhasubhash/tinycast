import SwiftUI

/// The built-in body for a posted notification; a caller can host its own view in its place.
struct NotificationCardView: View {
    let spec: NotificationSpec
    let onAction: (String) -> Void
    let onDismiss: () -> Void

    var body: some View {
        switch spec.style {
        case .toast: toast
        case .banner: banner
        case .card: card
        }
    }

    private var toast: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(spec.title)
                .font(Theme.Typography.bar)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
            closeButton
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .fixedSize()
        .background(Theme.Colors.panelScrim)
        .background(VisualEffectView())
        .clipShape(Capsule())
    }

    private var banner: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            textBlock
            Spacer(minLength: 0)
            closeButton
        }
        .padding(Theme.Spacing.xl)
        .frame(width: Theme.Size.hudMaxWidth, alignment: .leading)
        .background(Theme.Colors.panelScrim)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                textBlock
                Spacer(minLength: 0)
                closeButton
            }
            if !spec.actions.isEmpty {
                HStack(spacing: Theme.Spacing.md) {
                    Spacer(minLength: 0)
                    ForEach(spec.actions) { action in
                        NotificationActionButton(
                            action: action, onActivate: { onAction(action.id) })
                    }
                }
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(width: Theme.Size.dialogWidth, alignment: .leading)
        .background(Theme.Colors.panelScrim)
        .background(VisualEffectView())
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private var textBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(spec.title).font(Theme.Typography.panelTitle)
            Text(spec.body)
                .font(Theme.Typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
}

private struct NotificationActionButton: View {
    let action: NotificationAction
    let onActivate: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onActivate) {
            Text(action.title)
                .font(Theme.Typography.bar)
                .foregroundStyle(Color.primary)
                .padding(.horizontal, Theme.Spacing.xl)
                .frame(height: Theme.Size.menuButton)
                .contentShape(Capsule())
                .background(Capsule().fill(hovered ? Theme.Colors.menuHover : Color.clear))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .frosted(in: Capsule())
    }
}
