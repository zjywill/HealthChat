import Foundation
import Testing

@testable import Vana

/// 会话列表的时间分段。边界全部按日历天算,所以测试固定一个时区和一个「现在」,
/// 不然半夜跑 CI 会红。
@Suite("Session time sections")
struct SessionTimeSectionTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// 2026-08-09 10:00 +08:00
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 10))!
    }

    private func date(_ month: Int, _ day: Int, _ hour: Int, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func section(_ date: Date) -> SessionTimeSection {
        SessionTimeSection.section(for: date, now: now, calendar: calendar)
    }

    @Test("today starts at midnight, not 24 hours ago")
    func todayIsACalendarDay() {
        // 今天凌晨一点属于「今天」,虽然它离现在只有 9 小时、离昨天同一时刻只有 24 小时。
        #expect(section(date(8, 9, 1)) == .today)
        #expect(section(date(8, 9, 10)) == .today)
        // 昨天晚上 11:59 是「昨天」,哪怕只过去了 10 小时。
        #expect(section(date(8, 8, 23)) == .yesterday)
    }

    @Test("a clock jump into the future stays visible at the top")
    func futureCountsAsToday() {
        #expect(section(date(9, 1, 10)) == .today)
    }

    @Test("the week bucket covers two to six days back")
    func weekBoundaries() {
        #expect(section(date(8, 7, 23)) == .lastWeek)   // 2 天前
        #expect(section(date(8, 3, 0)) == .lastWeek)    // 6 天前,当天零点
        #expect(section(date(8, 2, 23)) == .earlier)    // 7 天前,刚出界
        #expect(section(date(1, 1, 12)) == .earlier)
    }

    @Test("empty sections are dropped and order follows the input")
    func groupsSkipEmptySections() {
        let summaries = [
            summary(updatedAt: date(8, 9, 9), title: "今天"),
            summary(updatedAt: date(8, 9, 8), title: "今天早一点"),
            summary(updatedAt: date(3, 1, 8), title: "很久以前"),
        ]

        let groups = SessionTimeGroup.groups(from: summaries, now: now, calendar: calendar)

        #expect(groups.map(\.section) == [.today, .earlier])
        #expect(groups[0].summaries.map(\.title) == ["今天", "今天早一点"])
        #expect(groups[1].summaries.map(\.title) == ["很久以前"])
    }

    @Test("row labels carry the half the header doesn't")
    func rowLabelsComplementTheHeader() {
        // 段头说了「大概多久之前」,行里给的就得是精确的那一半。
        #expect(SessionTimeSection.today.timeLabel(for: date(8, 9, 9), now: now, calendar: calendar)
            .contains("9"))
        // 跨年的会话必须带上年份,否则「3月5日」是哪一年的全靠猜。
        let lastYear = SessionTimeSection.earlier.timeLabel(for: date(3, 5, 8, year: 2024), now: now, calendar: calendar)
        #expect(lastYear.contains("2024"))
        let thisYear = SessionTimeSection.earlier.timeLabel(for: date(3, 5, 8), now: now, calendar: calendar)
        #expect(!thisYear.contains("2026"))
    }

    private func summary(updatedAt: Date, title: String) -> SessionSummary {
        SessionSummary(title: title, updatedAt: updatedAt, messageCount: 1)
    }
}
