import Foundation
import AIKit

struct HealthToolSpec: Sendable {
    let name: String
    let description: String
    /// 这个工具是否接受锻炼类型筛选(只有 workouts 需要)。
    let supportsActivityFilter: Bool
    let run: @Sendable (_ days: Int, _ activity: String?) async throws -> String

    init(
        name: String,
        description: String,
        supportsActivityFilter: Bool = false,
        run: @escaping @Sendable (_ days: Int, _ activity: String?) async throws -> String
    ) {
        self.name = name
        self.description = description
        self.supportsActivityFilter = supportsActivityFilter
        self.run = run
    }
}

enum HealthTools {
    static let all: [HealthToolSpec] = [
        HealthToolSpec(
            name: "daily_steps",
            description: "当用户问及步数、活动量或久坐情况时调用。返回最近若干天的每日步数和均值。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.dailySteps(days: dayCount)
            async let history = HealthStore.shared.dailySteps(days: HealthStore.baselineDays)
            return renderSteps(
                try await window,
                days: dayCount,
                baseline: Baseline(try await history.map(\.value))
            )
        },
        HealthToolSpec(
            name: "sleep_summary",
            description: "当用户问及睡眠时长、入睡时间、起床时间或睡眠趋势时调用。返回最近若干晚的聚合睡眠。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.sleepSummary(days: dayCount)
            async let history = HealthStore.shared.sleepSummary(days: HealthStore.baselineDays)
            return renderSleep(
                try await window,
                days: dayCount,
                baseline: Baseline(try await history.map(\.asleep))
            )
        },
        HealthToolSpec(
            name: "heart_rate_summary",
            description: "当用户问及静息心率、HRV、恢复或压力趋势时调用。返回最近若干天的静息心率和心率变异性。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            async let window = HealthStore.shared.heartRateSummary(days: dayCount)
            async let history = HealthStore.shared.heartRateSummary(days: HealthStore.baselineDays)
            let baseline = try await history
            return renderHeart(
                try await window,
                days: dayCount,
                restingBaseline: Baseline(baseline.compactMap(\.restingHR)),
                hrvBaseline: Baseline(baseline.compactMap(\.hrv))
            )
        },
        HealthToolSpec(
            name: "workouts",
            description: "当用户问及锻炼、运动频率、运动时长或活动消耗时调用。返回最近若干天的锻炼记录。"
                + "只关心某一种运动时传 activity（如“跑步”），筛选在数据层完成，比自己从全部记录里挑更可靠。",
            supportsActivityFilter: true
        ) { days, activity in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.workouts(days: dayCount, activity: activity)
            return renderWorkouts(values, days: dayCount, activity: activity)
        },
        HealthToolSpec(
            name: "body_metrics",
            description: "当用户问及体重、体脂或身体指标变化时调用。返回最近若干天有记录的体重和体脂趋势。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.bodyMetrics(days: dayCount)
            return renderBody(values, days: dayCount)
        },
        HealthToolSpec(
            name: "blood_pressure",
            description: "当用户问及血压、收缩压或舒张压时调用。返回最近若干天有记录的每日血压均值。"
                + "多数人没有这项数据（需要血压计或第三方 app 写入），没有记录时会明确说明。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.bloodPressureSummary(days: dayCount)
            return renderBloodPressure(values, days: dayCount)
        },
        HealthToolSpec(
            name: "vitals",
            description: "当用户问及血氧、呼吸频率或体温时调用。返回最近若干天有记录的每日均值。"
                + "这些项需要支持的 Apple Watch 或体温计，多数人只有部分数据，没有记录时会明确说明。"
        ) { days, _ in
            let dayCount = normalizedDays(days)
            let values = try await HealthStore.shared.vitalsSummary(days: dayCount)
            return renderVitals(values, days: dayCount)
        },
        HealthToolSpec(
            name: "correlations",
            description: "当用户问「什么影响了我的睡眠/心率」「某件事有没有用」「有什么规律」时调用。"
                + "把最近的数据按条件分成两组做对比（如锻炼当晚 vs 其他晚上的睡眠时长），返回每组天数和差值。"
                + "days 建议传 60 以上，样本太少不会有结果。"
        ) { days, _ in
            let dayCount = max(normalizedDays(days), 30)
            async let steps = HealthStore.shared.dailySteps(days: dayCount)
            async let nights = HealthStore.shared.sleepSummary(days: dayCount)
            async let hearts = HealthStore.shared.heartRateSummary(days: dayCount)
            async let sessions = HealthStore.shared.workouts(days: dayCount)

            let comparisons = HealthAnalysis.comparisons(
                steps: try await steps,
                nights: try await nights,
                hearts: try await hearts,
                sessions: try await sessions
            )
            return renderComparisons(comparisons, days: dayCount)
        },
        HealthToolSpec(
            name: "health_records",
            description: "当用户问及化验单、体检报告、血糖血脂等医院检查结果时调用。"
                + "返回「健康」里来自医院或诊所的化验和体征记录。"
                + "只有用户在「健康」App 里连过医疗机构才会有数据，没有时会明确说明。"
        ) { days, _ in
            // 化验单不是每周都有,窗口默认放到一年。
            let dayCount = max(days, 365)
            let items = try await HealthStore.shared.clinicalRecords(days: dayCount)
            return renderClinical(items, days: dayCount)
        }
    ]

