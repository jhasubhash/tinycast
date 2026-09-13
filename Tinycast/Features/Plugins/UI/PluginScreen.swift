import SwiftUI
import TinycastPluginKit

/// The palette screen for a running native plugin. `rows` is the plugin's current level, so the
/// flat selection indexes it 1:1; a surface level hides the rows and hands the body to the plugin.
struct PluginScreen: PaletteScreen {
    let manager: PluginManager
    let vm: PaletteState
    let openActions: () -> Void

    private var query: String { vm.query }

    var rows: [PluginResult] { manager.rows(query: query) }

    /// A surface owns the whole palette body, so the search field steps aside.
    var hidesSearchField: Bool { manager.surface != nil }

    var primaryActionTitle: String {
        guard rows.indices.contains(vm.selection) else { return "Open" }
        switch rows[vm.selection].action {
        case .run: return "Run"
        case .children: return "Browse"
        case .openURL, .surface, .none: return "Open"
        }
    }

    func hasPrimaryAction(at selection: Int) -> Bool {
        guard rows.indices.contains(selection) else { return false }
        return rows[selection].action != .none
    }

    /// Plugins carry no ⌘K menu of their own: their rows are their actions.
    func hasActions(at selection: Int) -> Bool { false }

    func activate(at selection: Int) {
        guard rows.indices.contains(selection) else { return }
        manager.activate(rows[selection], query: query)
    }

    /// Plugins have no ⌘↵ secondary action.
    func secondary(at selection: Int) -> Bool { false }

    func body(selection: Int, scroll: ScrollIntent) -> AnyView {
        AnyView(
            PluginScreenView(
                rows: rows,
                state: manager.state,
                surface: manager.surface,
                metadata: manager.metadata,
                selection: selection,
                scroll: scroll,
                onSelect: { vm.selection = $0 },
                onActivate: { activate(at: $0) }))
    }
}

/// Draws the running plugin: its surface when one is up, else its current list of rows.
private struct PluginScreenView: View {
    @Environment(\.metrics) private var metrics
    let rows: [PluginResult]
    let state: PluginSessionState
    let surface: AnyView?
    let metadata: PluginMetadata?
    let selection: Int
    let scroll: ScrollIntent
    let onSelect: (Int) -> Void
    let onActivate: (Int) -> Void

    private var selectedRowID: String? {
        rows.indices.contains(selection) ? rows[selection].id : nil
    }

    var body: some View {
        Group {
            if let surface {
                surface
            } else {
                switch state {
                case .loading:
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .failed(let message):
                    EmptyResults(text: message)
                case .idle, .active:
                    list
                }
            }
        }
    }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            EmptyResults(text: metadata.map { "No results in \($0.name)" } ?? "No results")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            PluginRow(result: row, selected: row.id == selectedRowID)
                                .contentShape(Rectangle())
                                .onTapGesture { onActivate(index) }
                                .selectionFrame(row.id == selectedRowID)
                        }
                    }
                    .padding(.horizontal, metrics.spacing.md)
                    .padding(.vertical, metrics.spacing.xs)
                    .hideNativeScrollers()
                    .scrollOriginAnchor()
                }
                .edgeDissolve()
                .thinScrollbar()
                .scrollFollowsSelection(
                    scroll, row: selectedRowID, atOrigin: selection == 0, proxy: proxy)
            }
        }
    }
}

private struct PluginRow: View {
    @Environment(\.metrics) private var metrics
    let result: PluginResult
    let selected: Bool
    @State private var hovered = false

    private var fill: Color {
        if selected { return Theme.Colors.selection }
        if hovered { return Theme.Colors.rowHover }
        return .clear
    }

    private var iconSource: EntryIcon {
        switch result.icon {
        case .symbol(let name): return .symbol(name)
        case .file: return .file(stamp: 0)
        }
    }

    private var iconFileURL: URL {
        if case .file(let url) = result.icon { return url }
        return URL(fileURLWithPath: "/")
    }

    var body: some View {
        HStack(spacing: metrics.spacing.lg) {
            EntryIconView(source: iconSource, fileURL: iconFileURL)
                .frame(width: metrics.size.rowIcon, height: metrics.size.rowIcon)
            Text(result.title)
                .font(metrics.typography.rowTitle)
                .lineLimit(1)
            if let subtitle = result.subtitle {
                Text(subtitle)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: metrics.spacing.sm)
            if let trailing = result.trailingText {
                Text(trailing)
                    .font(metrics.typography.rowTrailing)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, metrics.spacing.md)
        .padding(.vertical, metrics.spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                .fill(fill))
        .armedHover($hovered)
    }
}
