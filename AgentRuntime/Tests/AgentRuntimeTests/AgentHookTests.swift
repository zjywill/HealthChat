import Foundation
import Testing

@testable import AgentRuntime

/// 生命周期上的旁观位。
///
/// 要验的是那四条边界,而它们坏掉的时候都不报错:hook 拖住了用户在等的这一轮、某一轮悄无声
/// 息地没有收尾通知(hook 只能靠超时去猜)、一个慢 hook 连着把别的也拖住、delta 被当成边界
/// 一路派发出去。
@Suite("Agent hooks")
struct AgentHookTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    /// 把收到的通知按序记下来。可选地在第一条上挂住,用来验「loop 有没有等它」。
    private final class Recorder: AgentHook, @unchecked Sendable {
        private let lock = NSLock()
        private var _notices: [AgentHookNotice] = []
        private let gate: Gate?

        init(gate: Gate? = nil) { self.gate = gate }

        var notices: [AgentHookNotice] {
            lock.withLock { _notices }
        }

        var kinds: [String] { notices.map(\.label) }

        var turnOutcome: AgentHookTurnOutcome? {
            notices.reversed().compactMap {
                if case .turnFinished(let outcome) = $0.kind { outcome } else { nil }
            }.first
        }

        func observe(_ notice: AgentHookNotice) async {
            await gate?.wait()
            lock.withLock { _notices.append(notice) }
        }
    }

    /// 一道手动放开的闸。测「不阻塞」只能靠把 hook 真的挂住,sleep 那种是看谁跑得快。
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

    private static func loop(
        _ hooks: AgentHookDispatcher,
        turns: [ScriptedModelClient.Turn],
        toolOutput: String = "最近 7 天睡眠\n08-01 | 7 小时 12 分",
        maxToolRounds: Int = 6
    ) -> (AgentLoop, ScriptedModelClient) {
        let client = ScriptedModelClient(profile: profile, turns: turns)
        return (
            AgentLoop(
                client: client,
                capabilities: stubRegistry(["sleep_summary": toolOutput]),
                systemInstruction: "system",
                retryPolicy: RetryPolicy(baseDelay: .zero, maxDelay: .zero),
                maxToolRounds: maxToolRounds,
                hooks: hooks
            ),
            client
        )
    }

    private static let askedAboutSleep: [AgentChatMessageDTO] = [
        .init(role: .user, text: "看看最近睡眠")
    ]

    // MARK: - 边界

    @Test("a hook sees the boundaries in order, and never a delta")
    func hookSeesBoundariesInOrder() async {
        let recorder = Recorder()
        let dispatcher = AgentHookDispatcher([recorder])
        // 正文切成很多片发:通知的条数不该跟着变——delta 是那条通道的事。
        let (loop, _) = Self.loop(dispatcher, turns: [
            .init(
                toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: #"{"days":7}"#)],
                finishReason: .init(unified: .toolCalls)
            ),
            .init(
                textDeltas: ["这", "几", "天", "睡", "得", "还", "行"],
                finishReason: .init(unified: .stop),
                usage: .init(inputTokens: .init(total: 1_234))
            )
        ])

        let outcome = await record(loop, history: Self.askedAboutSleep)
        #expect(outcome.error == nil)
        await dispatcher.settle()

        #expect(recorder.kinds == ["turnStarted", "toolFinished", "turnFinished"])

        guard case .turnStarted(let start) = recorder.notices.first?.kind else {
            Issue.record("第一条应该是 turnStarted")
            return
        }
        // 开跑时的历史带在通知里:hook 真正跑起来的时候 app 那边的状态可能已经变了。
        #expect(start.history.map(\.text) == ["看看最近睡眠"])
        #expect(start.profile.modelId == "claude-sonnet-5")

        guard case .toolFinished(let tool) = recorder.notices[1].kind else {
            Issue.record("第二条应该是 toolFinished")
            return
        }
        #expect(tool.name == "sleep_summary")
        #expect(!tool.isError)
        #expect(tool.outputCharacters > 0)

        let finished = try! #require(recorder.turnOutcome)
        #expect(finished.state == .completed)
        #expect(finished.finishReason?.unified == .stop)
        #expect(finished.usage?.inputTokens.total == 1_234)
        #expect(finished.context?.providerId == "anthropic")
        // 交给 hook 的就是存进会话、回放给模型的那一份:工具结果和拼好的正文都在里面。
        #expect(finished.transcript.contains("7 小时 12 分"))
        #expect(finished.transcript.allText.contains("这几天睡得还行"))
        // 同一轮的通知带同一个 turnId——hook 多半是跨轮有状态的,分不出轮次就无从作废。
        #expect(Set(recorder.notices.map(\.turnId)).count == 1)
    }

    @Test("每一轮都有收尾通知：轮数用光也算答完，不是失败")
    func toolRoundLimitFinishesAsCompleted() async {
        let recorder = Recorder()
        let dispatcher = AgentHookDispatcher([recorder])
        let calling = ScriptedModelClient.Turn(
            toolCalls: [.init(toolCallId: "call", name: "sleep_summary", input: "{}")],
            finishReason: .init(unified: .toolCalls)
        )
        let (loop, _) = Self.loop(
            dispatcher,
            turns: Array(repeating: calling, count: 4),
            maxToolRounds: 2
        )

        let outcome = await record(loop, history: Self.askedAboutSleep)
        #expect(outcome.error == nil)
        await dispatcher.settle()

        let finished = try! #require(recorder.turnOutcome)
        // 用光轮数不是错误:已经查到的东西全在,要区分的看 raw。
        #expect(finished.state == .completed)
        #expect(finished.finishReason?.raw == AgentLoop.toolRoundLimitReason)
        #expect(recorder.kinds.filter { $0 == "toolFinished" }.count == 2)
    }

    @Test("用户按停止：收尾通知照样到，已经查到的东西带在里面")
    func stoppedTurnStillFinishes() async {
        let recorder = Recorder()
        let dispatcher = AgentHookDispatcher([recorder])
        let toolOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分"
        let (loop, _) = Self.loop(
            dispatcher,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["还行"], finishReason: .init(unified: .stop))
            ],
            toolOutput: toolOutput
        )

        // 照抄 app 的消费方式:取消的是消费者这个 Task。
        await Task {
            // 消费者被取消时 `for try await` 是**正常**结束的,不抛 CancellationError。
            try? await { () async throws in
                for try await event in loop.run(history: Self.askedAboutSleep) {
                    if case .toolCallFinished = event {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }()
        }.value
        // 停止那条通知**在流结束之后才到**:消费者一撒手,loop 那边还要被取消、退栈,才走到
        // 收尾。这正是「hook 不在用户等的那条路上」的另一面,所以这里只能等,不能假设它已经到了。
        try! await waitFor("停止那一轮的收尾通知") { recorder.turnOutcome != nil }
        await dispatcher.settle()

        let finished = try! #require(recorder.turnOutcome)
        // 被停掉的那一轮如果不发通知,hook 只能靠超时去猜自己在等的那一轮还会不会来。
        #expect(finished.state == .stopped)
        #expect(finished.transcript.contains(toolOutput))
    }

    @Test("救不回来的错误：state 带上原文，重试过程不额外发通知")
    func failedTurnCarriesTheReason() async {
        let recorder = Recorder()
        let dispatcher = AgentHookDispatcher([recorder])
        // 鉴权错误不重试:对着「key 不对」重试三次只是把同一句话说三遍。
        let (loop, client) = Self.loop(dispatcher, turns: [
            .init(failureMessage: "invalid api key")
        ])

        let outcome = await record(loop, history: Self.askedAboutSleep)
        #expect(outcome.error != nil)
        await dispatcher.settle()

        let finished = try! #require(recorder.turnOutcome)
        #expect(finished.state == .failed("invalid api key"))
        #expect(client.requests.count == 1)
        #expect(recorder.kinds == ["turnStarted", "turnFinished"])
    }

    // MARK: - 不阻塞,不互相拖累

    @Test("a stuck hook holds up neither the reply nor the other hooks")
    func aStuckHookHoldsUpNothing() async {
        let gate = Gate()
        let stuck = Recorder(gate: gate)
        let free = Recorder()
        let dispatcher = AgentHookDispatcher([stuck, free])
        let (loop, _) = Self.loop(dispatcher, turns: [
            .init(textDeltas: ["还行"], finishReason: .init(unified: .stop))
        ])

        // 一个 hook 挂在第一条通知上,这一轮照样跑完:等它就等于让用户多等一个字。
        let outcome = await record(loop, history: Self.askedAboutSleep)
        #expect(outcome.error == nil)
        #expect(stuck.notices.isEmpty)

        // 别的 hook 不跟着一起挂住——各有一条尾巴。
        try! await waitFor("没挂住的那个收全") { free.kinds.count == 2 }
        #expect(free.kinds == ["turnStarted", "turnFinished"])

        await gate.open()
        await dispatcher.settle()
        // 放开之后一条不少,而且还是原来的顺序。
        #expect(stuck.kinds == ["turnStarted", "turnFinished"])
    }

    @Test("同一个 hook 跨轮按顺序收：上一轮的收尾排在下一轮的开场前面")
    func noticesStayOrderedAcrossTurns() async {
        let recorder = Recorder()
        let dispatcher = AgentHookDispatcher([recorder])

        for _ in 0..<2 {
            let (loop, _) = Self.loop(dispatcher, turns: [
                .init(textDeltas: ["还行"], finishReason: .init(unified: .stop))
            ])
            _ = await record(loop, history: Self.askedAboutSleep)
        }
        await dispatcher.settle()

        // 宿主活得比一轮长,靠的就是这个顺序:「上一轮答完了」和「下一轮开跑了」倒过来,
        // 答完之后要生成的那点东西就会被自己作废。
        #expect(recorder.kinds == ["turnStarted", "turnFinished", "turnStarted", "turnFinished"])
        let turnIds = recorder.notices.map(\.turnId)
        #expect(turnIds[0] == turnIds[1])
        #expect(turnIds[2] == turnIds[3])
        #expect(turnIds[0] != turnIds[2])
    }

    @Test("没挂 hook 的那条路一次派发都不发生")
    func noHooksMeansNoDispatch() async {
        let (loop, _) = Self.loop(AgentHookDispatcher([]), turns: [
            .init(textDeltas: ["还行"], finishReason: .init(unified: .stop))
        ])
        var bare = loop
        bare.hooks = nil

        let outcome = await record(bare, history: Self.askedAboutSleep)
        #expect(outcome.error == nil)
        #expect(outcome.events.finishReason?.unified == .stop)
    }
}

private extension AgentHookNotice {
    var label: String {
        switch kind {
        case .turnStarted: "turnStarted"
        case .toolFinished: "toolFinished"
        case .turnFinished: "turnFinished"
        }
    }
}

private struct HookWaitTimeout: Error, CustomStringConvertible {
    let description: String
}

/// 轮询等一个条件。挂住的那个 hook 不能用 `settle()` 等——那正是会死等的地方。
private func waitFor(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            throw HookWaitTimeout(description: "等 \(what) 超时")
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
