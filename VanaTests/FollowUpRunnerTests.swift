import Foundation
import Testing

@testable import Vana

/// 到期的「说好回头看的事」自己先跑一轮。
///
/// 这里盯的主要是**闸**:这一轮是用户不在场时花的钱,跑错了他事后才看得到账单。所以
/// 「什么时候不跑」比「跑出来什么」更要紧——没配 key 不跑、关了 check-in 不跑(结论没有
/// 送达的路子)、今天已经跑过不跑、没到期不跑。
///
/// 真正那一轮模型调用不在这里跑:它要网络和 key。这套测试盯的是它前面那几道闸和后面
/// 结论怎么进通知。
@Suite("FollowUpRunner")
struct FollowUpRunnerTests {

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

    /// 那一轮跑完之后盘上会留下的东西。
    private static func derivedSession(
        for followUp: MemoryItem,
        conclusion: String,
        updatedAt: Date
    ) -> ChatSession {
        ChatSession(
            messages: [
                ChatMessage(role: .user, text: FollowUpRunner.question(for: followUp)),
                ChatMessage(role: .assistant, text: conclusion)
            ],
            threadId: SessionThread.followUp(followUp.id).id,
            createdAt: updatedAt,
            updatedAt: updatedAt
        )
    }

    // MARK: - 闸

    @Test("an incomplete cloud setup means no background spend")
    func incompleteSetupMeansNoRun() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey)
        // 云端要齐 key 和 model 才发得出去。key 在 Keychain 里,测试不该去动它——
        // 把 model 拿掉是同一道闸的另一半,而且改完能原样放回去。
        //
        // 这条必须是确定性的:让它"看情况真跑一轮"的话,每次 `swift test` 都在花用户的钱,
        // 而且那一轮要十几秒。
        let defaults = UserDefaults.standard
        let savedModel = defaults.string(forKey: EngineSettings.modelKey)
        defaults.set("", forKey: EngineSettings.modelKey)
        defer { defaults.set(savedModel, forKey: EngineSettings.modelKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        let sessions = Self.freshSessions()

        #expect(await BackgroundDigest.runIfDue(memoryStore: memory, sessionStore: sessions) == false)
        // 半截会话也不该留下:用户点开只会看到一条空回复。
        #expect(await sessions.summaries().isEmpty)
    }

    @Test("check-ins off means the conclusion has nowhere to go, so it is not computed")
    func checkInsOffMeansNoRun() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(false, forKey: EngineSettings.checkInsEnabledKey)
        defer { UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        let sessions = Self.freshSessions()

        // 结论只有一条送达的路子——早上那条通知。通知关着还去跑,是花钱写给自己看。
        #expect(await BackgroundDigest.runIfDue(memoryStore: memory, sessionStore: sessions) == false)
        #expect(await sessions.summaries().isEmpty)
    }

    @Test("memory off means there are no follow-ups at all")
    func memoryOffMeansNoRun() async throws {
        UserDefaults.standard.set(false, forKey: EngineSettings.memoryEnabledKey)
        defer { UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey) }

        let memory = Self.freshMemory()
        try await memory.add(kind: .followUp, text: "两周后看深睡", dueAt: Date().addingTimeInterval(-60))
        let sessions = Self.freshSessions()

        #expect(await BackgroundDigest.runIfDue(memoryStore: memory, sessionStore: sessions) == false)
    }

    @Test("a follow-up already run today is not run again")
    func alreadyRunTodayIsSkipped() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.memoryEnabledKey)
        UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey)
        let now = Date()
        let memory = Self.freshMemory()
        let stored = try await memory.add(
            kind: .followUp,
            text: "两周后看深睡",
            dueAt: now.addingTimeInterval(-60)
        )
        let followUp = try #require(stored.first)

        let sessions = Self.freshSessions()
        try await sessions.save(Self.derivedSession(
            for: followUp,
            conclusion: "深睡回到 1 小时 20 分了。",
            updatedAt: now.addingTimeInterval(-3_600)
        ))

        // 用户一天里切几次前后台是常事。每次都跑一轮,是拿他的钱重复回答同一个问题。
        #expect(await BackgroundDigest.runIfDue(now: now, memoryStore: memory, sessionStore: sessions) == false)
    }

    // MARK: - 结论怎么进通知

    @Test("the conclusion comes from the session it was written into, not a second copy")
    func conclusionComesFromTheSession() async throws {
        let now = Date()
        let followUp = MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: now)
        let sessions = Self.freshSessions()
        try await sessions.save(Self.derivedSession(
            for: followUp,
            conclusion: "深睡回到 1 小时 20 分了，比两周前多 25 分钟。后面几天再看看稳不稳。",
            updatedAt: now
        ))

        let conclusion = await FollowUpRunner.conclusion(for: followUp, in: sessions)
        // 通知那一行放不下一整段,取第一句。存第二份摘要的话,通知上那句和点开看到的
        // 迟早对不上。
        #expect(conclusion == "深睡回到 1 小时 20 分了，比两周前多 25 分钟。")
    }

    @Test("the promise is not restated with two full stops")
    func questionDoesNotDoubleThePunctuation() {
        // 记忆有的写到句号、有的不写。这一句是用户点开会话第一眼看到的东西。
        let withStop = MemoryItem(kind: .followUp, text: "3天后提醒他查看静息心率。")
        let without = MemoryItem(kind: .followUp, text: "3天后提醒他查看静息心率")
        #expect(!FollowUpRunner.question(for: withStop).contains("。。"))
        #expect(FollowUpRunner.question(for: withStop) == FollowUpRunner.question(for: without))
    }

    @Test("a follow-up that was never run has no conclusion to show")
    func noConclusionWithoutARun() async throws {
        let followUp = MemoryItem(kind: .followUp, text: "两周后看深睡", dueAt: Date())
        #expect(await FollowUpRunner.conclusion(for: followUp, in: Self.freshSessions()) == nil)
    }

    @Test("with a conclusion the morning notification says the answer, not the reminder")
    func notificationCarriesTheConclusion() {
        let followUp = MemoryItem(kind: .followUp, text: "他说两周后再看看深睡回来没有", dueAt: Date())
        let answered = CheckInScheduler.content(
            for: .morning,
            situation: HealthSituation(period: .morning, triggers: []),
            dueFollowUps: [followUp],
            followUpConclusions: [followUp.id: "深睡回到 1 小时 20 分了。"]
        )

        // 「说好两周后看深睡」是一句提醒;「深睡回到 1 小时 20 分了」才是他当初定下这个
        // 约定想要的东西。
        #expect(answered.body == "深睡回到 1 小时 20 分了。")
        // 点开还是接着原来那句聊,不是让它把通知上这行再念一遍。
        #expect(answered.question == followUp.text)
        #expect(answered.followUpId == followUp.id)
    }

    @Test("without a conclusion the morning notification still keeps its promise")
    func notificationFallsBackToThePromise() {
        let followUp = MemoryItem(kind: .followUp, text: "他说两周后再看看深睡回来没有", dueAt: Date())
        let plain = CheckInScheduler.content(
            for: .morning,
            situation: HealthSituation(period: .morning, triggers: []),
            dueFollowUps: [followUp]
        )

        // 那一轮没跑成是小事,说好今天回头看却一个字不提是大事。
        #expect(plain.body == followUp.text)
        #expect(plain.followUpId == followUp.id)
    }
}