    static func spec(named name: String) -> HealthToolSpec? {
        all.first { $0.name == name }
    }

    /// 从工具参数的 JSON 字符串里取天数。引擎调用工具和界面显示说明都要用。
    static func days(fromInput input: String) -> Int {
        normalizedDays((try? JSONValue.decode(from: input))?["days"]?.intValue ?? 7)
    }

    /// 锻炼类型筛选。只认目录里那几个名字,别的一律当没传。
    static func activity(fromInput input: String) -> String? {
        guard let value = (try? JSONValue.decode(from: input))?["activity"]?.stringValue,
              activityNames.contains(value) else {
            return nil
        }
        return value
    }

    /// 与 `HealthStore` 给锻炼记录起的名字一致。
    static let activityNames = ["跑步", "骑行", "步行", "力量训练", "游泳", "徒步", "瑜伽", "高强度间歇训练"]

    static func note(for name: String, days: Int, activity: String? = nil) -> String {
        let label: String
        switch name {
        case "daily_steps":
            label = "步数"
        case "sleep_summary":
            label = "睡眠"
        case "heart_rate_summary":
            label = "静息心率与 HRV"
        case "workouts":
            label = activity ?? "锻炼"
        case "body_metrics":
            label = "体重与体脂"
        case "blood_pressure":
            label = "血压"
        case "vitals":
            label = "血氧、呼吸与体温"
        case "correlations":
            label = "数据之间的关联"
        case "health_records":
            label = "化验与体检记录"
        default:
            label = "健康数据"
        }
        return "查询了最近 \(normalizedDays(days)) 天\(label)"
    }

    private static func normalizedDays(_ days: Int) -> Int {
        min(max(days, 1), 90)
    }

    private static func renderComparisons(_ comparisons: [Comparison], days: Int) -> String {
        guard !comparisons.isEmpty else {
            return "最近 \(days) 天的数据还不足以做对比（每组至少要有 3 天）。多记录一段时间再看。"
        }

        let lines = comparisons.map { item in
            let direction = item.difference >= 0 ? "多" : "少"
            return "\(item.label)：\(formatDecimal(item.withCondition, suffix: ""))"
                + " vs \(formatDecimal(item.withoutCondition, suffix: ""))"
                + "，\(direction) \(formatDecimal(abs(item.difference), suffix: ""))"
                + "（\(item.withCount) 天 / \(item.withoutCount) 天）"
        }

        return ([
            "最近 \(days) 天的分组对比（单位跟随各项：睡眠为分钟，心率为次/分，HRV 为 ms）",
            "这是相关不是因果，样本量也小，只能当线索。"
        ] + lines).joined(separator: "\n")
    }

    private static func renderClinical(_ items: [ClinicalItem], days: Int) -> String {
        guard !items.isEmpty else {
            return "没有找到化验或体检记录。这类数据要先在“健康”App > 浏览 > 健康记录里"
                + "连接医院或诊所才会有；国内多数机构尚未接入。"
        }

        let lines = items.prefix(40).map { item in
            let value = item.value.map { "：\($0)" } ?? ""
            return "\(formatFullDate(item.date)) [\(item.category)] \(item.name)\(value)"
        }
        var output = ["最近约 \(days) 天的化验与体征记录，共 \(items.count) 条"] + lines
        if items.count > 40 {
            output.append("（只列出最近 40 条）")
        }
        output.append("这些是医疗机构的原始记录，解读请以出具报告的医生为准。")
        return output.joined(separator: "\n")
    }

