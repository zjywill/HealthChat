import Foundation
import Testing

@testable import AgentRuntime

/// 用户在这一轮还在跑的时候补的话。
///
/// 三件事各自都能悄悄坏掉,而且坏了都不报错:接的位置不对(模型看成先追问再查数据)、
/// 同一句被发两遍(每个边界都取一次)、下次回放又出现一遍(列表和 transcript 各存了一份)。
@Suite("Pending input")
struct PendingInputTests {

    private static let profile = AgentModelProfile(
        providerId: "anthropic",
        modelId: "claude-sonnet-5",
        contextWindow: 20_000,
        maxOutputTokens: 8_000
    )

    /// 排队的话按次数发号:第一次边界(还没发过请求)没有,第二次才有。
    private final class Queue: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [[AgentPendingInput]]
        private(set) var asks = 0

        init(_ batches: [[AgentPendingInput]]) { remaining = batches }

        func take() -> [AgentPendingInput] {
            lock.lock()
            defer { lock.unlock() }
            asks += 1
            return remaining.isEmpty ? [] : remaining.removeFirst()
        }
    }

    // MARK: - 接进上下文

    @Test("an interjection lands after the tool result, not before the tool call")
    func interjectionLandsAfterTheToolResult() async {
        let toolOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分"
        let interjection = AgentPendingInput(text: "顺便也看看心率")
        // 第一个边界(第一次请求之前)空着,第二个边界才有——这正是「他在模型查数据的时候
        // 补了一句」的样子。
        let queue = Queue([[], [interjection]])

        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["睡眠和心率都看了"], finishReason: .init(unified: .stop))
            ]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["sleep_summary": toolOutput]),
            systemInstruction: "system",
            pendingInput: { queue.take() }
        )

        let outcome = await record(loop, history: [.init(role: .user, text: "看看最近睡眠")])
        #expect(outcome.error == nil)

        let second = try! #require(client.requests.last?.prompt)
        let roles = second.messages.map(\.role)
        let toolIndex = try! #require(roles.lastIndex(of: .tool))
        let interjected = try! #require(
            second.messages.lastIndex { $0.role == .user && $0.text == interjection.text }
        )
        // 位置就是全部:排在工具结果前面的话,模型读到的是「他先追问、我才去查」,
        // 而实际顺序正相反。
        #expect(interjected > toolIndex)
    }

    @Test("an interjection is taken once, never re-sent at the next boundary")
    func interjectionIsConsumedOnce() async {
        let interjection = AgentPendingInput(text: "顺便也看看心率")
        let queue = Queue([[], [interjection]])

        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(
                    toolCalls: [.init(toolCallId: "call_2", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["好"], finishReason: .init(unified: .stop))
            ]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["sleep_summary": "结果"]),
            systemInstruction: "system",
            pendingInput: { queue.take() }
        )

        let outcome = await record(loop, history: [.init(role: .user, text: "看看最近睡眠")])
        #expect(outcome.error == nil)

        let last = try! #require(client.requests.last?.prompt)
        let occurrences = last.messages.count { $0.role == .user && $0.text == interjection.text }
        #expect(occurrences == 1)
        // 每个边界都问一次:三次请求 = 三个边界。
        #expect(queue.asks == 3)
    }

    @Test("the turn records which queued messages it absorbed")
    func turnRecordsAbsorbedInput() async {
        let interjection = AgentPendingInput(text: "顺便也看看心率")
        let queue = Queue([[], [interjection]])

        let client = ScriptedModelClient(
            profile: Self.profile,
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: "{}")],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(textDeltas: ["好"], finishReason: .init(unified: .stop))
            ]
        )
        let loop = AgentLoop(
            client: client,
            capabilities: stubRegistry(["sleep_summary": "结果"]),
            systemInstruction: "system",
            pendingInput: { queue.take() }
        )

        let outcome = await record(loop, history: [.init(role: .user, text: "看看最近睡眠")])
        #expect(outcome.messages.last?.storedTurn.inlinedMessageIDs == [interjection.id])
        #expect(outcome.events.contains {
            if case .pendingInputAccepted(let inputs) = $0 { return inputs == [interjection] }
            return false
        })
    }

    // MARK: - 回放

    /// 插话在两个地方各有一份:app 的消息列表里一条(界面要显示),这一轮的 transcript
    /// 中间一段(模型当时就是这么读的)。回放时必须只出一份。
    @Test("a replayed interjection appears once, not twice")
    func replayDoesNotDuplicate() {
        let interjectionId = UUID()
        let text = "顺便也看看心率"
        let history = Self.historyWithInterjection(id: interjectionId, text: text, transcriptIsStored: true)

        let prompt = Self.planner().prepare(history: history).prompt
        #expect(prompt.messages.count { $0.role == .user && $0.text == text } == 1)
    }

    /// 那一轮被停掉时 transcript 是空的,回放走的是从工具记录重建的那份——里面没有插话。
    /// 这时候还跳过列表里那条,用户补的那句就凭空消失了。
    @Test("an interjection survives a turn that was stopped before its transcript was stored")
    func interjectionSurvivesAStoppedTurn() {
        let interjectionId = UUID()
        let text = "顺便也看看心率"
        let history = Self.historyWithInterjection(id: interjectionId, text: text, transcriptIsStored: false)

        let prompt = Self.planner().prepare(history: history).prompt
        #expect(prompt.messages.count { $0.role == .user && $0.text == text } == 1)
    }

    private static func planner() -> ConversationHistoryPlanner {
        ConversationHistoryPlanner(
            systemInstruction: "system",
            profile: profile,
            estimateTokens: { transcript in
                transcript.messages.reduce(0) { total, message in
                    total + message.parts.reduce(0) { $0 + $1.approximateCharacterCount }
                }
            }
        )
    }

    private static func historyWithInterjection(
        id: UUID,
        text: String,
        transcriptIsStored: Bool
    ) -> [AgentChatMessageDTO] {
        let callId = "call_1"
        let toolName = "sleep_summary"
        let stored = AgentTranscript(messages: [
            .init(role: .assistant, parts: [
                .toolCall(.init(toolCallId: callId, toolName: toolName, input: "{}"))
            ]),
            .toolResult(toolCallId: callId, toolName: toolName, result: .string("结果")),
            .user(text),
            .assistant("睡眠和心率都看了")
        ])
        return [
            .init(role: .user, text: "看看最近睡眠"),
            .init(
                role: .assistant,
                text: "睡眠和心率都看了",
                toolCalls: [.init(
                    id: callId,
                    name: toolName,
                    input: "{}",
                    output: .init(kind: .table, text: "结果")
                )],
                storedTurn: .init(
                    exactTranscript: transcriptIsStored ? stored : .init(),
                    state: transcriptIsStored ? .completed : .stopped,
                    inlinedMessageIDs: [id]
                )
            ),
            .init(id: id, role: .user, text: text)
        ]
    }
}
