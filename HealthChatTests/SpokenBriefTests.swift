import Foundation
import Testing

@testable import HealthChat

/// Siri 念的那一两句。
///
/// 时间边界("昨晚"是几天前)和比较方向(比平均多还是少)是这里唯一会错的两件事,所以
/// 时区和"现在"全部固定住——不然半夜跑一次就红一次。
@Suite("Spoken brief")
struct SpokenBriefTests {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return calendar
    }

    /// 2026-08-09 08:00,周日早上。
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: 9, hour: 8))!
    }

    private func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(
            from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute)
        )!
    }

    // MARK: - 今天

    @Test("活动量和最值得说的那个触发点各占一句")
    func todayCombinesActivityAndHeadline() {
        let line = SpokenBrief.todayLine(
            activity: DayActivity(date: now, steps: 6240, exerciseMinutes: 32),
            situation: HealthSituation(
                period: .morning,
                triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)]
            )
        )

        #expect(line == "今天走了 6240 步，运动 32 分钟。昨晚只睡了 5.4 小时，比最近常态少 92 分钟。")
    }

    /// 走得多这条已经在活动量那句里说过了。让它再当一次 headline 就是复读。
    @Test("今天步数相关的触发点不会被念第二遍")
    func todayDoesNotRepeatStepTriggers() {
        let line = SpokenBrief.todayLine(
            activity: DayActivity(date: now, steps: 15_200),
            situation: HealthSituation(
                period: .evening,
                triggers: [.bigActivityDay(steps: 15_200), .suppressedHRV(dropPercent: 18)]
            )
        )

        #expect(line == "今天走了 15200 步，明显多于平常。HRV 比最近基线低约 18%。")
    }

    @Test("一个触发点都没有时说各项正常，而不是沉默")
    func todayWithoutTriggers() {
        let line = SpokenBrief.todayLine(
            activity: DayActivity(date: now, steps: 8000),
            situation: HealthSituation(period: .afternoon, triggers: [])
        )

        #expect(line == "今天走了 8000 步。其他几项都在最近的常态范围里。")
    }

    // MARK: - 睡眠

    @Test("昨晚的时长、上下床时间和与最近几晚的差")
    func sleepReportsDeltaAgainstEarlierNights() {
        // night 记的是上床那天:8 月 8 日晚 = "昨晚"。
        let nights = [
            night(day: 4, asleep: 7 * 3600),
            night(day: 5, asleep: 7 * 3600),
            night(day: 6, asleep: 7 * 3600),
            night(day: 7, asleep: 7 * 3600),
            night(day: 8, asleep: 6 * 3600 + 12 * 60, bedHour: 23, bedMinute: 40, wakeHour: 6)
        ]

        let line = SpokenBrief.sleepLine(nights: nights, now: now, calendar: calendar)

        #expect(line == "昨晚睡了 6 小时 12 分，23 点 40 分 睡的，6 点 醒。比最近几晚平均少 48 分钟。")
    }

    /// 最近一次记录是三天前——那就不是"昨晚睡了多少",而是"昨晚没记录"。
    @Test("最近一条不是昨晚时，直说昨晚没有记录")
    func sleepFallsBackWhenLastNightIsMissing() {
        let line = SpokenBrief.sleepLine(
            nights: [night(day: 5, asleep: 7 * 3600 + 30 * 60)],
            now: now,
            calendar: calendar
        )

        #expect(line == "昨晚没有睡眠记录，多半是没戴设备。最近一次是 8 月 5 日那晚，睡了 7 小时 30 分。")
    }

    @Test("基线样本不够就只报事实，不硬算一个平均")
    func sleepSkipsComparisonWithoutBaseline() {
        let line = SpokenBrief.sleepLine(
            nights: [night(day: 7, asleep: 7 * 3600), night(day: 8, asleep: 6 * 3600)],
            now: now,
            calendar: calendar
        )

        #expect(line == "昨晚睡了 6 小时。")
    }

    @Test("一条记录都没有")
    func sleepWithoutAnyRecord() {
        #expect(SpokenBrief.sleepLine(nights: [], now: now, calendar: calendar) == "最近两周都没有睡眠记录。")
    }

    // MARK: - 训练

    @Test("最近那次训练的细节，加同类对比")
    func workoutComparesAgainstSameType() {
        let sessions = [
            run(day: 9, hour: 6, minutes: 42, distance: 7.2, heartRate: 152, energy: 410),
            run(day: 7, hour: 7, minutes: 30),
            run(day: 5, hour: 7, minutes: 30),
            run(day: 3, hour: 7, minutes: 30)
        ]

        let line = SpokenBrief.workoutLine(sessions: sessions, now: now)

        #expect(line == "1 小时前那次跑步，练了 42 分钟，7.2 公里，平均心率 152，消耗 410 千卡。"
            + "比最近两周同类训练的平均时长长 12 分钟。")
    }

    /// 拿一次跑步去比几次瑜伽,"比平常长 20 分钟"是句没有意义的话。
    @Test("同类样本不够就不做对比")
    func workoutSkipsComparisonWithoutPeers() {
        let sessions = [
            run(day: 9, hour: 6, minutes: 42),
            yoga(day: 7), yoga(day: 5), yoga(day: 3)
        ]

        #expect(SpokenBrief.workoutLine(sessions: sessions, now: now) == "1 小时前那次跑步，练了 42 分钟。")
    }

    @Test("一次都没练")
    func workoutWithoutAnyRecord() {
        #expect(SpokenBrief.workoutLine(sessions: [], now: now) == "最近两周没有锻炼记录。")
    }

    // MARK: - 造数据

    private func night(
        day: Int,
        asleep: TimeInterval,
        bedHour: Int? = nil,
        bedMinute: Int = 0,
        wakeHour: Int? = nil
    ) -> NightSleep {
        NightSleep(
            night: date(day),
            asleep: asleep,
            bedtime: bedHour.map { date(day, $0, bedMinute) },
            // 起床是第二天早上。
            wake: wakeHour.map { date(day + 1, $0) }
        )
    }

    private func run(
        day: Int,
        hour: Int,
        minutes: Int,
        distance: Double? = nil,
        heartRate: Double? = nil,
        energy: Double? = nil
    ) -> WorkoutItem {
        WorkoutItem(
            date: date(day, hour),
            typeName: "跑步",
            duration: TimeInterval(minutes * 60),
            activeEnergy: energy,
            distance: distance,
            averageHeartRate: heartRate
        )
    }

    private func yoga(day: Int) -> WorkoutItem {
        WorkoutItem(date: date(day, 7), typeName: "瑜伽", duration: 20 * 60, activeEnergy: nil)
    }
}
