import Foundation

/// 说好回头看的事到期了,自己先跑一轮。
///
/// 在这之前,到期的 `followUp` 只是让早上那条通知把当初那句话再念一遍——「说好两周后看看
/// 深睡有没有回来」。用户点开,再等一轮工具调用,才知道答案。这里把那一轮提前跑掉:通知里
/// 带的是**结论**,点开进去那条对话已经在那儿了。
///
/// 怎么跑在 `DerivedTurn`;这里只管**该不该跑**和**问什么**。
enum FollowUpRunner {
    /// 同一条待跟进,一天最多自己跑一次。
    ///
    /// 用户一天里切几次前后台是常事,每次都跑一轮是拿他的钱重复回答同一个问题。
    static let minimumInterval: TimeInterval = 86_400

    /// 到期的里挑一条还没跑过的。挑不到就返回 nil,让位给别的后台活。
    static func pending(
        now: Date,
        memoryStore: MemoryStore,
        sessionStore: SessionStore
    ) async -> MemoryItem? {
        guard EngineSettings.memoryEnabled else { return nil }

        // 一次只挑一条。到期三条就连着跑三轮模型,是用户完全没预期的一笔开销。
        // 剩下的明天再说——它们还在宽限期里。
        for item in await memoryStore.snapshot(now: now).due(at: now) {
            guard let previous = await sessionStore.latestInThread(.followUp(item.id)) else { return item }
            if now.timeIntervalSince(previous.updatedAt) >= minimumInterval { return item }
        }
        return nil
    }

    @discardableResult
    static func run(
        _ followUp: MemoryItem,
        now: Date = Date(),
        memoryStore: MemoryStore,
        sessionStore: SessionStore
    ) async -> Bool {
        await DerivedTurn.run(
            question: question(for: followUp),
            thread: .followUp(followUp.id),
            now: now,
            // 待跟进只跑这一次,不会攒出第二段来顶。
            supersedingUnread: false,
            memoryStore: memoryStore,
            sessionStore: sessionStore
        ) != nil
    }

    /// 这条待跟进最近一次自己跑出来的结论,给通知当正文。
    static func conclusion(
        for followUp: MemoryItem,
        in sessionStore: SessionStore = .shared
    ) async -> String? {
        await DerivedTurn.conclusion(on: .followUp(followUp.id), in: sessionStore)
    }

    /// 记忆是第三人称写的("他说两周后再看看深睡"),直接当成用户的问话发出去会很怪。
    /// 这里把它还原成他当初的意思,再说清楚现在要什么——用户点开会话看到的就是这一句。
    static func question(for followUp: MemoryItem) -> String {
        "我们说好这时候回头看的：\(DerivedTurn.naturalize(followUp.text))。现在怎么样了？"
            + "查一下数据，两三句话说清楚现在是什么情况、和当初比有没有变化。"
    }
}
