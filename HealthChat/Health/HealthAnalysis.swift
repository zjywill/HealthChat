import Foundation

/// 个人基线:拿 60 天的中位数当"平常"。
///
/// 中位数而不是均值——一次通宵、一次感冒不该改写什么叫正常。样本太少时干脆不给,
/// 报一个三天数据算出来的"基线"比不报更糟。
struct Baseline: Sendable, Equatable {
    let median: Double
    let sampleCount: Int

    init?(_ values: [Double], minimumSamples: Int = 10) {
        guard values.count >= minimumSamples else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        sampleCount = values.count
    }

    /// 相对基线的偏离百分比,正数表示高于平常。
    func deviation(of value: Double) -> Double? {
        guard median != 0 else { return nil }
        return (value - median) / median * 100
    }
}

/// 两组之间的一次比较。
///
/// 没有 p 值也没有相关系数:样本量这么小,报一个 r=0.31 只会显得比实际更确定。
/// 报的是"分成两组、各多少天、差多少"——这个用户自己能判断可不可信。
struct Comparison: Sendable {
    let label: String
    let withCondition: Double
    let withoutCondition: Double
    let withCount: Int
    let withoutCount: Int

    /// 两组都得有足够天数才值得说。
    init?(
        label: String,
        with: [Double],
        without: [Double],
        minimumPerGroup: Int = 3
    ) {
        guard with.count >= minimumPerGroup, without.count >= minimumPerGroup else { return nil }
        self.label = label
        withCondition = with.reduce(0, +) / Double(with.count)
        withoutCondition = without.reduce(0, +) / Double(without.count)
        withCount = with.count
        withoutCount = without.count
    }

    var difference: Double { withCondition - withoutCondition }
}

enum HealthAnalysis {
    /// 找几组成对关系。全部本地计算,不联网。
    ///
    /// 挑的都是用户真会问的因果方向:练了会不会影响睡眠、睡好了第二天心率会不会低。
    /// 相关不等于因果,输出里也这么写。
    static func comparisons(
        steps: [DayValue],
        nights: [NightSleep],
        hearts: [DayHeart],
        sessions: [WorkoutItem],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [Comparison] {
        var found: [Comparison] = []

        // 1. 有锻炼的那天晚上,睡得更长还是更短?
        let workoutDays = Set(sessions.map { calendar.startOfDay(for: $0.date) })
        let sleepAfterWorkout = nights.filter { workoutDays.contains(calendar.startOfDay(for: $0.night)) }
        let sleepOtherNights = nights.filter { !workoutDays.contains(calendar.startOfDay(for: $0.night)) }
        if let comparison = Comparison(
            label: "锻炼当晚的睡眠时长",
            with: sleepAfterWorkout.map { $0.asleep / 60 },
            without: sleepOtherNights.map { $0.asleep / 60 }
        ) {
            found.append(comparison)
        }

        // 2. 睡得多的那天,第二天静息心率更低吗?
        if let sleepBaseline = Baseline(nights.map(\.asleep), minimumSamples: 6) {
            let restingByDay = Dictionary(
                hearts.compactMap { day -> (Date, Double)? in
                    guard let resting = day.restingHR else { return nil }
                    return (calendar.startOfDay(for: day.date), resting)
                },
                uniquingKeysWith: { first, _ in first }
            )

            var afterLongSleep: [Double] = []
            var afterShortSleep: [Double] = []
            for night in nights {
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: night.night)),
                      let resting = restingByDay[nextDay] else { continue }
                if night.asleep >= sleepBaseline.median {
                    afterLongSleep.append(resting)
                } else {
                    afterShortSleep.append(resting)
                }
            }
            if let comparison = Comparison(
                label: "睡得比平常多之后的次日静息心率",
                with: afterLongSleep,
                without: afterShortSleep
            ) {
                found.append(comparison)
            }
        }

        // 3. 走得多的那天,HRV 更高吗?
        if let stepBaseline = Baseline(steps.map(\.value), minimumSamples: 6) {
            let hrvByDay = Dictionary(
                hearts.compactMap { day -> (Date, Double)? in
                    guard let hrv = day.hrv else { return nil }
                    return (calendar.startOfDay(for: day.date), hrv)
                },
                uniquingKeysWith: { first, _ in first }
            )

            var activeDays: [Double] = []
            var quietDays: [Double] = []
            for day in steps {
                guard let hrv = hrvByDay[calendar.startOfDay(for: day.date)] else { continue }
                if day.value >= stepBaseline.median {
                    activeDays.append(hrv)
                } else {
                    quietDays.append(hrv)
                }
            }
            if let comparison = Comparison(label: "走得比平常多的当天 HRV", with: activeDays, without: quietDays) {
                found.append(comparison)
            }
        }

        // 4. 睡得晚的时候,总时长会被压缩吗?
        let bedtimes = nights.compactMap { night -> (Double, Double)? in
            guard let bedtime = night.bedtime else { return nil }
            let parts = calendar.dateComponents([.hour, .minute], from: bedtime)
            guard let hour = parts.hour, let minute = parts.minute else { return nil }
            // 凌晨入睡记成 24 点之后,不然 00:30 会排在 22:00 前面。
            let minutes = Double(hour < 12 ? hour + 24 : hour) * 60 + Double(minute)
            return (minutes, night.asleep / 60)
        }
        if let bedtimeBaseline = Baseline(bedtimes.map(\.0), minimumSamples: 6) {
            if let comparison = Comparison(
                label: "入睡比平常晚时的睡眠时长",
                with: bedtimes.filter { $0.0 > bedtimeBaseline.median }.map(\.1),
                without: bedtimes.filter { $0.0 <= bedtimeBaseline.median }.map(\.1)
            ) {
                found.append(comparison)
            }
        }

        return found
    }
}
