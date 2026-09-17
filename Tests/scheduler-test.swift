// Pure scheduling math: next-fire and missed-occurrence resolution for every rule shape.
import Foundation

@main
@MainActor
struct SchedulerTests {
    static var failures = 0
    static var passes = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if condition() {
            passes += 1
        } else {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        onceFiresOnlyInTheFuture()
        intervalStepsFromTheAnchor()
        dailyCrossesMidnight()
        weeklyPicksTheRightWeekday()
        monthlyPicksTheDayOfMonth()
        dailySurvivesSpringForward()
        disabledTaskNeverFires()
        naturalDateParserParsesTomorrowAtNine()

        print("\(passes) passed, \(failures) failed")
        if failures > 0 { exit(1) }
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private static let nyCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static let baseCreatedAt = utcCalendar.date(
        from: DateComponents(year: 2025, month: 1, day: 15, hour: 10, minute: 0, second: 0))!

    private static func makeTask(
        rule: ScheduleRule, isEnabled: Bool = true, createdAt: Date, lastFired: Date? = nil,
        deleteAfterRun: Bool = false
    ) -> ScheduledTask {
        ScheduledTask(
            id: UUID(), name: "test task", isEnabled: isEnabled, rule: rule,
            action: .runScript(
                ScriptSpec(source: "echo hi", arguments: [], workingDirectory: nil, notifyOnFinish: false)),
            catchUp: .skip, deleteAfterRun: deleteAfterRun, lastFired: lastFired, createdAt: createdAt)
    }

    static func onceFiresOnlyInTheFuture() {
        let fireDate = baseCreatedAt.addingTimeInterval(3600)
        let task = makeTask(rule: .once(fireDate), createdAt: baseCreatedAt)

        expect(
            ScheduleEngine.nextFireDate(for: task, after: baseCreatedAt, calendar: utcCalendar) == fireDate,
            "once fires when `after` precedes the date")
        expect(
            ScheduleEngine.nextFireDate(for: task, after: fireDate, calendar: utcCalendar) == nil,
            "once never fires again once `after` reaches the date")
        expect(
            ScheduleEngine.nextFireDate(for: task, after: fireDate.addingTimeInterval(1), calendar: utcCalendar)
                == nil,
            "once never fires once `after` is past the date")

        expect(
            ScheduleEngine.missedOccurrences(
                for: task, since: baseCreatedAt, until: fireDate, calendar: utcCalendar, cap: 10) == [fireDate],
            "once is missed when the fire date falls inside (since, until]")
        expect(
            ScheduleEngine.missedOccurrences(
                for: task, since: fireDate, until: fireDate.addingTimeInterval(3600), calendar: utcCalendar,
                cap: 10
            ).isEmpty,
            "once is not missed once `since` reaches the fire date")
        expect(
            ScheduleEngine.missedOccurrences(
                for: task, since: baseCreatedAt.addingTimeInterval(-3600), until: baseCreatedAt,
                calendar: utcCalendar, cap: 10
            ).isEmpty,
            "once is not missed when the window ends before the fire date")
    }

    static func intervalStepsFromTheAnchor() {
        let seconds: TimeInterval = 900
        let task = makeTask(rule: .interval(seconds: seconds), createdAt: baseCreatedAt)

        expect(
            ScheduleEngine.nextFireDate(for: task, after: baseCreatedAt, calendar: utcCalendar)
                == baseCreatedAt.addingTimeInterval(seconds),
            "interval's first fire is one step past the anchor")
        expect(
            ScheduleEngine.nextFireDate(
                for: task, after: baseCreatedAt.addingTimeInterval(seconds * 2.5), calendar: utcCalendar)
                == baseCreatedAt.addingTimeInterval(seconds * 3),
            "interval always lands on the next whole step, not a fraction")
        expect(
            ScheduleEngine.nextFireDate(
                for: task, after: baseCreatedAt.addingTimeInterval(seconds * 3), calendar: utcCalendar)
                == baseCreatedAt.addingTimeInterval(seconds * 4),
            "landing exactly on a step still requires strictly-after")

        let missed = ScheduleEngine.missedOccurrences(
            for: task, since: baseCreatedAt, until: baseCreatedAt.addingTimeInterval(seconds * 10),
            calendar: utcCalendar, cap: 3)
        expect(
            missed == [
                baseCreatedAt.addingTimeInterval(seconds),
                baseCreatedAt.addingTimeInterval(seconds * 2),
                baseCreatedAt.addingTimeInterval(seconds * 3),
            ], "missed intervals coalesce to the cap, in order, from the earliest step")
    }

    static func dailyCrossesMidnight() {
        let createdAt = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 15, hour: 23, minute: 30))!
        let task = makeTask(rule: .daily(hour: 0, minute: 15), createdAt: createdAt)

