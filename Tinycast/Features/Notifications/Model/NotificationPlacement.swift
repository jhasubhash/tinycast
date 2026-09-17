import CoreGraphics

/// Pure frame math for stacking notification cards in a screen corner.
enum NotificationPlacement {
    /// `stackOffset` grows away from the corner, so successive cards in a stack don't overlap.
    static func origin(
        corner: NotificationCorner, content: CGSize, in visibleFrame: CGRect, inset: CGFloat,
        stackOffset: CGFloat
    ) -> CGPoint {
        let x: CGFloat
        switch corner {
        case .topLeading, .bottomLeading:
            x = visibleFrame.minX + inset
        case .topTrailing, .bottomTrailing:
            x = visibleFrame.maxX - inset - content.width
        }
        let y: CGFloat
        switch corner {
        case .topLeading, .topTrailing:
            y = visibleFrame.maxY - inset - content.height - stackOffset
        case .bottomLeading, .bottomTrailing:
            y = visibleFrame.minY + inset + stackOffset
        }
        return CGPoint(x: x, y: y)
    }
}
