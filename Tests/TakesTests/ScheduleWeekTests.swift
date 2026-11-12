import Foundation
import Testing
@testable import Takes

// 2026-11-03: the Schedule panel shows one week, a dot on busy days, and three natural times.

struct ScheduleWeekTests {
    let la = TimeZone(identifier: "America/Los_Angeles")!

    private func date(_ s: String) -> Date {
        let f = ISO8601DateFormatter()
        f.timeZone = la
        f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        return f.date(from: s)!
    }

    @Test func aWeekStartsOnSunday() {
        let days = ScheduleWeek.days(of: date("2026-11-04T08:07:00"), in: la)
        #expect(days.count == 7)
        #expect(ScheduleWeek.key(days[0], in: la) == "2026-11-01")
        #expect(ScheduleWeek.key(days[6], in: la) == "2026-11-07")
        #expect(ScheduleWeek.weekday(days[3], in: la) == "Wed")
    }

    @Test func aTimeIsOneOfTheSlotsOrOther() {
        let d = date("2026-11-04T12:13:00")
        #expect(ScheduleWeek.slot(of: d, in: la) == 1)
        #expect(ScheduleWeek.slot(of: date("2026-11-04T09:00:00"), in: la) == nil)
        let moved = ScheduleWeek.at(d, hour: 17, minute: 41, in: la)
        #expect(ScheduleWeek.key(moved, in: la) == "2026-11-04")
        #expect(ScheduleWeek.slot(of: moved, in: la) == 2)
    }

    @Test func busyDaysAreInThePostsZone() {
        // 11 PM on Wed in LA is Thursday in UTC: the dot goes on Wednesday.
        let busy = ScheduleWeek.busy([date("2026-11-04T23:30:00")], in: la)
        #expect(busy == ["2026-11-04"])
    }

    @Test func theTitleNamesTheWeek() {
        let now = date("2026-11-03T15:00:00")
        let this = ScheduleWeek.days(of: now, in: la)[0]
        #expect(ScheduleWeek.title(this, in: la, now: now) == "This week")
        let next = ScheduleWeek.days(of: date("2026-11-10T08:00:00"), in: la)[0]
        #expect(ScheduleWeek.title(next, in: la, now: now) == "Next week")
        let later = ScheduleWeek.days(of: date("2026-11-25T08:00:00"), in: la)[0]
        #expect(ScheduleWeek.title(later, in: la, now: now) == "Nov 22 – 28")
        #expect(ScheduleWeek.isPast(date("2026-11-02T08:00:00"), in: la, now: now))
        #expect(!ScheduleWeek.isPast(date("2026-11-03T08:00:00"), in: la, now: now))
    }

    @Test func theClockReadsNaturally() {
        #expect(ScheduleWeek.clock(8, 7) == "8:07 AM")
        #expect(ScheduleWeek.clock(12, 13) == "12:13 PM")
        #expect(ScheduleWeek.clock(17, 41) == "5:41 PM")
    }
}
