import Foundation
import Testing
import AgentRuntime

@testable import HealthChat

/// 跨会话召回:翻得到、编号不乱、不该看到的看不到。
///
/// 这套东西的胜负手是**召回精度不是召回广度**。模型说「我们上次说过…」而用户根本不记得
/// 说过,或者把三个月前的数字当成本周的讲,那一瞬间信任掉得比从没记住过还快。所以这里盯的
/// 大半是"不该发生什么":编号不许错位、删掉的不许还在、当前会话不许被当成历史读回来、
/// 读出来的每一段都得带着日期和那句「数值以本次工具为准」。
///
/// 每条测试都开自己的临时目录。app 侧测试跑在 app host 里,`SessionStore.shared` 就是
/// 模拟器上那份真的会话——测试写它等于动用户的对话。
@Suite("SessionRecall")
struct SessionRecallTests {

    private static func freshStore() -> SessionStore {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SessionStore(parent: directory)
    }

    private static func session(
        _ userText: String,
        reply: String = "",
        tools: [String] = [],
        topicId: String? = nil,
        createdAt: Date,
        updatedAt: Date? = nil
    ) -> ChatSession {
        var messages = [ChatMessage(role: .user, text: userText)]
        if !reply.isEmpty || !tools.isEmpty {
            messages.append(ChatMessage(
                role: .assistant,
                text: reply,
                toolCalls: tools.map {
                    ToolCallRecord(id: UUID().uuidString, name: $0, input: "{}", output: "…")
                }
            ))
        }
        return ChatSession(
            messages: messages,
            topicId: topicId,
            createdAt: createdAt,
            updatedAt: updatedAt ?? createdAt
        )
    }

    private static let day: TimeInterval = 86_400

    // MARK: - 编号

    @Test("handles follow creation order, so a later save never renumbers anything")
    func handlesSurviveASave() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let oldest = Self.session("三月那次出差", createdAt: base)
        var newest = Self.session("这周睡得不好", createdAt: base + 2 * Self.day)
        try await store.save(oldest)
        try await store.save(newest)

        let before = await store.recallIndex()
        #expect(before.digest(handle: "S1")?.id == oldest.id)
        #expect(before.digest(handle: "S2")?.id == newest.id)

        // 把新的那条更新一下。按 `updatedAt` 发号的话这里就该错位了——而上一句里模型说的
        // 「S1」会突然指到另一条对话去。
        newest.messages.append(ChatMessage(role: .user, text: "那前天呢"))
        newest.updatedAt = base + 10 * Self.day
        try await store.save(newest)

