import Foundation

/// 此刻的几个关键读数——**「现在是多少」**。
///
/// 和 `HealthTrigger` 是一对:触发点回答「有什么变了」,现状回答「现在是多少」。首屏原来
/// 只说前者,于是数据平稳的那几天(多数人多数时候)用户读到的是一句「没读到值得特别留意的
/// 波动」——一个数字都没有,他反而不知道自己现在怎么样。**没有波动不等于没有现状。**
///
/// 材料是白拿的:`HealthSituation.detect()` 本来就把这五项查了一遍,判完触发点就扔了。
/// 所以这里不加任何一次 HealthKit 查询,只是把已经在手里的东西留下来。
struct HealthVitals: Sendable, Equatable {
    /// 固定顺序:睡眠、活动、心率、HRV、锻炼、体重。读不到的那几项也留在里面(带上
    /// 「没有记录」),详情页要说清楚是**没有**还是**没读到**——空着一行等于让用户去猜。
    var items: [VitalItem] = []

    static let empty = HealthVitals()

    /// 真的有读数的那几项。写进句子和喂给模型的都只有它们。
    var measured: [VitalItem] { items.filter { $0.value != nil } }

    var isEmpty: Bool { measured.isEmpty }
}

/// 现状里的一项。
struct VitalItem: Sendable, Equatable, Identifiable {
    enum Kind: String, Sendable {
        case sleep, steps, restingHR, hrv, workout, weight
    }

    let kind: Kind
    /// 「昨晚睡眠」
    let title: String
    let icon: String
    /// 「7.2 小时」。nil 表示这一项没读到——那不是 0,两者在健康数据里差得很远。
    let value: String?
    /// 和最近常态的对比,或者没读到时的说明。
    let note: String?

    var id: String { kind.rawValue }

    /// 写进一句话里的说法:「昨晚睡了 7.2 小时」。
    ///
    /// 和 `title` + `value` 分开,是因为卡片上那句话是**说给人听的**,而列表里那两栏是
    /// 对齐着看的。硬把「昨晚睡眠 7.2 小时」拼进句子里,读起来像报表。
    var phrase: String? {
        guard let value else { return nil }
        switch kind {
        case .sleep: return String(localized: "昨晚睡了 \(value)")
        case .steps: return String(localized: "今天走了 \(value)")
        case .restingHR: return String(localized: "静息心率 \(value)")
        case .hrv: return "HRV \(value)"
        case .workout: return String(localized: "最近一次锻炼是\(value)")
        case .weight: return String(localized: "体重 \(value)")
        }
    }

    /// 喂给模型的那一行。带上对比,它才写得出「在常态里」还是「偏低」。
    var brief: String? {
        guard let value else { return nil }
        guard let note else { return "\(title)：\(value)" }
        return "\(title)：\(value)（\(note)）"
    }
}

