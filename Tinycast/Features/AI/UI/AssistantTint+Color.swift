import SwiftUI

/// The UI layer's mapping from the Foundation-only `AssistantTint` to a rendered accent. Kept out of
/// the model so `Assistant` never imports SwiftUI; the bar's glyph and the Settings swatch share it.
extension AssistantTint {
    var color: Color {
        switch self {
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .teal: return .teal
        case .gray: return .gray
        }
    }

    var title: String {
        switch self {
        case .blue: return "Blue"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .red: return "Red"
        case .orange: return "Orange"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .teal: return "Teal"
        case .gray: return "Gray"
        }
    }
}