        let expected = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 16, hour: 0, minute: 15))!
        let next = ScheduleEngine.nextFireDate(for: task, after: createdAt, calendar: utcCalendar)
        expect(next == expected, "daily rule crossing midnight fires the next calendar day at the configured time")

        let expectedFollowing = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 17, hour: 0, minute: 15))!
        let following = ScheduleEngine.nextFireDate(for: task, after: expected, calendar: utcCalendar)
        expect(following == expectedFollowing, "the day after that keeps firing at the same wall-clock time")
    }

    static func weeklyPicksTheRightWeekday() {
        // Jan 15 2025 is a Wednesday; the rule only fires Monday(2) and Friday(6).
        let createdAt = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 15, hour: 9, minute: 0))!
        let task = makeTask(rule: .weekly(weekdays: [2, 6], hour: 9, minute: 0), createdAt: createdAt)

        let firstFriday = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 17, hour: 9, minute: 0))!
        let next = ScheduleEngine.nextFireDate(for: task, after: createdAt, calendar: utcCalendar)
        expect(next == firstFriday, "weekly picks the nearer of the two configured weekdays")

        let nextMonday = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 20, hour: 9, minute: 0))!
        let afterFriday = ScheduleEngine.nextFireDate(for: task, after: firstFriday, calendar: utcCalendar)
        expect(afterFriday == nextMonday, "weekly rolls over to the other configured weekday the following week")
    }

    static func monthlyPicksTheDayOfMonth() {
        let createdAt = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 5, hour: 8, minute: 0))!
        let task = makeTask(rule: .monthly(day: 28, hour: 8, minute: 0), createdAt: createdAt)

        let expected = utcCalendar.date(
            from: DateComponents(year: 2025, month: 1, day: 28, hour: 8, minute: 0))!
        let next = ScheduleEngine.nextFireDate(for: task, after: createdAt, calendar: utcCalendar)
        expect(next == expected, "monthly fires on the configured day of the same month when it hasn't passed")

        let followingMonth = utcCalendar.date(
            from: DateComponents(year: 2025, month: 2, day: 28, hour: 8, minute: 0))!
        let afterFirst = ScheduleEngine.nextFireDate(for: task, after: expected, calendar: utcCalendar)
        expect(afterFirst == followingMonth, "monthly rolls to the next month once the day has passed")
    }

    /// US clocks spring forward on 2026-03-08; a naive +24h step would drift the wall-clock hour.
    static func dailySurvivesSpringForward() {
        let createdAt = nyCalendar.date(
            from: DateComponents(year: 2026, month: 3, day: 1, hour: 9, minute: 0))!
        let task = makeTask(rule: .daily(hour: 9, minute: 0), createdAt: createdAt)

        var cursor = createdAt
        var offsets: Set<Int> = []
        for _ in 0..<14 {
            guard let next = ScheduleEngine.nextFireDate(for: task, after: cursor, calendar: nyCalendar) else {
                expect(false, "daily recurrence must keep producing occurrences across the DST boundary")
                return
            }
            let components = nyCalendar.dateComponents([.hour, .minute], from: next)
            expect(
                components.hour == 9 && components.minute == 0,
                "daily rule keeps firing at 9:00 local time through DST")
            offsets.insert(nyCalendar.timeZone.secondsFromGMT(for: next))
            cursor = next
        }
        expect(
            offsets.count == 2,
            "the 14-day window crosses a UTC-offset change, proving this isn't fixed 24h arithmetic")
    }

    static func disabledTaskNeverFires() {
        let task = makeTask(rule: .interval(seconds: 60), isEnabled: false, createdAt: baseCreatedAt)
        expect(
            ScheduleEngine.nextFireDate(for: task, after: baseCreatedAt, calendar: utcCalendar) == nil,
            "a disabled task never produces a next fire date")
        expect(
            ScheduleEngine.missedOccurrences(
                for: task, since: baseCreatedAt, until: baseCreatedAt.addingTimeInterval(3600),
                calendar: utcCalendar, cap: 10
            ).isEmpty,
            "a disabled task never produces missed occurrences")
    }

    static func naturalDateParserParsesTomorrowAtNine() {
        let parsed = NaturalDateParser.date(from: "tomorrow at 9am", now: baseCreatedAt, calendar: utcCalendar)
        expect(parsed != nil, "natural language 'tomorrow at 9am' parses to a date")
    }
}
