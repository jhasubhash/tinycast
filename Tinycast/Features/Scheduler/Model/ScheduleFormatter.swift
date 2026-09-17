import Foundation

/// Human-readable one-liners for a task's schedule, shown as the row subtitle in Settings.
enum ScheduleFormatter {
    static func summary(of task: ScheduledTask) -> String {
        let action: String
        switch task.action {
        case .runScript: action = "Run script"
        case .postNotification: action = "Notify"
        }
        return "\(action) · \(rule(task.rule))"
    }

    static func rule(_ rule: ScheduleRule) -> String {
        switch rule {
        case .once(let date):
            return "Once, \(dateTime.string(from: date))"
        case .interval(let seconds):
            return "Every \(interval(seconds))"
        case .daily(let hour, let minute):
            return "Daily at \(clock(hour, minute))"
        case .weekly(let weekdays, let hour, let minute):
            return "\(weekdayList(weekdays)) at \(clock(hour, minute))"
        case .monthly(let day, let hour, let minute):
            return "Monthly on the \(ordinal(day)) at \(clock(hour, minute))"
        }
    }

    private static func interval(_ seconds: TimeInterval) -> String {
        let units: [(TimeInterval, String)] = [(86_400, "day"), (3_600, "hour"), (60, "minute")]
        for (size, name) in units where seconds >= size && seconds.truncatingRemainder(dividingBy: size) == 0 {
            let count = Int(seconds / size)
            return count == 1 ? name : "\(count) \(name)s"
        }
        let count = max(1, Int(seconds))
        return count == 1 ? "second" : "\(count) seconds"
    }

    private static func clock(_ hour: Int, _ minute: Int) -> String {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        guard let date = Calendar.current.date(from: components) else {
            return String(format: "%02d:%02d", hour, minute)
        }
        return timeOnly.string(from: date)
    }

    private static func weekdayList(_ weekdays: Set<Int>) -> String {
        let symbols = Calendar.current.shortWeekdaySymbols
        let names = weekdays.sorted().compactMap { day -> String? in
            let index = day - 1
            return symbols.indices.contains(index) ? symbols[index] : nil
        }
        return names.isEmpty ? "Weekly" : names.joined(separator: ", ")
    }

    private static func ordinal(_ day: Int) -> String {
        ordinalFormatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    private static let timeOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    private static let dateTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .medium
        return formatter
    }()

    private static let ordinalFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter
    }()
}
