import Foundation
import Testing

@testable import AgentRuntime

/// 整条 loop 的集成测试:假模型 + 假能力,但 planner、compactor、calibration、事件归约
/// 全是真的。这三个场景是 agent 循环最容易悄悄坏掉的地方。
@Suite("Agent loop integration")
struct AgentLoopTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    // MARK: - 工具跑完之后用户手动停止

    @Test("stopping right after a tool finishes keeps the result and replays it instead of re-querying")
    func stopAfterToolRun() async {
        let toolOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分\n08-02 | 6 小时 48 分"
        var executions = 0
        let counter = Mutex(0)

        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                // 第二轮永远走不完——用户在工具结果回来之后就按了停止。
                .init(textDeltas: ["这几晚"], finishReason: .init(unified: .stop))
            ]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["sleep_summary": toolOutput]) { _ in counter.increment() },
            systemInstruction: "system"
        )

        let base: [AgentChatMessageDTO] = [.init(role: .user, text: "看看最近睡眠")]
        var history = base
        AgentTurnReducer.startReply(in: &history)

        let started = history
        // 照抄 app 的消费方式:取消的是消费者这个 Task。
        //
        // 坑在这:`AsyncThrowingStream` 的消费者被取消时,`for try await` 是正常结束的,
        // 不抛 `CancellationError`。只 catch 是抓不到"用户按了停止"的,循环出来还得自己看
        // `Task.isCancelled`——否则那条回复会既没文本也没状态地存下去。
        let outcome = await Task { () -> ([AgentChatMessageDTO], Bool, (any Error)?) in
            var local = started
            do {
                for try await event in loop.run(history: base) {
                    AgentTurnReducer.apply(event, in: &local)
                    // 工具刚跑完的那一刻按停止。
                    if case .toolCallFinished = event {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            } catch {
                return (local, Task.isCancelled, error)
            }
            return (local, Task.isCancelled, nil)
        }.value

        history = outcome.0
        #expect(outcome.1)

        AgentTurnReducer.markStopped(in: &history)
        executions = counter.value

        let assistant = try! #require(history.last)
        #expect(assistant.storedTurn.state == .stopped)
        #expect(assistant.textIsPlaceholder)
        // 已经花掉的那次查询要留着,界面上也还看得到结果。
        #expect(assistant.toolCalls.count == 1)
        #expect(assistant.toolCalls.first?.output?.text == toolOutput)
        #expect(executions == 1)

        // 停止之后接着问:上一轮的工具结果照样回放,不该再查一次。
        let planner = ConversationHistoryPlanner(
            systemInstruction: "system",
            profile: Self.profile
        ) { transcript in
            transcript.messages.reduce(0) { $0 + $1.text.count }
        }
        let prepared = planner.prepare(history: history + [.init(role: .user, text: "那深睡呢")])

        #expect(prepared.prompt.contains(toolOutput))
        // app 写给用户的占位不是模型说过的话,不能混进上下文。
        #expect(!prepared.prompt.allText.contains("已停止回复"))
    }

    // MARK: - 长对话触发压缩

    @Test("a long conversation compacts old turns into digests before the request goes out")
    func longConversationCompactsBeforeSending() async {
        let oldOutput = String(repeating: "步数数据很长。", count: 1_200)
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["好的"], finishReason: .init(unified: .stop))],
            tokensPerCharacter: 4
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["daily_steps": "新的一次查询"]),
            systemInstruction: "system"
        )

        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "上个月走了多少"),
            completedAssistant(
                text: "上个月平均一天 9,100 步。",
                toolName: "daily_steps",
                toolOutput: oldOutput,
                context: nil
            ),
            .init(role: .user, text: "那这周呢")
        ]

        let (messages, error) = await collect(loop, history: history)
        #expect(error == nil)

        let prompt = try! #require(client.lastPrompt)
        // 原始工具输出被折叠掉了,但结论和折叠提示都还在——模型知道自己上次查过什么。
        #expect(!prompt.contains(oldOutput))
        #expect(prompt.allText.contains("上个月平均一天 9,100 步。"))
        #expect(prompt.allText.contains("daily_steps"))
        #expect(prompt.allText.contains("folded 1 tool call"))
        // 最后那句用户问题不能被压没了。
        #expect(prompt.allText.contains("那这周呢"))

        let snapshot = try! #require(messages.last?.storedTurn.context)
        #expect(snapshot.compactedAssistantMessages >= 1)
        #expect(snapshot.droppedConversationTurns == 0)
        #expect(snapshot.estimatedPromptTokens ?? 0 <= 20_000 - 2_000)
    }

    // MARK: - 切模型之后继续追问

    @Test("switching to a smaller model migrates history and drops the old model's calibration")
    func modelSwitchMigratesHistoryAndCalibration() async {
        let bigWindowContext = TurnContextSnapshotDTO(
            providerId: "anthropic",
            requestedModelId: "claude-opus-4-8",
            contextWindow: 200_000,
            estimatedPromptTokens: 100,
            // 旧模型上本地估算差了一倍。这把尺子不能拿到新模型上继续用。
            actualPromptTokens: 200
        )
        let detailedOutput = String(repeating: "详细的工具轨迹。", count: 30)
        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "先聊聊上周"),
            completedAssistant(
                text: "上周整体还行。",
                toolName: "daily_steps",
                toolOutput: detailedOutput,
                context: bigWindowContext
            ),
            .init(role: .user, text: "换个模型继续说")
        ]

        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["继续"], finishReason: .init(unified: .stop))]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["daily_steps": "新查询"]),
            systemInstruction: "system"
        )

        let (messages, error) = await collect(loop, history: history)
        #expect(error == nil)

        let prompt = try! #require(client.lastPrompt)
        let snapshot = try! #require(messages.last?.storedTurn.context)

        // 窗口变小了,老的那轮主动换成压缩形态,而不是等 provider 报 400。
        #expect(snapshot.migrationNotes.contains(ConversationHistoryPlanner.modelSwitchNote))
        #expect(snapshot.compactedAssistantMessages == 1)
        #expect(!prompt.contains(detailedOutput))
        #expect(prompt.allText.contains("上周整体还行。"))
        #expect(prompt.messages.contains { !$0.compactionSourceIDs.isEmpty })

        // 校准跟着模型走:换了模型就回到裸估算,不拿旧模型 2 倍的比例去套。
        let rawEstimate = client.estimateTokens(for: .init(
            profile: Self.profile,
            prompt: prompt,
            capabilities: loop.capabilities.definitions
        ))
        #expect(snapshot.estimatedPromptTokens == rawEstimate)
        #expect(ContextCalibration(history: history, profile: Self.profile).scale == nil)

        // 同一个模型的历史才认:换回去就该继续用那把尺子。
        let sameModel = AgentModelProfile(
            providerId: "anthropic",
            modelId: "claude-opus-4-8",
            contextWindow: 200_000
        )
        #expect(ContextCalibration(history: history, profile: sameModel).scale == 2)
    }

    // MARK: -

    private func completedAssistant(
        text: String,
        toolName: String,
        toolOutput: String,
        context: TurnContextSnapshotDTO?
    ) -> AgentChatMessageDTO {
        let callId = "call_\(toolName)"
        return AgentChatMessageDTO(
            role: .assistant,
            text: text,
            toolCalls: [.init(
                id: callId,
                name: toolName,
                input: #"{"days":30}"#,
                output: .init(kind: .table, text: toolOutput)
            )],
            storedTurn: .init(
                exactTranscript: .init(messages: [
                    .init(role: .assistant, parts: [
                        .text(text),
                        .toolCall(.init(toolCallId: callId, toolName: toolName, input: #"{"days":30}"#))
                    ]),
                    .toolResult(toolCallId: callId, toolName: toolName, result: .string(toolOutput))
                ]),
                state: .completed,
                context: context
            )
        )
    }
}

/// 测试里数一下能力被执行了几次。
final class Mutex: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int

    init(_ value: Int) { stored = value }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        stored += 1
        lock.unlock()
    }
}
