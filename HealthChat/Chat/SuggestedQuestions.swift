import Foundation

struct SuggestedQuestion: Identifiable, Equatable, Sendable {
    var id: String { text }
    let icon: String
    let text: String
}

/// 一天里的哪一段。开这个 app 的动机跟时间强相关:早上想知道昨晚睡得怎么样,
/// 晚上想知道今天动够没有,练完想知道恢复得如何。
enum DayPeriod: Sendable, Equatable {
    case morning
    case afternoon
    case evening

    init(at date: Date = Date(), calendar: Calendar = .autoupdatingCurrent) {
        switch calendar.component(.hour, from: date) {
        case 5..<11: self = .morning
        case 11..<18: self = .afternoon
        default: self = .evening
        }
    }

    /// 给模型的场景说明,让生成的问题贴着当下这一刻。
    var context: String {
        switch self {
        case .morning:
            return "现在是早上，用户刚醒，最可能关心昨晚睡得怎么样、今天状态适不适合训练。"
        case .afternoon:
            return "现在是下午，用户可能刚练完或者想知道今天活动量攒够了没有。"
        case .evening:
            return "现在是晚上，用户在收尾一天，最可能关心今天运动量够不够、这周练得怎么样。"
        }
    }
}

/// 首屏的问题建议。
///
/// 这几条是占位:没配 key、生成失败、或者 AI 还没返回时先顶上,首屏永远不空着。
/// 每条都短到一行放得下——换行会把卡片撑得参差不齐。
enum SuggestedQuestions {
    static func defaults(at date: Date = Date()) -> [SuggestedQuestion] {
        defaults(period: DayPeriod(at: date))
    }

    static func defaults(period: DayPeriod) -> [SuggestedQuestion] {
        switch period {
        case .morning:
            return [
                SuggestedQuestion(icon: "moon.stars", text: "昨晚睡得怎么样？"),
                SuggestedQuestion(icon: "bed.double", text: "最近睡眠稳定吗？"),
                SuggestedQuestion(icon: "figure.run", text: "今天适合训练吗？")
            ]
        case .afternoon:
            return [
                SuggestedQuestion(icon: "figure.walk", text: "今天走够步数了吗？"),
                SuggestedQuestion(icon: "figure.cooldown", text: "刚练完，恢复得如何？"),
                SuggestedQuestion(icon: "heart.text.square", text: "最近状态还行吗？")
            ]
        case .evening:
            return [
                SuggestedQuestion(icon: "figure.walk", text: "今天运动量够吗？"),
                SuggestedQuestion(icon: "flame", text: "这周锻炼够了吗？"),
                SuggestedQuestion(icon: "heart.text.square", text: "今天比昨天累吗？")
            ]
        }
    }
}