    private static func renderSteps(_ values: [DayValue], days: Int, baseline: Baseline?) -> String {
        let recorded = values.filter { $0.value > 0 }
        guard !recorded.isEmpty else {
            return "最近 \(days) 天没有步数记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
        }

        if days > 30 {
            let lines = weeklyGroups(values, date: \.date).map { group in
                let average = group.items.map(\.value).reduce(0, +) / Double(group.items.count)
                return "\(group.range) 日均 \(formatSteps(average)) 步"
            }
            return (["最近 \(days) 天步数（按周汇总）"] + lines).joined(separator: "\n")
        }

        let average = values.map(\.value).reduce(0, +) / Double(values.count)
        let lines = values.map { "\(formatDate($0.date)) \(formatSteps($0.value)) 步" }
        var output = lines + ["日均 \(formatSteps(average)) 步"]
        if let line = baselineLine(baseline, current: average, format: { "\(formatSteps($0)) 步" }) {
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    /// "60 天基线 8,120 步（中位数，58 天有记录），本段比基线低 12%"
    ///
    /// 让模型跟"这个人平常什么样"比,而不是跟人群平均值或者它自己的印象比。
    private static func baselineLine(
        _ baseline: Baseline?,
        current: Double,
        format: (Double) -> String
    ) -> String? {
        guard let baseline else { return nil }
        var line = "\(HealthStore.baselineDays) 天基线 \(format(baseline.median))"
            + "（中位数，\(baseline.sampleCount) 天有记录）"
        if let deviation = baseline.deviation(of: current), abs(deviation) >= 5 {
            line += "，本段比基线\(deviation > 0 ? "高" : "低") \(Int(abs(deviation).rounded()))%"
        }
        return line
    }

    private static func renderSleep(_ values: [NightSleep], days: Int, baseline: Baseline?) -> String {
        guard !values.isEmpty else {
            return "最近 \(days) 天没有睡眠记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
        }

        if days > 30 {
            let lines = weeklyGroups(values, date: \.night).map { group in
                let average = group.items.map(\.asleep).reduce(0, +) / Double(group.items.count)
                return "\(group.range) 平均 \(formatDuration(average))，\(group.items.count) 晚有记录"
            }
            return (["最近 \(days) 天睡眠（按周汇总）"] + lines).joined(separator: "\n")
        }

        let lines = values.map { item in
            let bedtime = item.bedtime.map(formatTime) ?? "--:--"
            let wake = item.wake.map(formatTime) ?? "--:--"
            return "\(formatDate(item.night)) \(formatDuration(item.asleep))，\(bedtime)–\(wake)"
        }
        let average = values.map(\.asleep).reduce(0, +) / Double(values.count)
        var output = lines + ["平均 \(formatDuration(average))"]
        if let line = baselineLine(baseline, current: average, format: formatDuration) {
            output.append(line)
        }
        return output.joined(separator: "\n")
    }

    private static func renderHeart(
        _ values: [DayHeart],
        days: Int,
        restingBaseline: Baseline? = nil,
        hrvBaseline: Baseline? = nil
    ) -> String {
        let recorded = values.filter { $0.restingHR != nil || $0.hrv != nil }
        guard !recorded.isEmpty else {
            return "最近 \(days) 天没有静息心率或 HRV 记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
        }

        if days > 30 {
            let lines = weeklyGroups(values, date: \.date).map { group in
                let resting = average(group.items.compactMap(\.restingHR))
                let hrv = average(group.items.compactMap(\.hrv))
                return "\(group.range) 静息 \(formatOptional(resting, suffix: " 次/分"))，HRV \(formatOptional(hrv, suffix: " ms"))"
            }
            return (["最近 \(days) 天心率（按周汇总）"] + lines).joined(separator: "\n")
        }

        let lines = recorded.map { item in
            "\(formatDate(item.date)) 静息 \(formatOptional(item.restingHR, suffix: " 次/分"))，HRV \(formatOptional(item.hrv, suffix: " ms"))"
        }
        let restingValues = recorded.compactMap(\.restingHR)
        let hrvValues = recorded.compactMap(\.hrv)
        var summary: [String] = []
        if let minimum = restingValues.min(), let maximum = restingValues.max() {
            summary.append("静息心率区间 \(Int(minimum.rounded()))–\(Int(maximum.rounded())) 次/分")
        }
        if let minimum = hrvValues.min(), let maximum = hrvValues.max() {
            summary.append("HRV 区间 \(Int(minimum.rounded()))–\(Int(maximum.rounded())) ms")
        }
        if let current = average(restingValues),
           let line = baselineLine(restingBaseline, current: current, format: {
               "\(Int($0.rounded())) 次/分"
           }) {
            summary.append("静息心率 \(line)")
        }
        if let current = average(hrvValues),
           let line = baselineLine(hrvBaseline, current: current, format: {
               "\(Int($0.rounded())) ms"
           }) {
            summary.append("HRV \(line)")
        }
        return (lines + summary).joined(separator: "\n")
    }

    private static func renderWorkouts(
        _ values: [WorkoutItem],
        days: Int,
        activity: String? = nil
    ) -> String {
        guard !values.isEmpty else {
            if let activity {
                return "最近 \(days) 天没有\(activity)记录（其他类型的锻炼可能有，不带筛选再查一次即可）。"
            }
            return "最近 \(days) 天没有锻炼记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
        }

        if days > 30 {
            let chronological = values.sorted { $0.date < $1.date }
            let lines = weeklyGroups(chronological, date: \.date).map { group in
                let duration = group.items.map(\.duration).reduce(0, +)
                let energy = group.items.compactMap(\.activeEnergy).reduce(0, +)
                return "\(group.range) \(group.items.count) 次，\(formatDuration(duration))，\(Int(energy.rounded())) kcal"
            }
            return (["最近 \(days) 天锻炼（按周汇总）"] + lines).joined(separator: "\n")
        }

        let lines = values.map { item in
            "\(formatDate(item.date)) \(item.typeName)，\(formatDuration(item.duration))，\(formatOptional(item.activeEnergy, suffix: " kcal"))"
        }
        let duration = values.map(\.duration).reduce(0, +)
        return (lines + ["共 \(values.count) 次，合计 \(formatDuration(duration))"]).joined(separator: "\n")
    }

    private static func renderBody(_ values: [DayBody], days: Int) -> String {
        guard !values.isEmpty else {
            return "最近 \(days) 天没有体重或体脂记录。请在“设置 > 隐私与安全性 > 健康”中检查授权。"
        }

        let renderedValues: [DayBody]
        if days > 30 {
            renderedValues = weeklyGroups(values, date: \.date).compactMap { group in
                let weights = group.items.compactMap(\.weight)
                let bodyFat = group.items.compactMap(\.bodyFat)
                guard !weights.isEmpty || !bodyFat.isEmpty else { return nil }
                return DayBody(
                    date: group.items.last?.date ?? group.items[0].date,
                    weight: average(weights),
                    bodyFat: average(bodyFat)
                )
            }
        } else {
            renderedValues = values
        }

        var lines = renderedValues.map { item in
            "\(formatDate(item.date)) 体重 \(formatDecimal(item.weight, suffix: " kg"))，体脂 \(formatDecimal(item.bodyFat, suffix: "%"))"
        }
        if days > 30 {
            lines.insert("最近 \(days) 天身体指标（按周均值）", at: 0)
        }

        if let firstWeight = values.compactMap(\.weight).first,
           let lastWeight = values.compactMap(\.weight).last {
            lines.append("体重变化 \(formatSigned(lastWeight - firstWeight, suffix: " kg"))")
        }
        if let firstFat = values.compactMap(\.bodyFat).first,
           let lastFat = values.compactMap(\.bodyFat).last {
            lines.append("体脂变化 \(formatSigned(lastFat - firstFat, suffix: " 个百分点"))")
        }
        return lines.joined(separator: "\n")
    }

    private static func renderBloodPressure(_ values: [DayBloodPressure], days: Int) -> String {
        let recorded = values.filter { $0.systolic != nil || $0.diastolic != nil }
        guard !recorded.isEmpty else {
            // 没数据是常态而不是故障,说清楚原因,别让模型把它当成"读取失败"。
            return "最近 \(days) 天没有血压记录。血压需要血压计或第三方 app 写入“健康”，"
                + "Apple Watch 不测血压。如果确认记过，请在“健康”App > 共享 > App 里确认已允许 HealthChat 读取。"
        }

        let lines = recorded.map { item in
            "\(formatDate(item.date)) \(formatOptional(item.systolic, suffix: ""))/"
                + "\(formatOptional(item.diastolic, suffix: "")) mmHg"
        }
        var output = ["最近 \(days) 天血压（每日均值）"] + lines

        if let systolic = average(recorded.compactMap(\.systolic)),
           let diastolic = average(recorded.compactMap(\.diastolic)) {
            output.append(
                "均值 \(Int(systolic.rounded()))/\(Int(diastolic.rounded())) mmHg，共 \(recorded.count) 天有记录"
            )
        }
        return output.joined(separator: "\n")
    }

    private static func renderVitals(_ values: [DayVitals], days: Int) -> String {
        let recorded = values.filter {
            $0.oxygen != nil || $0.respiratoryRate != nil
                || $0.wristTemperature != nil || $0.bodyTemperature != nil
        }
        guard !recorded.isEmpty else {
            return "最近 \(days) 天没有血氧、呼吸频率或体温记录。血氧和睡眠手腕温度需要支持的 Apple Watch "
                + "并开启对应功能，体温需要体温计写入。如果确认记过，请在“健康”App > 共享 > App 里确认已允许 HealthChat 读取。"
        }

        let lines = recorded.map { item in
            var parts: [String] = ["\(formatDate(item.date))"]
            if let oxygen = item.oxygen {
                parts.append("血氧 \(formatDecimal(oxygen, suffix: "%"))")
            }
            if let breathing = item.respiratoryRate {
                parts.append("呼吸 \(formatDecimal(breathing, suffix: " 次/分"))")
            }
            if let wrist = item.wristTemperature {
                parts.append("手腕温度 \(formatDecimal(wrist, suffix: "°C"))")
            }
            if let temperature = item.bodyTemperature {
                parts.append("体温 \(formatDecimal(temperature, suffix: "°C"))")
            }
            return parts.joined(separator: "，")
        }

        var output = ["最近 \(days) 天体征（每日均值）"] + lines
        if let oxygen = average(recorded.compactMap(\.oxygen)) {
            output.append("血氧均值 \(formatDecimal(oxygen, suffix: "%"))")
        }
        if let breathing = average(recorded.compactMap(\.respiratoryRate)) {
            output.append("呼吸频率均值 \(formatDecimal(breathing, suffix: " 次/分"))")
        }
        return output.joined(separator: "\n")
    }

    private static func weeklyGroups<Item>(
        _ items: [Item],
        date: KeyPath<Item, Date>
    ) -> [(range: String, items: [Item])] {
        stride(from: 0, to: items.count, by: 7).map { start in
            let end = min(start + 7, items.count)
            let group = Array(items[start..<end])
            let firstDate = group[0][keyPath: date]
            let lastDate = group[group.count - 1][keyPath: date]
            return ("\(formatDate(firstDate))–\(formatDate(lastDate))", group)
        }
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 化验单可能是几个月前的,只写月-日会看不出年份。
    private static func formatFullDate(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash))
    }

    private static func formatDate(_ date: Date) -> String {
        let components = Calendar.autoupdatingCurrent.dateComponents([.month, .day], from: date)
        return String(format: "%02d-%02d", components.month ?? 0, components.day ?? 0)
    }

    private static func formatTime(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func formatSteps(_ value: Double) -> String {
        value.formatted(.number.grouping(.automatic).precision(.fractionLength(0)))
    }

    private static func formatDuration(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval.rounded()) / 60, 0)
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        if hours == 0 {
            return "\(remainingMinutes) 分钟"
        }
        if remainingMinutes == 0 {
            return "\(hours) 小时"
        }
        return "\(hours) 小时 \(remainingMinutes) 分"
    }

    private static func formatOptional(_ value: Double?, suffix: String) -> String {
        guard let value else { return "无记录" }
        return "\(Int(value.rounded()))\(suffix)"
    }

    private static func formatDecimal(_ value: Double?, suffix: String) -> String {
        guard let value else { return "无记录" }
        return "\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }

    private static func formatSigned(_ value: Double, suffix: String) -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(value.formatted(.number.precision(.fractionLength(1))))\(suffix)"
    }
}
