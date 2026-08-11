import Foundation

/// 目标线的定期进展。
///
/// 目标是用户自己定下的一件长期的事。他不会每天来问「减脂进展怎么样」——那件事的变化本来就
/// 不是按天发生的。所以由 app 每隔一阵子替他问一次,结论进早上那条 check-in。
///
/// 怎么跑在 `DerivedTurn`;这里只管**该不该跑**和**问什么**。
enum GoalDigest {
    /// 同一条目标线,多久报一次进展。
    ///
    /// 一周。**不是一天**:入睡时间、体重这类指标的日间波动比趋势本身大得多,每天报一次
    /// 说的全是噪声,而且第三天用户就开始无视这条通知了。一周才看得出「提前了 45 分钟」
    /// 这种能下判断的东西。
    static let minimumInterval: TimeInterval = 7 * 86_400

    /// 多久没动过就当他已经放下了。
    ///
    /// 一个月没碰过的目标,还每周报一次进展,是纠缠不是关心。他想接着做,列表里点一下就回来了,
    /// 回来那一刻这条线自然又活了。
    static let abandonedAfter: TimeInterval = 30 * 86_400

    /// 该报进展的那条目标。挑不到就返回 nil。
    static func pending(now: Date, sessionStore: SessionStore) async -> GoalSummary? {
        for goal in await sessionStore.goals() {
            guard now.timeIntervalSince(goal.updatedAt) < abandonedAfter else { continue }
            guard let thread = goal.thread else { continue }
            // 上次替他问是什么时候——看的是**机器写的**那几段,不是他自己聊的那几段。
            // 他昨天刚聊过这条线,不代表这周的进展已经报过了;反过来也一样。
            let lastDigest = await sessionStore.entries(inThread: thread)
                .first { $0.isDerived }
            guard let lastDigest else { return goal }
            if now.timeIntervalSince(lastDigest.updatedAt) >= minimumInterval { return goal }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ goal: GoalSummary,
        now: Date = Date(),
        memoryStore: MemoryStore,
        sessionStore: SessionStore
    ) async -> Bool {
        guard let thread = goal.thread else { return false }
        return await DerivedTurn.run(
            question: question(for: goal),
            thread: thread,
            threadTitle: goal.title,
            now: now,
            memoryStore: memoryStore,
            sessionStore: sessionStore
        ) != nil
    }

    static func conclusion(for goal: GoalSummary, in sessionStore: SessionStore = .shared) async -> String? {
        guard let thread = goal.thread else { return nil }
        return await DerivedTurn.conclusion(on: thread, in: sessionStore)
    }

    /// 问的是**变化**,不是现状。
    ///
    /// 「你这周睡了几小时」他自己随时问得到;这条通知要值得存在,得说出「比上周提前了 20 分钟」
    /// 这种他不翻历史就看不出来的东西——而那正好是 `search_sessions` 派上用场的地方。
    static func question(for goal: GoalSummary) -> String {
        "关于「\(goal.title)」这件事：先翻一下我们之前聊到哪儿、当时定的是什么，"
            + "再查现在的数据，两三句话说清楚这段时间有没有进展、和上次比变了多少。"
            + "没有明显变化就直说没有，不用凑一个好消息出来。"
    }
}
