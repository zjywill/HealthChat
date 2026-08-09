import Foundation

/// app 切前后台时替用户跑的那点后台活。
///
/// 存在的意义是**一次只跑一件**。到期的待跟进和该报进展的目标可能同时成立,连着跑两轮模型
/// 是用户完全没预期的一笔开销,而且第二轮的结论今天也没地方说——早上那条通知只有一行。
///
/// 排序不是随手定的:**说好回头看的事排在目标前面**。那是一个带日子的约定(「两周后看深睡」),
/// 今天不说就失约了;目标的周进展晚一天说没什么损失。同一条道理见 `CheckInScheduler.content`
/// 里待跟进排在所有触发点前面。
enum BackgroundDigest {

    /// 有活就干一件,返回是否真的产出了新结论(调用方据此决定要不要重排通知)。
    @discardableResult
    static func runIfDue(
        now: Date = Date(),
        memoryStore: MemoryStore = .shared,
        sessionStore: SessionStore = .shared
    ) async -> Bool {
        // check-in 关掉就没有送达的路子,这一轮纯粹是花钱写给自己看。
        // 云端设置不齐则是发都发不出去。
        guard UserDefaults.standard.bool(forKey: EngineSettings.checkInsEnabledKey),
              DerivedTurn.cloudSettings() != nil
        else { return false }

        if let followUp = await FollowUpRunner.pending(
            now: now,
            memoryStore: memoryStore,
            sessionStore: sessionStore
        ) {
            return await FollowUpRunner.run(
                followUp,
                now: now,
                memoryStore: memoryStore,
                sessionStore: sessionStore
            )
        }

        if let goal = await GoalDigest.pending(now: now, sessionStore: sessionStore) {
            return await GoalDigest.run(
                goal,
                now: now,
                memoryStore: memoryStore,
                sessionStore: sessionStore
            )
        }

        return false
    }
}
