import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 答完一轮之后生成的那几条追问 chip。
///
/// 它挂在 `AgentHook` 上,所以这里连着验两件事:hook 那套通知够不够写出一条追问(材料分在
/// 两条通知里),以及几种"不该生成"的情况有没有真的不生成——多花一次调用用户看不见,而
/// 三条接不上屏幕的追问他一眼就会看见。
@Suite("Follow-up chips")
struct FollowUpChipTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    private static let sleepOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分\n08-02 | 6 小时 04 分"

    /// 记下每次生成拿到的材料和交付出去的东西。可以挂在闸上,用来制造「还在生成时下一轮开跑」。
    private final class Spy: @unchecked Sendable {
        private let lock = NSLock()
        private var _contexts: [FollowUpContext] = []
        private var _delivered: [[String]] = []
        private let gate: Gate?
        private let answer: [String]

        init(returning answer: [String] = ["那第三天呢", "为什么会这样", "白天累不累"], gate: Gate? = nil) {
            self.answer = answer
            self.gate = gate
        }

        var contexts: [FollowUpContext] { lock.withLock { _contexts } }
        var delivered: [[String]] { lock.withLock { _delivered } }

        func hook() -> FollowUpSuggestionHook {
            FollowUpSuggestionHook(
                generate: { [self] context in
                    lock.withLock { _contexts.append(context) }
                    await gate?.wait()
                    return answer
                },
                deliver: { [self] suggestions in
                    lock.withLock { _delivered.append(suggestions) }
                }
            )
        }
    }

    private actor Gate {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiting.append($0) }
        }

        func open() {
            isOpen = true
            for continuation in waiting { continuation.resume() }
            waiting.removeAll()
        }
    }

    private static func engine(
        _ hooks: AgentHookDispatcher,
        turns: [ScriptedModelClient.Turn]
    ) -> LoopEngine {
        var engine = LoopEngine(
            client: ScriptedModelClient(profile: profile, turns: turns),
            capabilities: stubRegistry(["sleep_summary": sleepOutput])
        )
        engine.hooks = hooks
        return engine
    }

    /// 照 app 的方式跑一轮:事件流抽干就算这一轮结束。
    private static func run(
        _ engine: LoopEngine,
        history: [ChatMessage],
        stoppingAfterTool: Bool = false
    ) async {
        let task = Task {
            try? await { () async throws in
                for try await event in engine.reply(to: history) {
                    if stoppingAfterTool, case .toolCallFinished = event {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }()
        }
        await task.value
    }

    // MARK: - 材料

    @Test("答完一轮：问句、回答和工具名字凑齐，工具的原始数字一个都不带")
    func materialsComeFromBothNotices() async throws {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: #"{"days":7}"#)],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(text: "这两晚都不到 7 小时，周末补了一点", finishReason: .init(unified: .stop))
        ])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        await dispatcher.settle()
        // 生成和交付挂在 hook 自己的 Task 上,`settle()` 等的是通知派发——它们不在 loop 那条
        // 路上,本来就等不到。
        try await waitFor("交付") { spy.delivered.count == 1 }

        let context = try #require(spy.contexts.first)
        // 问句在 `turnStarted` 的历史里,回答在 `turnFinished` 的 transcript 里——材料本来
        // 就分在两条通知上,认错一条就会拿上一句去配这一段回答。
        #expect(context.question == "最近睡得怎么样")
        #expect(context.answer == "这两晚都不到 7 小时，周末补了一点")
        #expect(context.toolNames == ["sleep_summary"])
        // 查过什么有用,查出来的数字没用:它明天就过期了,而这一次生成要为它多付一整段钱。
        #expect(!context.answer.contains("7 小时 12 分"))
        let request = FollowUpSuggester.request(for: context)
        #expect(!request.contains("7 小时 12 分"))
        #expect(request.contains("sleep_summary"))

        #expect(spy.delivered == [["那第三天呢", "为什么会这样", "白天累不累"]])
    }

    @Test("中途插的那句也算他问的")
    func interjectionCountsAsPartOfTheQuestion() async throws {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(text: "睡眠和心率都看了", finishReason: .init(unified: .stop))
        ])

        // 第一个边界(第一次请求之前)空着,第二个边界才有——「他在模型查数据的时候补了一句」。
        let queue = QueuedBatches([[], [AgentPendingInput(text: "顺便也看看心率")]])
        let task = Task {
            try? await { () async throws in
                for try await _ in engine.reply(
                    to: [ChatMessage(role: .user, text: "最近睡得怎么样")],
                    pendingInput: { queue.take() }
                ) {}
            }()
        }
        await task.value
        await dispatcher.settle()
        try await waitFor("生成跑起来") { spy.contexts.count == 1 }

        let context = try #require(spy.contexts.first)
        #expect(context.question.contains("最近睡得怎么样"))
        // 不带上它,生成的三条会绕开他刚补的那句问下去——那正是他不想再听的。
        #expect(context.question.contains("顺便也看看心率"))
    }

    // MARK: - 不生成

    @Test("按了停止的那一轮不生成：他要按的是重试，不是追问")
    func stoppedTurnGeneratesNothing() async {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "c1", name: "sleep_summary", input: "{}")],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(text: "看完了", finishReason: .init(unified: .stop))
        ])

        await Self.run(
            engine,
            history: [ChatMessage(role: .user, text: "最近睡得怎么样")],
            stoppingAfterTool: true
        )
        // 停止那条收尾通知在流结束之后才到,所以这里等一等再看——不等的话这个测试会因为
        // "还没来得及生成"而假过。
        try? await Task.sleep(for: .milliseconds(200))
        await dispatcher.settle()

        #expect(spy.contexts.isEmpty)
        #expect(spy.delivered.isEmpty)
    }

    @Test("报错的那一轮不生成")
    func failedTurnGeneratesNothing() async {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [.init(failureMessage: "invalid api key")])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        try? await Task.sleep(for: .milliseconds(200))
        await dispatcher.settle()

        #expect(spy.contexts.isEmpty)
    }

    @Test("助手一个字没说就不生成")
    func silentTurnGeneratesNothing() async {
        let spy = Spy()
        let dispatcher = AgentHookDispatcher([spy.hook()])
        let engine = Self.engine(dispatcher, turns: [.init(finishReason: .init(unified: .stop))])

        await Self.run(engine, history: [ChatMessage(role: .user, text: "最近睡得怎么样")])
        await dispatcher.settle()

        #expect(spy.contexts.isEmpty)
    }

    @Test("下一轮开跑就作废：还在写的那几条不会摆到新回答下面")
    func nextTurnSupersedesTheSuggestionsInFlight() async throws {
        let gate = Gate()
        let spy = Spy(gate: gate)
        let hook = spy.hook()
        let dispatcher = AgentHookDispatcher([hook])

        // 第一轮答完,生成挂在闸上;紧接着第二轮开跑——这正是插话续跑时的形状。
        await Self.run(
            Self.engine(dispatcher, turns: [.init(text: "第一段", finishReason: .init(unified: .stop))]),
            history: [ChatMessage(role: .user, text: "最近睡得怎么样")]
        )
        await dispatcher.settle()
        try await waitFor("第一轮那次生成挂在闸上") { spy.contexts.count == 1 }
        #expect(spy.delivered.isEmpty)

        await Self.run(
            Self.engine(dispatcher, turns: [.init(text: "第二段", finishReason: .init(unified: .stop))]),
            history: [ChatMessage(role: .user, text: "那心率呢")]
        )
        await gate.open()
        await dispatcher.settle()
        // `settle()` 只等通知派发完,等不到生成那一步——它本来就不在 loop 的那条路上。
        try await waitFor("第二轮那几条交付") { spy.delivered.count == 1 }
        // 放开之后再给第一轮那次一点时间:它要是也交付了,这里会变成 2。
        try? await Task.sleep(for: .milliseconds(100))

        // 两轮各生成了一次,但只交付一次:第一轮那几条接的是"最近睡得怎么样",而屏幕上已经
        // 多了一段关于心率的回答。
        #expect(spy.contexts.count == 2)
        #expect(spy.contexts.last?.question == "那心率呢")
        #expect(spy.delivered.count == 1)
    }

    // MARK: - 收尾

    @Test("剥掉壳、筛掉放不下的，够两条就用")
    func parsingKeepsWhatFits() {
        #expect(FollowUpSuggester.parse("1. 那第三天呢\n- 为什么会这样\n「白天累不累」") == [
            "那第三天呢", "为什么会这样", "白天累不累"
        ])
        // 超长的那行放不进 chip,等于没写;剩下两条照用。
        //
        // 门槛不设在"恰好三条":中文追问写到十一二个字很常见,一条超长就把另外两条也带走,
        // 而那条路径是静默的——界面上只表现为"没生成"。
        #expect(FollowUpSuggester.parse("""
            那第三天呢
            为什么会这样
            这一条特别特别长，长到一个按钮根本放不下它
            """) == ["那第三天呢", "为什么会这样"])
        // 只剩一条就整体作废:一颗生成的加一颗固定的,长短语气都不一样,比少一颗更像坏了。
        #expect(FollowUpSuggester.parse("那第三天呢").isEmpty)
        #expect(FollowUpSuggester.parse("").isEmpty)
    }

    @Test("答案太长时保头保尾")
    func aLongAnswerKeepsBothEnds() {
        let answer = String(repeating: "头", count: 700)
            + String(repeating: "中", count: 3_000)
            + String(repeating: "尾", count: 700)
        let request = FollowUpSuggester.request(for: .init(question: "问", answer: answer))

        #expect(request.contains(String(repeating: "头", count: 600)))
        #expect(request.contains(String(repeating: "尾", count: 600)))
        // 丢掉的中段是把数据一天天念过去的那部分,对"接着问什么"没有贡献。
        #expect(request.count < answer.count)
    }
}

/// 轮询等一个条件。生成那一步不在 `settle()` 等得到的范围里(它挂在 hook 自己的 Task 上),
/// 所以只能等条件成立。
private func waitFor(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw WaitTimeout(description: "等 \(what) 超时")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// 按次数发号的排队消息。
private final class QueuedBatches: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [[AgentPendingInput]]

    init(_ batches: [[AgentPendingInput]]) { remaining = batches }

    func take() -> [AgentPendingInput] {
        lock.withLock { remaining.isEmpty ? [] : remaining.removeFirst() }
    }
}
