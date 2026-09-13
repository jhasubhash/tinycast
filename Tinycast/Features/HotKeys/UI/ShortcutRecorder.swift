import SwiftUI

/// Deliberately not a focusable control. See docs/features/hotkeys.md#recorder.
struct ShortcutRecorder: View {
    let action: HotKeyAction
    /// Drops the empty well's fill: a column of identical pills reads louder than its rows.
    var isQuiet = false
    /// Off for surfaces that don't want the accent ring while recording — the ⌘K menu row is one.
    var recordingAccent = true
    /// Shows a taken-chord conflict in the field itself, for rows with no callout to host it.
    var showsConflictInline = false

    @Environment(HotKeyManager.self) private var hotKeys
    /// Observed so a bound double-tap surfaces its warning the moment the grant changes.
    private var doubleTapMonitor: DoubleTapMonitor { hotKeys.doubleTapMonitor }
    @State private var hovered = false

    private var isRecording: Bool { hotKeys.recordingAction == action }

    /// The taken-chord this field should call out, or nil — only while it is the recording one.
    private var conflict: ShortcutCaptureSession.Conflict? {
        showsConflictInline && isRecording ? hotKeys.capture.conflict : nil
    }

    private var borderColor: Color {
        if conflict != nil { return .orange }
        return isRecording && recordingAccent ? Color.accentColor : Theme.Colors.cardStroke
    }

    /// Sits back a shade until pointed at, without reading as something you cannot press.
    private var unsetInk: Color {
        isRecording || !isQuiet || hovered
            ? Theme.Colors.textSecondary : Theme.Colors.textTertiary
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.menu, style: .continuous)
        // The width is kept either way, so a column of recorders stays aligned as they fill in.
        let showsFill = !isQuiet || isRecording || hovered || hotKeys.binding(for: action) != nil
        content
            .padding(.horizontal, Theme.Spacing.sm)
            .frame(width: Theme.Size.shortcutRecorder, height: 24)
            .background(shape.fill(Theme.Colors.cardFill).opacity(showsFill ? 1 : 0))
            .overlay(shape.strokeBorder(borderColor, lineWidth: 1))
            // An over-long binding truncates rather than resizing the field.
            .clipShape(shape)
            .contentShape(shape)
            .onTapGesture { hotKeys.recordingAction = action }
            .onHover { hovered = $0 }
            // Hand the callout this field's bounds while it's the open one.
            .anchorPreference(key: ShortcutRecorderAnchorKey.self, value: .bounds) {
                isRecording ? $0 : nil
            }
            // Rows are lazy: a recording row scrolled away must release the session.
            .onDisappear { if isRecording { hotKeys.recordingAction = nil } }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }

    @ViewBuilder
    private var content: some View {
        // A taken chord calls out its owner, then reverts to "Listening…" so a retry is obvious.
        if let conflict {
            Text("In use · \(conflict.owner)")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(.orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .help("\(conflict.binding.keycaps.joined()) is already used by \(conflict.owner)")
        } else if isRecording {
            // "Listening…" wins even over a set binding, so the field reads as live while recording.
            Text("Listening…")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(unsetInk)
        } else if let binding = hotKeys.binding(for: action) {
            boundLabel(binding)
        } else {
            Text("Record")
                .font(Theme.Typography.keyCap)
                .foregroundStyle(unsetInk)
        }
    }

    private func boundLabel(_ binding: HotKeyBinding) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            // A double-tap binding is dead without the grant, so say so where the binding is.
            if binding.doubleTapModifier != nil, doubleTapMonitor.needsAccessibility {
                Button {
                    Permissions.openAccessibilitySettings()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Double-tap shortcuts need Accessibility access. Click to grant it.")
            }
            ForEach(Array(binding.keycaps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(Theme.Typography.keyCap)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Theme.Spacing.xs)
                    .frame(
                        minWidth: Theme.Size.recorderKeyCap, minHeight: Theme.Size.recorderKeyCap
                    )
                    .background(
                        RoundedRectangle(
                            cornerRadius: Theme.Radius.recorderKeyCap, style: .continuous
                        )
                        .fill(Color.primary.opacity(0.08))
                    )
            }
        }
        .frame(maxWidth: .infinity)
        // Overlaid, not a row member, so it costs the caps no width.
        .overlay(alignment: .trailing) {
            Button {
                hotKeys.setBinding(nil, for: action)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovered ? 1 : 0)
            .allowsHitTesting(hovered)
        }
    }
}
