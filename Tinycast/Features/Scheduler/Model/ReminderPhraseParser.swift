import Foundation

/// One reminder lifted from a free-text phrase: what to call it, and when it fires.
struct ParsedReminder: Equatable, Sendable {
    var title: String
    var rule: ScheduleRule
}

/// Turns a launcher phrase like "remind me to book the ticket in 20 min" into a notification task.
/// A recurrence word is read and removed first, then the time span (`NaturalDateParser`), and the
/// words left over become the title. Foundation-only: the clock and calendar are injected, so the
/// harness pins every shape.
enum ReminderPhraseParser {
    static func parse(_ text: String, now: Date, calendar: Calendar) -> ParsedReminder? {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        let recurrence = Recurrence.detect(in: remainder)
        if let recurrence { remainder = remainder.replacingCharacters(in: recurrence.range, with: " ") }

        let time = NaturalDateParser.match(in: remainder, now: now, calendar: calendar)
        if let time { remainder = remainder.replacingCharacters(in: time.range, with: " ") }

        let title = cleanTitle(remainder)
        guard !title.isEmpty else { return nil }

        let rule: ScheduleRule
        if let recurrence {
            let clock = time.map { Self.clock($0.date, calendar) } ?? Recurrence.defaultClock
            rule = recurrence.rule(hour: clock.hour, minute: clock.minute, now: now, calendar: calendar)
        } else {
            // A one-shot with no future time is not a reminder; let the caller try its model.
            guard let time, time.date > now else { return nil }
            rule = .once(time.date)
        }
        return ParsedReminder(title: title, rule: rule)
    }

    /// True when a phrase reads as a reminder request, before any time is typed, so the launcher can
    /// float scheduling to the top. Keyword intent only — the full parse decides whether it fires.
    static func signalsIntent(in text: String) -> Bool {
        let lower = text.lowercased()
        return intentMarkers.contains { lower.contains($0) }
    }

    private static let intentMarkers = [
        "remind", "reminder", "notify me", "notification", "alert me",
        "ping me", "wake me", "nudge me", "don't let me forget", "dont let me forget",
    ]

    private static func clock(_ date: Date, _ calendar: Calendar) -> (hour: Int, minute: Int) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? Recurrence.defaultClock.hour, parts.minute ?? Recurrence.defaultClock.minute)
    }

    /// Strips the command framing ("remind me to") and the prepositions the time left dangling
    /// ("standup at "), then sentence-cases what remains.
    private static func cleanTitle(_ text: String) -> String {
        var result = text
        while true {
            let trimmed = trimEnds(result)
            guard let stripped = stripLeadingFiller(trimmed), stripped != result else {
                result = trimmed
                break
            }
            result = stripped
        }
        result = stripTrailingConnectors(trimEnds(result))
        guard let first = result.first else { return "" }
        return first.uppercased() + result.dropFirst()
    }

    private static func trimEnds(_ text: String) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t,.;:-–—"))
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private static func stripLeadingFiller(_ text: String) -> String? {
        let lower = text.lowercased()
        for phrase in fillerPrefixes where lower == phrase || lower.hasPrefix(phrase + " ") {
            return String(text.dropFirst(phrase.count))
        }
        return text
    }

    private static func stripTrailingConnectors(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        while let last = words.last, trailingConnectors.contains(last.lowercased()) {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    private static let fillerPrefixes = [
        "remind me to", "remind me that", "remind me", "reminder to", "remember to",
        "remember that", "remember", "remind to", "ping me to", "ping me", "i need to",
        "i want to", "i have to", "note to self to", "note to self", "note to", "make a note to",
        "set a reminder to", "set a reminder", "schedule a reminder to", "create a reminder to",
        "to", "that",
    ]

    private static let trailingConnectors: Set<String> = [
        "at", "on", "by", "for", "to", "in", "this", "next", "the", "every", "each", "of",
    ]
}

/// A recurrence word found in a phrase, with the span to remove so it never lands in the title.
private struct Recurrence {
    enum Kind {
        case daily
        case weekly(Set<Int>)
        case monthly
    }

    let kind: Kind
    let range: Range<String.Index>

    static let defaultClock = (hour: 9, minute: 0)

    func rule(hour: Int, minute: Int, now: Date, calendar: Calendar) -> ScheduleRule {
        switch kind {
        case .daily:
            return .daily(hour: hour, minute: minute)
        case .weekly(let days):
            let weekdays = days.isEmpty ? [calendar.component(.weekday, from: now)] : days
            return .weekly(weekdays: weekdays, hour: hour, minute: minute)
        case .monthly:
            return .monthly(day: calendar.component(.day, from: now), hour: hour, minute: minute)
        }
    }

    /// Checked most specific first, so "every weekday" never reads as the daily "every … day".
    static func detect(in text: String) -> Recurrence? {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        for (expression, kind) in patterns {
            guard let result = expression.firstMatch(in: text, options: [], range: full),
                let range = Range(result.range, in: text)
            else { continue }
            if case .specificWeekday = kind {
                guard let dayRange = Range(result.range(at: 1), in: text),
                    let weekday = weekday(for: String(text[dayRange]))
                else { continue }
                return Recurrence(kind: .weekly([weekday]), range: range)
            }
            return Recurrence(kind: kind.rule, range: range)
        }
        return nil
    }

    private enum PatternKind {
        case fixed(Kind)
        case specificWeekday

        var rule: Kind {
            if case .fixed(let kind) = self { return kind }
            return .weekly([])
        }
    }

    private static func weekday(for token: String) -> Int? {
        let key = String(token.lowercased().prefix(3))
        return weekdays[key]
    }

    private static let weekdays: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7,
    ]

    private static let patterns: [(NSRegularExpression, PatternKind)] = {
        let specs: [(String, PatternKind)] = [
            (#"\b(?:every\s+weekend|on\s+weekends?|weekends?)\b"#, .fixed(.weekly([1, 7]))),
            (#"\b(?:every\s+weekday|on\s+weekdays?|weekdays?)\b"#, .fixed(.weekly([2, 3, 4, 5, 6]))),
            (#"\b(?:every|on|each)\s+(mon|tue|wed|thu|fri|sat|sun)[a-z]*s?\b"#, .specificWeekday),
            (#"\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*s\b"#, .specificWeekday),
            (
                #"\b(?:every\s*day|everyday|daily|each\s+day|every\s+(?:morning|night|evening|afternoon))\b"#,
                .fixed(.daily)
            ),
            (#"\b(?:every\s+week|weekly)\b"#, .fixed(.weekly([]))),
            (#"\b(?:every\s+month|monthly)\b"#, .fixed(.monthly)),
        ]
        return specs.compactMap { pattern, kind in
            (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])).map { ($0, kind) }
        }
    }()
}
