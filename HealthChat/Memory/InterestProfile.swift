import Foundation

/// 这个人实际关心什么。
///
/// **数出来的,不是模型抽出来的。**「最近 30 条会话里 18 条查了睡眠、2 条查了体重」是统计,
/// 本地数一遍更准更便宜,而且随时可重算、不占记忆的额度。分工是清楚的:模型抽的是他**说过
/// 的话**,app 数的是他**点过的东西**。为数数花一次模型调用是纯亏。
///
/// 数的是工具调用而不是问句里的关键词。他点的按钮、问出去的问题最后都会落成一次工具调用,
/// 而关键词匹配会把「今天不想聊睡眠」也算成关心睡眠。
struct InterestProfile: Sendable, Equatable {
    static let empty = InterestProfile(weights: [:])

    /// 工具名 → 加权次数。
    let weights: [String: Double]

    /// 越近的会话算得越重。半年前问过一阵子睡眠,不代表现在还在关心。
    private static let decayPerSession = 0.93
    /// 低于这个权重当没有:一次两次算不上倾向。
    private static let meaningfulWeight = 1.5

    func weight(forTool tool: String?) -> Double {
        guard let tool else { return 0 }
        return weights[tool] ?? 0
    }

    /// 从高到低,只留够得上「倾向」的。
    var ranked: [String] {
        weights
            .filter { $0.value >= Self.meaningfulWeight }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map(\.key)
    }

    /// 给 `QuestionSuggester` 的一句话。没形成倾向就返回 nil——硬凑一句「他关心健康」
    /// 只会占掉提示词的位置。
    var summary: String? {
        let top = ranked.prefix(2).map { HealthTools.label(for: $0) }
        guard !top.isEmpty else { return nil }

        var sentence = "他最常问的是\(top.joined(separator: "、"))。"
        // 从来没碰过的那几类也值得说一句:据此别再推荐它们,比多推荐一次更有用。
        let untouched = HealthTools.all
            .map(\.name)
            .filter { weights[$0] == nil }
            .prefix(2)
            .map { HealthTools.label(for: $0) }
        if !untouched.isEmpty {
            sentence += "几乎不问\(untouched.joined(separator: "、"))。"
        }
        return sentence
    }

    /// 从会话索引里数一遍。传进来的要**最近的在前**。
    ///
    /// 数的是索引不是会话全文:这里要的只是"哪几个工具出现过",为它把一年的对话解成对象图
    /// 是纯浪费,而这一步在 Siri 那条路上跑在用户等着听话的时候。
    static func build(from entries: [SessionIndexEntry]) -> InterestProfile {
        var weights: [String: Double] = [:]

        for (index, entry) in entries.enumerated() {
            // app 替他问的那几段不算。后台替他查了三次睡眠不代表他关心睡眠——而这份统计
            // 反过来又会影响后台去查什么,不挡住就是自己喂自己。
            guard !entry.isDerived else { continue }
            let weight = pow(decayPerSession, Double(index))
            // 一条会话里同一个工具查了五次也只算一次:那是一个问题被拆成了五步,
            // 不是他关心这件事的程度是别人的五倍。`toolNames` 已经去过重了。
            for tool in entry.toolNames {
                weights[tool, default: 0] += weight
            }
        }

        return InterestProfile(weights: weights)
    }
}
