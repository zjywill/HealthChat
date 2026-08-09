import Foundation

/// 一条**跨天延续**的会话线。
///
/// 在这之前,每一次 check-in 通知、每一条到期的待跟进都开一条新会话。结果是「这件事」散在
/// 三十条标题都叫「早上好」的会话里——用户翻不出一件事的过程,模型也每天从零开始。
///
/// 线程只做一件事:下次从同一个入口进来时,**接着上次那条聊**。它不是新的一层存储,就是
/// `ChatSession` 上多一个 id。
enum SessionThread: Equatable, Sendable {
    /// 每天的 check-in 汇成一条。
    case checkIn
    /// 兑现某一条「说好回头看的事」。单一主题,而且后台派生的那一轮要往这条里写结论。
    case followUp(UUID)
    /// 用户自己开的一件长期的事:减脂、备半马、把作息掰回来。
    ///
    /// 名字由用户起,存在会话的 `threadTitle` 上,不另开一张"目标表"——一段一段往下传看着
    /// 冗余,换来的是这条线的名字和它的内容永远在同一个文件里。
    case goal(UUID)

    var id: String {
        switch self {
        case .checkIn: "checkin"
        case .followUp(let uuid): "followup:\(uuid.uuidString)"
        case .goal(let uuid): "goal:\(uuid.uuidString)"
        }
    }

    init?(id: String) {
        func uuid(after prefix: String) -> UUID? {
            guard id.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(id.dropFirst(prefix.count)))
        }

        if id == "checkin" {
            self = .checkIn
        } else if let followUp = uuid(after: "followup:") {
            self = .followUp(followUp)
        } else if let goal = uuid(after: "goal:") {
            self = .goal(goal)
        } else {
            return nil
        }
    }

    /// 用户没起名字时的兜底名。
    var title: String {
        switch self {
        case .checkIn: "每日 check-in"
        case .followUp: "说好回头看的事"
        case .goal: "长期目标"
        }
    }

    /// 目标线是用户当成一件事在管的:能改名、能整条删,列表上单独一组。
    var isGoal: Bool {
        if case .goal = self { return true }
        return false
    }
}

/// 一条目标线在界面上的样子。
///
/// **按线合并,不是按会话。** 一条「减脂」可能已经分成三段(隔太久就另起一段),但用户眼里
/// 那始终是一件事;列表里排出三条「减脂计划」,正是这个功能要消掉的那种碎片。
struct GoalSummary: Identifiable, Equatable, Sendable {
    let threadId: String
    /// 用户起的名字。
    let title: String
    let updatedAt: Date
    /// 最近那一段。点进去先落在它上面(还接得上的话)。
    let latestSessionId: UUID
    var segmentCount: Int
    var messageCount: Int

    var id: String { threadId }
    var thread: SessionThread? { SessionThread(id: threadId) }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// 什么时候接着上次那条,什么时候另起一条。
///
/// 「永远接着上一条」听起来更连续,实际是把一条会话养成一份永不结束的日志:每一轮都要压缩
/// 一次(钱),用户翻到底要滑半天(没法用),而三个月前那句早就和今天无关了。所以延续是**有
/// 期限的**——断开的那条一条不丢,`search_sessions` 照样翻得到。
enum SessionThreadPolicy {
    /// 隔了这么多天没动过,就当上一段已经结束了。
    ///
    /// 4 天:请两天假不看手机回来还能接上,出差一周回来则是新的一段。
    static let maxIdleDays = 4
    /// 一条线程会话最多攒这么多条消息。
    static let maxMessages = 40

    /// 目标线隔多久不动才算断。
    ///
    /// 比 check-in 宽得多:「减脂」这件事请一周假回来还是同一件事,而每天的 check-in 隔一周
    /// 就是新的一段了。用户自己开的线,凭一次出差把它掐断很没道理。
    static let maxGoalIdleDays = 21

    static func canContinue(_ entry: SessionIndexEntry, at now: Date = Date()) -> Bool {
        guard !entry.isEmpty, entry.messageCount < maxMessages else { return false }
        let idleDays = entry.thread?.isGoal == true ? maxGoalIdleDays : maxIdleDays
        return now.timeIntervalSince(entry.updatedAt) < Double(idleDays) * 86_400
    }
}
