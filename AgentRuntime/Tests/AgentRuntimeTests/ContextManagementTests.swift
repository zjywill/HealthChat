import Foundation
import Testing

@testable import AgentRuntime

/// 真正的上下文管理:跨过水位线就叫模型把远处的对话总结掉,结果存下来复用,总结失败也不能
/// 把用户这一句问不出去。
@Suite("Context management")
struct ContextManagementTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 12_000,
        maxOutputTokens: 4_000
    )

    // MARK: -

    @Test("crossing the threshold summarizes the older span before the request goes out")
    func thresholdTriggersSummarization() async {
        let summarizer = RecordingSummarizer(
            visible: "聊过上个月的步数和睡眠。",
            replay: "结论：上个月日均 9,100 步。已调用 daily_steps(days=30)，返回 08-01 至 08-30 的逐日步数。"
        )
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["好的"], finishReason: .init(unified: .stop))]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["daily_steps": "新的"]),
            systemInstruction: "system",
            summarizer: summarizer
        )

        let history = conversation(turnCount: 3)
        let (messages, error) = await collect(loop, history: history)
        #expect(error == nil)

        // 模型被叫去写了摘要,而且只写了一次。
        #expect(summarizer.calls.count == 1)
        let plan = try! #require(summarizer.calls.first)
        // 摊平的原文里工具结果也在——最值钱的数字就在那儿,不能只摊 text。
        #expect(plan.spanText.contains("[result] daily_steps"))

        let prompt = try! #require(client.lastPrompt)
        // 远处那两轮的原始数据换成了摘要。
        #expect(!prompt.contains(Self.output(turn: 1)))
        #expect(!prompt.contains(Self.output(turn: 2)))
        #expect(prompt.allText.contains("结论：上个月日均 9,100 步。"))
        // 最近两轮原样留着——刚查完的数据被压掉,下一句"那第三天呢"就答不上来了。
        #expect(prompt.allText.contains("第 3 问"))
        #expect(prompt.contains(Self.output(turn: 3)))

        let snapshot = try! #require(messages.last?.storedTurn.context)
        #expect(snapshot.summarizedSpans == 1)
        #expect(!snapshot.exceedsBudget_placeholder)
    }

    @Test("the generated artifact is handed back so it is never recomputed")
    func artifactIsPersistedAndReused() async {
        let summarizer = RecordingSummarizer(visible: "看过了。", replay: "要点：日均 9,100 步。")
        let registry = stubRegistry(["daily_steps": "新的"])

        var history = conversation(turnCount: 3)
        let first = AgentLoop(
            client: ScriptedModelClient(
                profile: Self.profile,
                turns: [.init(textDeltas: ["好的"], finishReason: .init(unified: .stop))]
            ),
            capabilities: registry,
            systemInstruction: "system",
            summarizer: summarizer
        )
        let (afterFirst, firstError) = await collect(first, history: history)
        #expect(firstError == nil)
        #expect(summarizer.calls.count == 1)

        // app 把 `.historyCompacted` 写回了会话——下一轮拿到的历史里已经带着 artifact。
        history = afterFirst
        let owner = try! #require(history.first { $0.storedTurn.compaction?.kind == .modelGenerated })
        #expect(owner.storedTurn.compaction?.visibleSummary == "看过了。")
        #expect((owner.storedTurn.compaction?.sourceMessageIDs.count ?? 0) > 1)

        history.append(.init(role: .user, text: "再问一句"))
        let secondClient = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["再答"], finishReason: .init(unified: .stop))]
        )
        let second = AgentLoop(
            client: secondClient,
            capabilities: registry,
            systemInstruction: "system",
            summarizer: summarizer
        )
        let (_, secondError) = await collect(second, history: history)
        #expect(secondError == nil)

        // 同一段没有被重新总结一遍——总结是真金白银的一次调用。
        #expect(summarizer.calls.count == 1)
        #expect(secondClient.lastPrompt?.allText.contains("要点：日均 9,100 步。") == true)
        #expect(secondClient.lastPrompt?.contains(Self.output(turn: 1)) == false)
    }

    @Test("a failing summarizer falls back to mechanical compaction instead of failing the turn")
    func summarizerFailureFallsBack() async {
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["好的"], finishReason: .init(unified: .stop))]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["daily_steps": "新的"]),
            systemInstruction: "system",
            summarizer: FailingSummarizer()
        )

        let (messages, error) = await collect(loop, history: conversation(turnCount: 3))

        // 总结只是省 token 的手段,它挂了不该让用户这一句问不出去。
        #expect(error == nil)
        #expect(messages.last?.text == "好的")
        let prompt = try! #require(client.lastPrompt)
        #expect(!prompt.contains(Self.output(turn: 1)))
        // 退回机械压缩:折叠提示还在,只是不如模型写的摘要省。
        #expect(prompt.allText.contains("folded 1 tool call"))
    }

    @Test("a short conversation is never summarized")
    func shortConversationIsLeftAlone() async {
        let summarizer = RecordingSummarizer(visible: "不该被调用", replay: "不该被调用")
        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [.init(textDeltas: ["好的"], finishReason: .init(unified: .stop))]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["daily_steps": "短"]),
            systemInstruction: "system",
            summarizer: summarizer
        )

        let (_, error) = await collect(loop, history: conversation(turnCount: 2, size: 1))

        #expect(error == nil)
        #expect(summarizer.calls.isEmpty)
    }

    // MARK: -

    /// 每轮的工具输出各不相同,才分得清哪一轮被压掉了、哪一轮被保住了。
    static func output(turn: Int, size: Int = 500) -> String {
        String(repeating: "第\(turn)轮的原始数据。", count: size)
    }

    /// 造一段 `turnCount` 轮的历史,每轮都带一次工具调用,最后跟一句新问题。
    private func conversation(turnCount: Int, size: Int = 500) -> [AgentChatMessageDTO] {
        var history: [AgentChatMessageDTO] = []
        for turn in 1...turnCount {
            let output = Self.output(turn: turn, size: size)
            history.append(.init(role: .user, text: "第 \(turn) 问"))
            let callId = "call_\(turn)"
            history.append(.init(
                role: .assistant,
                text: "第 \(turn) 答",
                toolCalls: [.init(
                    id: callId,
                    name: "daily_steps",
                    input: #"{"days":30}"#,
                    output: .init(kind: .table, text: output)
                )],
                storedTurn: .init(
                    exactTranscript: .init(messages: [
                        .init(role: .assistant, parts: [
                            .text("第 \(turn) 答"),
                            .toolCall(.init(
                                toolCallId: callId,
                                toolName: "daily_steps",
                                input: #"{"days":30}"#
                            ))
                        ]),
                        .toolResult(
                            toolCallId: callId,
                            toolName: "daily_steps",
                            result: .string(output)
                        )
                    ]),
                    state: .completed
                )
            ))
        }
        history.append(.init(role: .user, text: "第 \(turnCount + 1) 问"))
        return history
    }
}

