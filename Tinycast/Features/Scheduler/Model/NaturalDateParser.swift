import Foundation

/// Free-text "when" parsing for one-shot tasks. Absolute phrases ("tomorrow at 9am") come from
/// `NSDataDetector`; relative durations ("in 20 minutes") are its blind spot, so they are matched
/// first. Each hit carries the span it matched, so a caller can lift the time out of a longer
/// sentence and keep the rest as a title.
enum NaturalDateParser {
    struct Match {
        let date: Date
        let range: Range<String.Index>
    }

    static func date(from text: String, now: Date, calendar: Calendar) -> Date? {
        match(in: text, now: now, calendar: calendar)?.date
    }

    /// Relative first — `NSDataDetector` resolves none of the "in N units" forms — then absolute.
    static func match(in text: String, now: Date, calendar: Calendar) -> Match? {
        relativeMatch(in: text, now: now, calendar: calendar)
            ?? absoluteMatch(in: text, now: now, calendar: calendar)
    }

    private static func relativeMatch(in text: String, now: Date, calendar: Calendar) -> Match? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for expression in relativeExpressions {
            guard let result = expression.firstMatch(in: text, options: [], range: full),
                let range = Range(result.range, in: text),
                let countRange = Range(result.range(at: 1), in: text),
                let unitRange = Range(result.range(at: 2), in: text),
                let amount = number(String(text[countRange])),
                let component = component(for: String(text[unitRange])),
                let date = calendar.date(byAdding: component, value: amount, to: now)
            else { continue }
            return Match(date: date, range: range)
        }
        return nil
    }

    private static func absoluteMatch(in text: String, now: Date, calendar: Calendar) -> Match? {
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue)
        else { return nil }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let result = detector.firstMatch(in: text, options: [], range: full),
            let detected = result.date, let range = Range(result.range, in: text)
        else { return nil }
        // NSDataDetector resolves "tomorrow" et al. against the live clock; re-anchor onto `now`.
        let driftDays = calendar.dateComponents([.day], from: Date(), to: now).day ?? 0
        let anchored = calendar.date(byAdding: .day, value: driftDays, to: detected) ?? detected
        return Match(date: anchored, range: range)
    }

    private static func number(_ token: String) -> Int? {
        if let value = Int(token) { return value }
        return words[token.lowercased()]
    }

    private static func component(for unit: String) -> Calendar.Component? {
        switch unit.lowercased() {
        case let u where u.hasPrefix("sec"): return .second
        case let u where u.hasPrefix("min"): return .minute
        case let u where u.hasPrefix("hr") || u.hasPrefix("hour"): return .hour
        case let u where u.hasPrefix("day"): return .day
        case let u where u.hasPrefix("week"): return .weekOfYear
        case let u where u.hasPrefix("month"): return .month
        default: return nil
        }
    }

    private static let words: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// Group 1 is the count (digits or a number word), group 2 the unit; both spellings covered.
    private static let relativeExpressions: [NSRegularExpression] = {
        let count = #"(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten)"#
        let unit = #"(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?|weeks?|months?)"#
        let patterns = [
            #"\b(?:in|after|within)\s+(?:the\s+)?(?:next\s+)?"# + count + #"\s*"# + unit + #"\b"#,
            #"\b"# + count + #"\s*"# + unit + #"\s+(?:from\s+now|later)\b"#,
        ]
        return patterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }()
}
