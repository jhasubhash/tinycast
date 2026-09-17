import AppKit
import SwiftUI

/// Unlike `HUDPresenter`, notifications stack per corner instead of replacing one another.
@MainActor
final class NotificationPresenter {
    private struct Entry {
        let id: UUID
        let panel: NotificationPanel
    }

    private let screen: () -> NSScreen?
    private var stacks: [NotificationCorner: [Entry]] = [:]
    private var corners: [UUID: NotificationCorner] = [:]
    private var dismissals: [UUID: Task<Void, Never>] = [:]

    private static let inset: CGFloat = Theme.Spacing.xxl
    private static let stackGap: CGFloat = Theme.Spacing.md

    init(screen: @escaping () -> NSScreen?) {
        self.screen = screen
    }

    /// `content` is the override seam: nil renders the built-in `NotificationCardView`.
    @discardableResult
    func post(
        _ spec: NotificationSpec, content: AnyView? = nil, onAction: ((String) -> Void)? = nil
    ) -> UUID {
        let id = spec.id
        let panel = NotificationPanel()
        let body = content ?? AnyView(
            NotificationCardView(
                spec: spec,
                onAction: { onAction?($0) },
                onDismiss: { [weak self] in self?.dismiss(id) }))
        let host = NSHostingView(rootView: body)
        // Never size from `host.frame` after attaching: AppKit resets it to the content rect.
        let size = host.fittingSize
        host.setFrameSize(size)
        panel.setContentSize(size)
        panel.contentView = host

        corners[id] = spec.corner
        stacks[spec.corner, default: []].insert(Entry(id: id, panel: panel), at: 0)
        layout(corner: spec.corner)
        panel.fadeIn(duration: Theme.Duration.enter) { panel.orderFrontRegardless() }

        if let dwell = spec.dwell {
            dismissals[id] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(dwell))
                guard !Task.isCancelled else { return }
                self?.dismiss(id)
            }
        }
        return id
    }

    func dismiss(_ id: UUID) {
        dismissals[id]?.cancel()
        dismissals[id] = nil
        guard let corner = corners.removeValue(forKey: id),
            var entries = stacks[corner],
            let index = entries.firstIndex(where: { $0.id == id })
        else { return }
        let entry = entries.remove(at: index)
        stacks[corner] = entries
        entry.panel.fadeOut(duration: Theme.Duration.exit) { [weak self] in
            self?.layout(corner: corner)
        }
    }

    func dismissAll() {
        for task in dismissals.values { task.cancel() }
        dismissals.removeAll()
        for entries in stacks.values {
            for entry in entries { entry.panel.fadeOut(duration: Theme.Duration.exit) }
        }
        stacks.removeAll()
        corners.removeAll()
    }

    /// Newest first: index 0 sits nearest the corner, pushing older cards further away.
    private func layout(corner: NotificationCorner) {
        guard let visible = screen()?.visibleFrame, let entries = stacks[corner] else { return }
        var offset: CGFloat = 0
        for entry in entries {
            let size = entry.panel.frame.size
            let origin = NotificationPlacement.origin(
                corner: corner, content: size, in: visible, inset: Self.inset, stackOffset: offset)
            entry.panel.setFrameOrigin(origin)
            offset += size.height + Self.stackGap
        }
    }
}