final class RecordingSummarizer: AgentSummarizer, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [SummarizationPlan] = []
    private let visible: String
    private let replay: String

    var calls: [SummarizationPlan] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    init(visible: String, replay: String) {
        self.visible = visible
        self.replay = replay
    }

    private func record(_ plan: SummarizationPlan) {
        lock.lock()
        _calls.append(plan)
        lock.unlock()
    }

    func summarize(_ plan: SummarizationPlan) async throws -> CompactionArtifact {
        record(plan)
        return CompactionArtifact(
            kind: .modelGenerated,
            visibleSummary: visible,
            replaySummary: .assistantSummary(replay, sourceIDs: plan.sourceMessageIDs),
            sourceMessageIDs: plan.sourceMessageIDs
        )
    }
}

struct FailingSummarizer: AgentSummarizer {
    func summarize(_ plan: SummarizationPlan) async throws -> CompactionArtifact {
        throw AgentLoopError.service("summarizer down")
    }
}

private extension TurnContextSnapshotDTO {
    /// 快照里没有直接的"超没超"字段,拿估算和预算比一下。
    var exceedsBudget_placeholder: Bool {
        guard let window = contextWindow, let estimate = estimatedPromptTokens else { return false }
        return estimate > window - (reservedOutputTokens ?? 0)
    }
}
