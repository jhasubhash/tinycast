import Foundation

/// Free-text "when" parsing for one-shot tasks, e.g. "tomorrow at 9am".
enum NaturalDateParser {
    static func date(from text: String, now: Date, calendar: Calendar) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let detected = detector.firstMatch(in: text, options: [], range: range)?.date else {
            return nil
        }
        // NSDataDetector resolves "tomorrow" et al. against the live clock; re-anchor onto `now`.
        let driftDays = calendar.dateComponents([.day], from: Date(), to: now).day ?? 0
        return calendar.date(byAdding: .day, value: driftDays, to: detected)
    }
}
