import Foundation

/// Vana 记住的一条事实。
///
/// 记忆里**不存 HealthKit 查得到的数字**。存「昨晚睡了 6.2 小时」明天就是错的,存「他觉得
/// 睡够 7 小时才算好」永远对。查得到的每次回工具拿,记忆只留查不到的:用户自己说的、模型
/// 推出来的解释、他希望被怎么对待。
///
/// 这条约束顺带解决了失效问题——不存易腐的东西,就不用给每条记忆做过期时间。唯一的例外是
/// `followUp`,那一类天生带时限,过期自己消失。
struct MemoryItem: Identifiable, Equatable, Codable, Sendable {
    /// 这条是怎么来的。
    ///
    /// 界面上要能回答「这句哪来的」:分不清是自己写的还是模型记的,用户就没法判断该不该
    /// 信它。也决定了后台的抽取能不能动它——前两种都不行。
    enum Origin: String, Codable, Sendable {
        /// 在设置页里手写或改过的。
        case manual
        /// 对话里明确让 Vana 记的(`remember` 工具)。
        case asked
        /// 会话结束后自动抽出来的。
        case extracted
    }

    let id: UUID
    var kind: MemoryKind
    var text: String
    var createdAt: Date
    var updatedAt: Date
    var origin: Origin
    /// 从哪条会话来的。
    var sourceSessionId: UUID?
    /// 只有 `followUp` 用:说好什么时候回头看。
    ///
    /// 到期不等于删除——到期正是它要派上用场的时刻。过了这个点它会进 check-in,
    /// 再过 `MemoryStore.followUpGrace` 才真的消失。
    var dueAt: Date?

    /// 用户主动写下或要求记的,淘汰和自动改写都跳过。
    var pinned: Bool { origin != .extracted }

    init(
        id: UUID = UUID(),
        kind: MemoryKind,
        text: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        origin: Origin = .extracted,
        sourceSessionId: UUID? = nil,
        dueAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.origin = origin
        self.sourceSessionId = sourceSessionId
        self.dueAt = dueAt
    }

    /// 说好回头看的那天到了。
    func isDue(at now: Date) -> Bool {
        guard let dueAt else { return false }
        return dueAt <= now
    }

    /// 到期之后又搁了一段时间,可以清掉了。
    func hasExpired(at now: Date, grace: TimeInterval) -> Bool {
        guard let dueAt else { return false }
        return dueAt.addingTimeInterval(grace) <= now
    }
}

/// 记忆的四类。
///
/// 分类不是为了好看:渲染进 prompt 时分组能让模型对短列表更服从,淘汰时也要按类别定优先级。
enum MemoryKind: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 长期情况:上夜班、腰伤不能跑、在备半马。
    case profile
    /// 表达偏好:别老提醒去看医生、只看深睡时长。
    case preference
    /// 已有解释:静息心率基线约 52、三月那周 HRV 掉是因为出差。
    case interpretation
    /// 待跟进:说好过一阵子再看的事。唯一带时限的一类。
    case followUp

    var id: String { rawValue }

    /// 界面上的名字,也是 prompt 里的分组标签——两处叫法不一致,用户在设置里看到的东西
    /// 就和模型看到的对不上了。
    var title: String {
        switch self {
        case .profile: String(localized: "长期情况")
        case .preference: String(localized: "表达偏好")
        case .interpretation: String(localized: "已有解释")
        case .followUp: String(localized: "待跟进")
        }
    }

    var hint: String {
        switch self {
        case .profile: String(localized: "作息、工作、伤病限制、正在进行的目标")
        case .preference: String(localized: "希望 Vana 怎么说话、自己看重哪个指标")
        case .interpretation: String(localized: "对你而言某个指标的正常范围，或某段异常的原因")
        case .followUp: String(localized: "说好过一阵子再看的事，到点会在 check-in 里提醒你")
        }
    }

    var icon: String {
        switch self {
        case .profile: "person.text.rectangle"
        case .preference: "text.bubble"
        case .interpretation: "chart.line.uptrend.xyaxis"
        case .followUp: "clock.arrow.circlepath"
        }
    }
}

/// 一条会话开始时拿到的记忆,**这条会话之内不再变**。
///
/// 理由和「系统提示里的今天只精确到天」是同一个:system 段中途变化会打掉 prompt 缓存,而且
/// 同一条对话里模型对用户的认知不该跳变。所以引擎不许自己去读盘,由 `ChatViewModel` 在会话
/// 开始时读好传进去。抽取写在会话结束、快照读在会话开始,正好配套——这条会话学到的东西,
/// 下一条会话生效。
struct MemorySnapshot: Equatable, Sendable {
    static let empty = MemorySnapshot(items: [])

    let items: [MemoryItem]

    var isEmpty: Bool { items.isEmpty }

    /// 拼进 system 段的那一块。空记忆返回 nil,不要往提示里塞一句「（暂无）」——那只会
    /// 让模型去解释为什么没有。
    var instructionBlock: String? {
        instructionBlock(now: Date())
    }

    func instructionBlock(now: Date) -> String? {
        guard !items.isEmpty else { return nil }

        var lines = [
            "关于这位用户（来自过往对话，不是健康数据）："
        ]
        for kind in MemoryKind.allCases {
            let matching = items.filter { $0.kind == kind }
            guard !matching.isEmpty else { continue }
            for item in matching {
                // 到期的待跟进要说清已经到点了,否则模型只会把它当成一句将来时的计划,
                // 而这条记忆存在的全部意义就是「现在该回头看了」。
                let due = item.isDue(at: now) ? "（说好的时间已经到了）" : ""
                lines.append("- [\(kind.title)] \(item.text)\(due)")
            }
        }
        // 这一句是这套东西最要紧的防线。没有它,模型会拿三个月前记下的一句话当今天的数据讲。
        lines.append(
            """
                以上只用于理解他的处境和表达方式。任何具体数值一律以本次工具返回的为准，\
                记忆与工具结果冲突时以工具结果为准，也不要把上面的内容当成诊断。
                """
        )
        return lines.joined(separator: "\n")
    }

    /// 给抽取器看的那份:每条前面挂一个短编号。
    ///
    /// 不给模型看 UUID——36 个字符乘以几十条纯属浪费,而且模型抄长串本来就容易抄错,抄错
    /// 一位就是一条改不动的记忆。
    var handles: [(handle: String, item: MemoryItem)] {
        items.enumerated().map { (handle: "M\($0.offset + 1)", item: $0.element) }
    }

    func resolve(handle: String) -> UUID? {
        handles.first { $0.handle.caseInsensitiveCompare(handle) == .orderedSame }?.item.id
    }

    var handleListing: String {
        guard !items.isEmpty else { return "（目前还没有记住任何事）" }
        return handles
            .map { "\($0.handle) [\($0.item.kind.title)] \($0.item.text)" }
            .joined(separator: "\n")
    }

    /// 说好该回头看的那几条。check-in 用它挑今天早上说什么。
    func due(at now: Date) -> [MemoryItem] {
        items.filter { $0.kind == .followUp && $0.isDue(at: now) }
    }
}
