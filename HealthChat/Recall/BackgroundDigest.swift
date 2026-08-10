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
    /// - Parameters:
    ///   - memoryStore: **机主那一份,不跟着当前选中的成员走。** 这一轮读的是 HealthKit,
    ///     而那份数据只有机主有;用户此刻正好在看妈妈那一栏,不该让后台这一轮把机主的结论
    ///     写进妈妈的会话里。同 `CheckInScheduler`、`SpokenBrief`。
    ///   - sessionStore: 同上。「今天跑过没有」那道闸读的也是机主那边的会话。
    static func runIfDue(
        now: Date = Date(),
        memoryStore: MemoryStore = TenantScope.ownerStores.memory,
        sessionStore: SessionStore = TenantScope.ownerStores.sessions
    ) async -> Bool {
        // check-in 关掉就没有送达的路子,这一轮纯粹是花钱写给自己看。
        // 云端设置不齐则是发都发不出去。
        guard UserDefaults.standard.bool(forKey: EngineSettings.checkInsEnabledKey),
              DerivedTurn.cloudSettings() != nil
        else { return false }

        // **在飞守卫。** 下面那几道闸("今天跑过没有"、"这周报过没有")读的是**盘上那条会话**,
        // 而它要等这一轮跑完(几十秒)才存下来。`scenePhase` 一次开合就触发两次
        // (`.active` 和 `.background`),第二次进来时第一轮还在飞,闸门读到的还是"没跑过"——
        // 于是两轮并行,两份钱,最后还互相顶掉对方那条会话。
        let ran = await BackgroundModelWork.shared.run {
            await runOnce(now: now, memoryStore: memoryStore, sessionStore: sessionStore)
        }
        // 没抢到位子 → nil → 这次什么都没跑,也就没有新结论要去重排通知。
        return ran ?? false
    }

    private static func runOnce(
        now: Date,
        memoryStore: MemoryStore,
        sessionStore: SessionStore
    ) async -> Bool {
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