        let after = await store.recallIndex()
        #expect(after.digest(handle: "S1")?.id == oldest.id)
        #expect(after.digest(handle: "S2")?.id == newest.id)
    }

    @Test("excluding the current session does not shift the other handles")
    func excludingCurrentKeepsHandles() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let first = Self.session("一", createdAt: base)
        let second = Self.session("二", createdAt: base + Self.day)
        let third = Self.session("三", createdAt: base + 2 * Self.day)
        for one in [first, second, third] { try await store.save(one) }

        // 排除放在发号之前的话,S3 会变成第三条之外的另一条。
        let index = await store.recallIndex(excluding: second.id)
        #expect(index.digest(handle: "S1")?.id == first.id)
        #expect(index.digest(handle: "S3")?.id == third.id)
        #expect(index.digest(handle: "S2") == nil)
    }

    // MARK: - 不该看到的

    @Test("the session in progress is not recallable as history")
    func currentSessionIsExcluded() async throws {
        let store = Self.freshStore()
        let current = Self.session("我现在问的这句", createdAt: Date())
        try await store.save(current)

        let index = await store.recallIndex(excluding: current.id)
        // 不排掉的话模型会把自己刚说过的话当成「上次」读回来。
        #expect(index.search(query: "现在").isEmpty)
    }

    @Test("a deleted session leaves the index immediately")
    func deletedSessionDisappears() async throws {
        let store = Self.freshStore()
        let doomed = Self.session("这段我不想留着", createdAt: Date())
        try await store.save(doomed)
        // 先读一次把索引缓存住,再删——缓存没被清掉的话下面这条会挂。
        #expect(await store.recallIndex().digests.count == 1)

        try await store.delete(id: doomed.id)

        // 用户刚把这段对话删了,下一句还能被模型引用出来,是这套东西最难解释的一种失灵。
        #expect(await store.recallIndex().isEmpty)
    }

    @Test("an empty session is not something to recall")
    func emptySessionsAreSkipped() async throws {
        let store = Self.freshStore()
        try await store.save(ChatSession(createdAt: Date()))
        try await store.save(Self.session("真的聊了点什么", createdAt: Date()))

        // 空会话占一个编号,后面每条的编号就跟着它的存亡漂移;而它本身也没什么可读的。
        let index = await store.recallIndex()
        #expect(index.digests.count == 1)
        #expect(index.digest(handle: "S1")?.title == "真的聊了点什么")
    }

    // MARK: - 检索

    @Test("search matches the user's own words, not the assistant's catch-all replies")
    func searchScoresUserWords() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let aboutSleep = Self.session(
            "我最近老是三四点醒，是不是加班太多",
            reply: "看下来主要落在周三。",
            tools: ["sleep_summary"],
            createdAt: base
        )
        // 助手那段什么都提一句。把它算进打分,每条会话都能匹配上任何查询,检索就退化成了
        // 按时间倒序。
        let aboutSteps = Self.session(
            "今天走了多少步",
            reply: "睡眠、心率、活动量看下来都还行，加班那几天也没什么异常。",
            tools: ["daily_steps"],
            createdAt: base + Self.day
        )
        for one in [aboutSleep, aboutSteps] { try await store.save(one) }

        let index = await store.recallIndex()
        let hits = index.search(query: "加班 睡眠")
        #expect(hits.first?.id == aboutSleep.id)
    }

    @Test("an empty query returns the most recent conversations")
    func emptyQueryReturnsRecent() async throws {
        let store = Self.freshStore()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let older = Self.session("很久以前", createdAt: base)
        let newer = Self.session("最近", createdAt: base + 5 * Self.day)
        for one in [older, newer] { try await store.save(one) }

        // 「上次我们聊到哪了」是个合法的问法,不该被当成"没有查询词"挡回去。
        let hits = await store.recallIndex().search(query: "")
        #expect(hits.first?.id == newer.id)
        #expect(hits.count == 2)
    }

    // MARK: - 读回来的样子

    @Test("a recalled transcript carries its date and the numbers-are-stale line")
    func transcriptCarriesDateAndDisclaimer() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let session = Self.session(
            "上周睡得怎么样",
            reply: "平均 6 小时 10 分，比你平时少。",
            tools: ["sleep_summary"],
            createdAt: when
        )
        let now = when + 90 * Self.day
        let text = SessionRecallTranscript.text(for: session, now: now)

        #expect(text.contains(SessionRecall.dateLabel(when, now: now)))
        #expect(text.contains("上周睡得怎么样"))
        #expect(text.contains("平均 6 小时 10 分"))
        // 当时查了什么要留着(结论建立在哪些数据上),但这一行不许带数字回来。
        #expect(text.contains("当时查了：睡眠"))
        // 这是整套召回最要紧的防线。没有它,模型会拿三个月前的 6 小时 10 分当本周讲。
        #expect(text.contains(SessionRecallTranscript.footer))
    }

    @Test("the chip's date comes from the same line the model reads")
    func chipDateComesFromTheOutput() throws {
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let text = SessionRecallTranscript.text(
            for: Self.session("上周睡得怎么样", reply: "还行。", createdAt: when),
            now: when
        )

        // 一轮里常常连着回顾好几次,三个一模一样的胶囊等于没说。日期从输出里取,
        // 胶囊上那天和点开看到的那天就不可能对不上。
        #expect(SessionRecallTranscript.dateLabel(inOutput: text) == SessionRecall.dateLabel(when, now: when))
        #expect(SessionRecallTranscript.dateLabel(inOutput: nil) == nil)
        #expect(SessionRecallTranscript.dateLabel(inOutput: "没有编号为 S99 的对话。") == nil)
    }

    @Test("app-written placeholders are not read back as things the model said")
    func placeholdersAreNotRecalled() throws {
        var stopped = ChatMessage(role: .assistant, text: "已停止回复")
        stopped.textIsPlaceholder = true
        let session = ChatSession(
            messages: [ChatMessage(role: .user, text: "帮我看看心率"), stopped],
            createdAt: Date()
        )

        let text = SessionRecallTranscript.text(for: session)
        // 「已停止回复」是 app 写给用户的,不是模型说过的话。读回来只会让它去解释一句
        // 自己没说过的话。
        #expect(!text.contains("已停止回复"))
        #expect(text.contains("帮我看看心率"))
    }

    @Test("an over-long conversation keeps the question and the conclusion")
    func longTranscriptKeepsHeadAndTail() throws {
        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "帮我分析一下这三个月的睡眠")]
        for index in 0..<40 {
            messages.append(ChatMessage(role: .assistant, text: String(repeating: "中间的过程\(index)", count: 12)))
            messages.append(ChatMessage(role: .user, text: "那第\(index)周呢"))
        }
        messages.append(ChatMessage(role: .assistant, text: "结论是周三最差。"))
        let session = ChatSession(messages: messages, createdAt: Date())

        let text = SessionRecallTranscript.text(for: session)
        #expect(text.count < SessionRecallTranscript.maxCharacters + SessionRecallTranscript.footer.count + 200)
        // 开头是他当时在问什么,结尾是聊出来的结论。被丢掉的中间那段是查数据的过程——
        // 而过程恰恰是最该现查一遍、最不值得读回来的。
        #expect(text.contains("帮我分析一下这三个月的睡眠"))
        #expect(text.contains("结论是周三最差。"))
        #expect(text.contains("中间"))
    }

    // MARK: - 工具

    @Test("read_session refuses a handle that search never handed out")
    func readRejectsUnknownHandle() async throws {
        let store = Self.freshStore()
        try await store.save(Self.session("一次对话", createdAt: Date()))

        let registry = SessionRecallTools.registry(store: store)
        let result = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.readToolName,
            input: #"{"id":"S99"}"#
        ))
        // 报成错误,模型才会退回去先 search 一次;悄悄返回空的话它会当作"那次对话没内容"。
        #expect(result.isError)
    }

    @Test("finding nothing is an answer, not a tool failure")
    func emptySearchIsNotAnError() async throws {
        let store = Self.freshStore()
        try await store.save(Self.session("今天走了多少步", createdAt: Date()))

        let registry = SessionRecallTools.registry(store: store)
        let result = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.searchToolName,
            input: #"{"query":"膝盖 手术"}"#
        ))
        // 「以前没聊过这个」是有效答案,模型据此就该老老实实去查数据。报成错误它会以为工具
        // 坏了,换个说法再试一次,白花一轮。
        #expect(!result.isError)
        #expect(result.output.text.contains("没有找到"))
    }

    @Test("search then read walks the same handle end to end")
    func searchThenReadRoundTrip() async throws {
        let store = Self.freshStore()
        let target = Self.session(
            "我睡眠差是不是因为加班",
            reply: "对上了，差的那几天都是周三。",
            tools: ["sleep_summary"],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.save(target)

        let registry = SessionRecallTools.registry(store: store)
        let found = await registry.execute(CapabilityInvocation(
            toolCallId: "1",
            name: SessionRecallTools.searchToolName,
            input: #"{"query":"加班"}"#
        ))
        let handle = try #require(await store.recallIndex().digests.first?.handle)
        #expect(found.output.text.contains(handle))

        let read = await registry.execute(CapabilityInvocation(
            toolCallId: "2",
            name: SessionRecallTools.readToolName,
            input: #"{"id":"\#(handle)"}"#
        ))
        #expect(!read.isError)
        #expect(read.output.text.contains("差的那几天都是周三"))
    }
}