extension HealthVitals {
    /// 从 `detect()` 已经查回来的那五份数据里读出现状。
    ///
    /// 纯函数,`now` / `calendar` 从外面传——「昨晚」是几号、「今天」是哪一天,这两件事
    /// 在测试里必须钉得住。
    static func read(
        steps: [DayValue],
        nights: [NightSleep],
        hearts: [DayHeart],
        sessions: [WorkoutItem],
        body: [DayBody],
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> HealthVitals {
        HealthVitals(items: [
            sleepItem(nights, now: now, calendar: calendar),
            stepsItem(steps, now: now, calendar: calendar),
            restingItem(hearts),
            hrvItem(hearts),
            workoutItem(sessions, now: now, calendar: calendar),
            weightItem(body, calendar: calendar)
        ])
    }

    // MARK: - 各项

    private static func sleepItem(
        _ nights: [NightSleep],
        now: Date,
        calendar: Calendar
    ) -> VitalItem {
        let sorted = nights.sorted { $0.night < $1.night }
        // 得是「昨晚」才算数。三天前那条说明中间断了,拿它当现状就是在报一个过期的数。
        guard let last = sorted.last,
              let nightsAgo = calendar.dateComponents(
                [.day],
                from: calendar.startOfDay(for: last.night),
                to: calendar.startOfDay(for: now)
              ).day,
              nightsAgo <= 1
        else {
            return VitalItem(
                kind: .sleep,
                title: String(localized: "昨晚睡眠"),
                icon: "moon.zzz",
                value: nil,
                note: String(localized: "昨晚没有记录")
            )
        }

        let hours = last.asleep / 3600
        let baseline = sorted.dropLast().map(\.asleep)
        var note: String?
        if !baseline.isEmpty {
            let average = baseline.reduce(0, +) / Double(baseline.count)
            note = comparison(
                delta: Int((last.asleep - average) / 60),
                unit: String(localized: "分钟"),
                tolerance: 15,
                reference: String(localized: "最近 \(baseline.count) 晚平均")
            )
        }
        return VitalItem(
            kind: .sleep,
            title: String(localized: "昨晚睡眠"),
            icon: "moon.zzz",
            value: String(localized: "\(hours.oneDecimal) 小时"),
            note: note
        )
    }

    private static func stepsItem(
        _ days: [DayValue],
        now: Date,
        calendar: Calendar
    ) -> VitalItem {
        let today = days.last { calendar.isDate($0.date, inSameDayAs: now) }
        let history = days.filter { !calendar.isDate($0.date, inSameDayAs: now) }
        // 今天 0 步 **且**这两周一步没有,说明的不是他没动,是这台设备根本没在记步。
        // 「0 步（最近平常 0 步）」是一行纯噪声,而"今天 0 步"在有基线时是真的有话要说
        // (`.noStepsToday` 就是那条)。
        let hasAnySteps = days.contains { $0.value > 0 }
        guard let today, hasAnySteps else {
            return VitalItem(
                kind: .steps,
                title: String(localized: "今天步数"),
                icon: "figure.walk",
                value: nil,
                note: hasAnySteps ? String(localized: "今天还没有记录") : String(localized: "最近没有记录")
            )
        }

        var note: String?
        if history.contains(where: { $0.value > 0 }) {
            let average = Int(history.map(\.value).reduce(0, +) / Double(history.count))
            // 步数是**攒了一天的量**,不是一个瞬时值。上午八点走了两千步远低于日均,那是
            // 时间还早,不是他今天动得少——所以只报平常是多少,不替它下"偏少"的判断。
            note = String(localized: "最近平常 \(average.grouped) 步")
        }
        return VitalItem(
            kind: .steps,
            title: String(localized: "今天步数"),
            icon: "figure.walk",
            value: String(localized: "\(Int(today.value).grouped) 步"),
            note: note
        )
    }

    private static func restingItem(_ days: [DayHeart]) -> VitalItem {
        let resting = days.sorted { $0.date < $1.date }.compactMap(\.restingHR)
        guard let latest = resting.last else {
            return VitalItem(
                kind: .restingHR,
                title: String(localized: "静息心率"),
                icon: "heart",
                value: nil,
                note: String(localized: "最近没有记录")
            )
        }
        var note: String?
        let baseline = resting.dropLast()
        if baseline.count >= 3 {
            let average = baseline.reduce(0, +) / Double(baseline.count)
            note = comparison(
                delta: Int(latest - average),
                unit: String(localized: "次"),
                tolerance: 2,
                reference: String(localized: "最近基线 \(Int(average))")
            )
        }
        return VitalItem(
            kind: .restingHR,
            title: String(localized: "静息心率"),
            icon: "heart",
            value: String(localized: "\(Int(latest)) 次/分"),
            note: note
        )
    }

    private static func hrvItem(_ days: [DayHeart]) -> VitalItem {
        let hrv = days.sorted { $0.date < $1.date }.compactMap(\.hrv)
        guard let latest = hrv.last else {
            return VitalItem(
                kind: .hrv,
                title: "HRV",
                icon: "waveform.path.ecg",
                value: nil,
                note: String(localized: "最近没有记录")
            )
        }
        var note: String?
        let baseline = hrv.dropLast()
        if baseline.count >= 3 {
            let average = baseline.reduce(0, +) / Double(baseline.count)
            note = comparison(
                delta: Int(latest - average),
                unit: "ms",
                tolerance: 3,
                reference: String(localized: "最近基线 \(Int(average))")
            )
        }
        return VitalItem(
            kind: .hrv,
            title: "HRV",
            icon: "waveform.path.ecg",
            value: "\(Int(latest)) ms",
            note: note
        )
    }

    private static func workoutItem(
        _ sessions: [WorkoutItem],
        now: Date,
        calendar: Calendar
    ) -> VitalItem {
        guard let latest = sessions.max(by: { $0.date < $1.date }) else {
            return VitalItem(
                kind: .workout,
                title: String(localized: "最近一次锻炼"),
                icon: "flame",
                value: nil,
                note: String(localized: "最近两周没有记录")
            )
        }
        let ended = latest.date.addingTimeInterval(latest.duration)
        let minutes = max(Int(latest.duration / 60), 1)
        let days = calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: ended),
            to: calendar.startOfDay(for: now)
        ).day ?? 0
        let when: String
        switch days {
        case ..<1: when = String(localized: "今天")
        case 1: when = String(localized: "昨天")
        default: when = String(localized: "\(days) 天前")
        }
        return VitalItem(
            kind: .workout,
            title: String(localized: "最近一次锻炼"),
            icon: "flame",
            value: String(localized: "\(when)的\(latest.typeName) \(minutes) 分钟"),
            note: String(localized: "最近两周 \(sessions.count) 次")
        )
    }

    private static func weightItem(_ days: [DayBody], calendar: Calendar) -> VitalItem {
        let weights = days.sorted { $0.date < $1.date }.compactMap { day -> (Date, Double)? in
            guard let weight = day.weight else { return nil }
            return (day.date, weight)
        }
        guard let last = weights.last else {
            return VitalItem(
                kind: .weight,
                title: String(localized: "体重"),
                icon: "scalemass",
                value: nil,
                note: String(localized: "最近没有记录")
            )
        }
        var note: String?
        if let first = weights.first, weights.count >= 3 {
            let days = calendar.dateComponents([.day], from: first.0, to: last.0).day ?? 0
            let delta = last.1 - first.1
            note = abs(delta) < 0.3
                ? String(localized: "\(max(days, 1)) 天里基本没变")
                : delta > 0
                    ? String(localized: "\(max(days, 1)) 天里涨了 \(abs(delta).oneDecimal) 公斤")
                    : String(localized: "\(max(days, 1)) 天里降了 \(abs(delta).oneDecimal) 公斤")
        }
        return VitalItem(
            kind: .weight,
            title: String(localized: "体重"),
            icon: "scalemass",
            value: String(localized: "\(last.1.oneDecimal) 公斤"),
            note: note
        )
    }

    /// 「比最近基线高 4 次」/「和最近基线差不多」。
    ///
    /// `tolerance` 之内一律说「差不多」,不报那个数:静息心率日间本来就晃一两次,把
    /// 「比基线高 1 次」写进去,模型就会认真解释一个纯噪声。
    private static func comparison(
        delta: Int,
        unit: String,
        tolerance: Int,
        reference: String
    ) -> String {
        // 「最近基线 57」这种以数字收尾的说法后面要补一个空格,否则接出来的是「57多 7 次」
        // ——数字和汉字之间不留空,这一整行就是这里唯一一处读起来发黏的地方。
        let joint = reference.last?.isNumber == true ? " " : ""
        guard abs(delta) > tolerance else { return String(localized: "和\(reference)\(joint)差不多") }
        // 多和少分两条整句,不在句子中间拼一个方向词:英文那边「比基线多 3 次」整句的
        // 语序和中文不一样,拼出来的那半句没法翻。
        return delta > 0
            ? String(localized: "比\(reference)\(joint)多 \(abs(delta)) \(unit)")
            : String(localized: "比\(reference)\(joint)少 \(abs(delta)) \(unit)")
    }
}

private extension Double {
    /// "7.2";整数就不带小数点。
    var oneDecimal: String {
        self == rounded() ? String(Int(self)) : String(format: "%.1f", self)
    }
}

private extension Int {
    /// "6,240"。四位数以上的步数不分节,读起来要数位数。
    var grouped: String { formatted(.number.grouping(.automatic)) }
}
