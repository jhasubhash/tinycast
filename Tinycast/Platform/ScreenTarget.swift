import AppKit

extension NSScreen {
    /// The display in use; `NSScreen.main` is the key window's, which we rarely have.
    static var underCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        // NSMouseInRect, not `contains`: the topmost row otherwise reads as the display above.
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main
    }

    /// The menu-bar display: the one at the global origin, which `NSScreen.main` is not.
    static var primary: NSScreen? {
        screens.first { $0.frame.origin == .zero } ?? screens.first
    }

    /// Stable per-display identity for a stored position: survives a replug, unlike the display ID.
    var displayKey: String {
        let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        guard let id = number?.uint32Value else { return "primary" }
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
            let string = CFUUIDCreateString(nil, uuid) as String?
        else { return String(id) }
        return string.lowercased()
    }
}
