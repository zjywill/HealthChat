import Foundation

/// 会话列表的时间分段:今天 / 昨天 / 最近 7 天 / 更早。
///
/// 按**日历天**切,不按「过去 24 小时」:凌晨一点的会话是「今天」的第一条,
/// 不是「昨天」的最后一条——用户记的是日期,不是经过了多少秒。
enum SessionTimeSection: Int, CaseIterable, Identifiable, Sendable {
    case today
    case yesterday
    case lastWeek
    case earlier

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .today: String(localized: "今天")
        case .yesterday: String(localized: "昨天")
        case .lastWeek: String(localized: "最近 7 天")
        case .earlier: String(localized: "更早")
        }
    }

    /// 时间落在哪一段。未来的时间(改过系统时钟、时区跳变)算「今天」——
    /// 让它掉到「更早」的末尾,用户会以为会话丢了。
    static func section(for date: Date, now: Date, calendar: Calendar) -> SessionTimeSection {
        let today = calendar.startOfDay(for: now)
        if date >= today { return .today }

        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return .earlier }
        if date >= yesterday { return .yesterday }

        // 含今天在内的 7 个日历天;今天和昨天已经先被摘走,这一段实际是 2–6 天前。
        guard let weekStart = calendar.date(byAdding: .day, value: -6, to: today) else { return .earlier }
        return date >= weekStart ? .lastWeek : .earlier
    }

    /// 分段里每一行显示的时间。段头已经说了「大概多久之前」,行里就该给精确的那一半:
    /// 「更早」段里再写一遍「3 周前」是把两次机会都花在同一个信息上。
    ///
    /// 界面文案全是中文写死的,时间也得跟上——不指定 locale 就会跟着系统语言变成 "Wed 14:20"。
    func timeLabel(for date: Date, now: Date, calendar: Calendar) -> String {
        let locale = Locale(identifier: "zh_Hans")
        switch self {
        case .today, .yesterday:
            return date.formatted(.dateTime.hour().minute().locale(locale))
        case .lastWeek:
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(locale))
        case .earlier:
            let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            return sameYear
                ? date.formatted(.dateTime.month().day().locale(locale))
                : date.formatted(.dateTime.year().month().day().locale(locale))
        }
    }
}

/// 一段时间里的会话。空的段不会出现在结果里。
struct SessionTimeGroup: Identifiable, Equatable, Sendable {
    let section: SessionTimeSection
    let summaries: [SessionSummary]

    var id: Int { section.id }
}

extension SessionTimeGroup {
    /// 按时间分段。输入已经是「最近更新的在前」,一趟扫完就分好了,段内顺序原样保留。
    static func groups(
        from summaries: [SessionSummary],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [SessionTimeGroup] {
        var buckets: [SessionTimeSection: [SessionSummary]] = [:]
        for summary in summaries {
            let section = SessionTimeSection.section(for: summary.updatedAt, now: now, calendar: calendar)
            buckets[section, default: []].append(summary)
        }

        return SessionTimeSection.allCases.compactMap { section in
            guard let items = buckets[section], !items.isEmpty else { return nil }
            return SessionTimeGroup(section: section, summaries: items)
        }
    }
}
