import FoundationModels
import Foundation

/// The on-device backstop for the launcher reminder fallback: when `ReminderPhraseParser` can't
/// find a time deterministically, the Apple Intelligence model extracts `{title, when, repeats}`
/// from arbitrary phrasing. Returns nil whenever the model is unavailable or its answer is unusable,
/// so the caller degrades to "couldn't find a time" rather than guessing.
enum ReminderPhraseModel {
    static func extract(_ text: String, now: Date, calendar: Calendar) async -> ParsedReminder? {
        guard AppleIntelligenceProvider.status().isAvailable else { return nil }
        let session = LanguageModelSession(instructions: instructions)
        let prompt =
            "The current date and time is \(anchorFormatter.string(from: now)). "
            + "Convert this reminder request into the fields: \"\(text)\""
        guard let extracted = try? await session.respond(
            to: prompt, generating: ExtractedReminder.self).content
        else { return nil }
        return reminder(from: extracted, now: now, calendar: calendar)
    }

    private static func reminder(
        from extracted: ExtractedReminder, now: Date, calendar: Calendar
    ) -> ParsedReminder? {
        let title = extracted.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let date = date(from: extracted.when) else { return nil }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 9, minute = parts.minute ?? 0
        switch extracted.repeats.lowercased() {
        case "daily":
            return ParsedReminder(title: title, rule: .daily(hour: hour, minute: minute))
        case "weekly":
            return ParsedReminder(
                title: title,
                rule: .weekly(
                    weekdays: [calendar.component(.weekday, from: date)], hour: hour, minute: minute))
        case "monthly":
            return ParsedReminder(
                title: title,
                rule: .monthly(day: calendar.component(.day, from: date), hour: hour, minute: minute))
        default:
            guard date > now else { return nil }
            return ParsedReminder(title: title, rule: .once(date))
        }
    }

    /// The model's `when` may or may not carry an offset or seconds, so several shapes are tried.
    private static func date(from text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for formatter in dateParsers {
            if let date = formatter.date(from: trimmed) { return date }
        }
        return nil
    }

    private static let instructions =
        "You turn a reminder request into structured fields. `title` is a concise imperative with "
        + "no time or date words. `when` is the first fire time as an ISO 8601 date-time in the "
        + "future, e.g. 2026-01-31T14:00:00. Set `repeats` to none unless the request explicitly "
        + "recurs; use daily, weekly or monthly only when it clearly repeats."

    private static let anchorFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZZZ (EEEE)"
        return formatter
    }()

    private static let dateParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
        ]
        return formats.map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            return formatter
        }
    }()
}

@Generable
private struct ExtractedReminder {
    @Guide(description: "A concise imperative title with no time or date words, e.g. Book the ticket")
    var title: String
    @Guide(description: "The first fire time as an ISO 8601 date-time in the future")
    var when: String
    @Guide(description: "How often it repeats", .anyOf(["none", "daily", "weekly", "monthly"]))
    var repeats: String
}
