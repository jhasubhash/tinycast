import Foundation

struct NotificationSpec: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var title: String
    var body: String
    var style: NotificationStyle
    var corner: NotificationCorner
    var dwell: TimeInterval?          // nil = sticky until dismissed
    var actions: [NotificationAction]
}

enum NotificationStyle: String, Codable, Sendable, CaseIterable {
    case toast, banner, card
}

enum NotificationCorner: String, Codable, Sendable, CaseIterable {
    case topLeading, topTrailing, bottomLeading, bottomTrailing
}

struct NotificationAction: Codable, Hashable, Sendable, Identifiable {
    var id: String
    var title: String
}
