import Foundation
import Testing

@testable import Vana

/// 目标进展进 check-in。
///
/// 这一轮又是用户不在场时花的钱,而且和待跟进不同——它是**反复**发生的。所以盯的重点是
/// 节流:一周一次、放下了就不再问、一次前后台最多跑一件、机器写的那段别在列表里越堆越多。
/// 一条每天早上都在念叨目标的通知,三天就会被划掉。
@Suite("GoalDigest")
struct GoalDigestTests {

    private static func freshMemory() -> MemoryStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return MemoryStore(directory: directory)
    }

    private static func freshSessions() -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(parent: directory)
    }

    private static let day: TimeInterval = 86_400

    private static func segment(
        _ thread: SessionThread,
        title: String = "减脂",
        derived: Bool = false,
        messages: Int = 2,
        updatedAt: Date
    ) -> ChatSession {
        ChatSession(
            messages: (0..<messages).map {
                ChatMessage(
                    role: $0.isMultiple(of: 2) ? .user : .assistant,
                    text: "第\($0)条",
                    toolCalls: $0 == 1
                        ? [ToolCallRecord(id: UUID().uuidString, name: "body_metrics", input: "{}")]
                        : []
                )
            },
            threadId: thread.id,
            threadTitle: title,
            isDerived: derived,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - 该不该问

    @Test("a goal never digested before is due right away")
    func firstDigestIsDueImmediately() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        try await store.save(Self.segment(thread, updatedAt: now - Self.day))

        #expect(await GoalDigest.pending(now: now, sessionStore: store)?.threadId == thread.id)
    }

    @Test("progress is reported weekly, not daily")
    func digestIsThrottledToAWeek() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        try await store.save(Self.segment(thread, updatedAt: now - 8 * Self.day))
        try await store.save(Self.segment(thread, derived: true, updatedAt: now - 2 * Self.day))

        // 入睡时间、体重这类指标的日间波动比趋势本身大得多。每天报一次说的全是噪声,
        // 而且第三天用户就开始无视这条通知了。
        #expect(await GoalDigest.pending(now: now, sessionStore: store) == nil)
        #expect(await GoalDigest.pending(now: now + 6 * Self.day, sessionStore: store) != nil)
    }

    @Test("the user's own chatting does not count as having reported progress")
    func userChatIsNotADigest() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        try await store.save(Self.segment(thread, derived: true, updatedAt: now - 20 * Self.day))
        // 他昨天自己聊过这条线,但这周的进展还没报过。
        try await store.save(Self.segment(thread, updatedAt: now - Self.day))

        #expect(await GoalDigest.pending(now: now, sessionStore: store) != nil)
    }

    @Test("a goal left alone for a month is let go, not nagged weekly")
    func abandonedGoalsAreLetGo() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        try await store.save(Self.segment(thread, updatedAt: now - 45 * Self.day))

        // 一个月没碰过的目标还每周报一次进展,是纠缠不是关心。他想接着做,点一下就回来了。
        #expect(await GoalDigest.pending(now: now, sessionStore: store) == nil)
    }

    // MARK: - 一次只跑一件

    @Test("a due follow-up wins over a due goal, and only one runs")
    func onlyOneBackgroundRunAtATime() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey)
        // 云端设置拿掉,这条测试就不会真去打模型(那要十几秒,还花用户的钱)。
        let defaults = UserDefaults.standard
        let savedModel = defaults.string(forKey: EngineSettings.modelKey)
        defaults.set("", forKey: EngineSettings.modelKey)
        defer { defaults.set(savedModel, forKey: EngineSettings.modelKey) }

        let now = Date()
        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: now - 60)
        let sessions = Self.freshSessions()
        try await sessions.save(Self.segment(.goal(UUID()), updatedAt: now - Self.day))

        // 两件都成立时,先跑说好回头看的那件:那是一个带日子的约定,今天不说就失约了;
        // 目标的周进展晚一天说没什么损失。
        #expect(await FollowUpRunner.pending(now: now, memoryStore: memory, sessionStore: sessions) != nil)
        #expect(await GoalDigest.pending(now: now, sessionStore: sessions) != nil)
        // 设置不齐就一件都不跑,更不会连着跑两轮。
        #expect(await BackgroundDigest.runIfDue(now: now, memoryStore: memory, sessionStore: sessions) == false)
        #expect(await sessions.goals().first?.segmentCount == 1)
    }

    // MARK: - 别在列表里越堆越多

    @Test("last week's unread digest is superseded, not stacked")
    func unreadDigestsAreSuperseded() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        let lastWeek = Self.segment(thread, derived: true, updatedAt: now - 7 * Self.day)
        let thisWeek = Self.segment(thread, derived: true, updatedAt: now)
        try await store.save(lastWeek)
        try await store.save(thisWeek)

        // 每周一段进展报告攒一年是五十二段,而用户根本没看过前面那些。
        let stale = await DerivedTurn.unreadDerived(on: thread, besides: thisWeek.id, in: store)
        #expect(stale == lastWeek.id)
    }

    @Test("a digest the user replied to is a real conversation and is kept")
    func answeredDigestsAreKept() async throws {
        let store = Self.freshSessions()
        let now = Date()
        let thread = SessionThread.goal(UUID())
        // 他接了话之后这段就有四条了。
        let answered = Self.segment(thread, derived: true, messages: 4, updatedAt: now - 7 * Self.day)
        let fresh = Self.segment(thread, derived: true, updatedAt: now)
        try await store.save(answered)
        try await store.save(fresh)

        // 顶掉它等于把他说过的话删了。
        #expect(await DerivedTurn.unreadDerived(on: thread, besides: fresh.id, in: store) == nil)
    }

    @Test("what the app asked on his behalf is not what he is interested in")
    func derivedSessionsDoNotFeedInterests() async throws {
        let store = Self.freshSessions()
        let now = Date()
        try await store.save(Self.segment(.goal(UUID()), derived: true, messages: 4, updatedAt: now))

        // 后台替他查了三次体重不代表他关心体重——而这份统计反过来又会影响首屏建议和
        // check-in 挑什么说,不挡住就是自己喂自己。
        #expect(await store.interests().weight(forTool: "body_metrics") == 0)
    }

    // MARK: - 进不进得了通知

    @Test("a goal with real progress outranks a trigger, but not a dated promise")
    func goalRanksBetweenPromisesAndTriggers() {
        let note = CheckInScheduler.GoalNote(
            threadId: SessionThread.goal(UUID()).id,
            title: "把作息掰回来",
            conclusion: "入睡中位数提前到 00:55，比上周早了 20 分钟。"
        )
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.5, deficitMinutes: 90)]
        )

        // 目标压过触发点:那是**他自己定下的**一件事,触发点只是数据里冒出来的现象。
        let withGoal = CheckInScheduler.content(for: .morning, situation: situation, goalNote: note)
        #expect(withGoal.body == note.conclusion)
        #expect(withGoal.threadId == note.threadId)
        // 点开落回那条线接着聊,不预填问题——进展已经在通知里了,再问一遍只会得到同一段话。
        #expect(withGoal.question == nil)

        // 但压不过一个带日子的约定:今天不说就失约了。
        let promise = MemoryItem(kind: .followUp, text: "他说两周后再看看深睡", dueAt: Date())
        let withBoth = CheckInScheduler.content(
            for: .morning,
            situation: situation,
            dueFollowUps: [promise],
            goalNote: note
        )
        #expect(withBoth.followUpId == promise.id)
        #expect(withBoth.threadId == SessionThread.followUp(promise.id).id)
    }

    @Test("without a conclusion the goal stays out of the notification")
    func goalWithoutProgressStaysQuiet() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.5, deficitMinutes: 90)]
        )
        let plain = CheckInScheduler.content(for: .morning, situation: situation)

        // 空口一句「你的『减脂』还在进行中」对用户是零信息,那不如把位置让给触发点。
        #expect(plain.body == situation.triggers[0].brief)
        // 没写线程的照旧回 check-in 那条线。
        #expect(plain.threadId == nil)
    }

    @Test("the evening check-in never repeats the morning's goal note")
    func goalIsMorningOnly() {
        let note = CheckInScheduler.GoalNote(
            threadId: SessionThread.goal(UUID()).id,
            title: "减脂",
            conclusion: "体重两周降了 0.8 公斤。"
        )
        let evening = CheckInScheduler.content(
            for: .evening,
            situation: HealthSituation(period: .evening, triggers: []),
            goalNote: note
        )

        // 晚上再说一遍同一件事,是两条通知讲一个内容。
        #expect(evening.body != note.conclusion)
    }
}
