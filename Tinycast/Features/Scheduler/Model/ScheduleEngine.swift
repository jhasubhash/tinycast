import Foundation

/// Turns a `ScheduledTask` rule into concrete fire dates. Every date in, every date out — no clock reads.
enum ScheduleEngine {
    static func nextFireDate(for task: ScheduledTask, after: Date, calendar: Calendar) -> Date? {
        guard task.isEnabled else { return nil }
        switch task.rule {
        case .once(let date):
            return date > after ? date : nil
        case .interval(let seconds):
            guard seconds > 0 else { return nil }
            let anchor = task.lastFired ?? task.createdAt
            let step = stepIndex(strictlyAfter: after, anchor: anchor, seconds: seconds)
            return anchor.addingTimeInterval(step * seconds)
        case .daily, .weekly, .monthly:
            guard let rule = recurrenceRule(for: task.rule, calendar: calendar) else { return nil }
            let anchor = task.lastFired ?? task.createdAt
            return rule.recurrences(of: anchor).first { $0 > after }
        }
    }

    static func missedOccurrences(
        for task: ScheduledTask, since: Date, until: Date, calendar: Calendar, cap: Int
    ) -> [Date] {
        guard task.isEnabled, cap > 0, since < until else { return [] }
        switch task.rule {
        case .once(let date):
            return since < date && date <= until ? [date] : []
        case .interval(let seconds):
            guard seconds > 0 else { return [] }
            let anchor = task.lastFired ?? task.createdAt
            var step = stepIndex(strictlyAfter: since, anchor: anchor, seconds: seconds)
            var result: [Date] = []
            while result.count < cap {
                let date = anchor.addingTimeInterval(step * seconds)
                if date > until { break }
                result.append(date)
                step += 1
            }
            return result
        case .daily, .weekly, .monthly:
            guard let rule = recurrenceRule(for: task.rule, calendar: calendar) else { return [] }
            let anchor = task.lastFired ?? task.createdAt
            var result: [Date] = []
            for date in rule.recurrences(of: anchor) {
                if date > until { break }
                if date > since { result.append(date) }
                if result.count >= cap { break }
            }
            return result
        }
    }

    /// The multiple of `seconds` from `anchor` (may be negative) that lands strictly after `date`.
    private static func stepIndex(strictlyAfter date: Date, anchor: Date, seconds: TimeInterval) -> Double {
        let elapsed = date.timeIntervalSince(anchor)
        return (elapsed / seconds).rounded(.down) + 1
    }

    private static func recurrenceRule(for rule: ScheduleRule, calendar: Calendar) -> Calendar.RecurrenceRule? {
        switch rule {
        case .once, .interval:
            return nil
        case .daily(let hour, let minute):
            return Calendar.RecurrenceRule(
                calendar: calendar, frequency: .daily, hours: [hour], minutes: [minute], seconds: [0])
        case .weekly(let weekdays, let hour, let minute):
            let days = weekdays.sorted().compactMap(localeWeekday).map(Calendar.RecurrenceRule.Weekday.every)
            guard !days.isEmpty else { return nil }
            return Calendar.RecurrenceRule(
                calendar: calendar, frequency: .weekly, weekdays: days, hours: [hour], minutes: [minute],
                seconds: [0])
        case .monthly(let day, let hour, let minute):
            return Calendar.RecurrenceRule(
                calendar: calendar, frequency: .monthly, daysOfTheMonth: [day], hours: [hour],
                minutes: [minute], seconds: [0])
        }
    }

    /// Calendar weekday integers run 1 (Sunday) … 7 (Saturday), matching `DateComponents.weekday`.
    private static func localeWeekday(_ calendarWeekday: Int) -> Locale.Weekday? {
        switch calendarWeekday {
        case 1: return .sunday
        case 2: return .monday
        case 3: return .tuesday
        case 4: return .wednesday
        case 5: return .thursday
        case 6: return .friday
        case 7: return .saturday
        default: return nil
        }
    }
}
