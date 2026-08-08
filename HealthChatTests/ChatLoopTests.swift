import Foundation
import Testing
import AgentRuntime

@testable import HealthChat

/// app 侧的 agent loop 集成测试。
///
/// 从 `ChatViewModel.send()` 一路走到发给模型的 prompt:事件归约、会话状态、上下文预算、
/// 压缩、换模型迁移都在里面,只有模型客户端是假的。
@MainActor
@Suite("Chat loop")
struct ChatLoopTests {

    private static func profile(
        _ modelId: String,
        window: Int
    ) -> AgentModelProfile {
        .init(providerId: "anthropic", modelId: modelId, contextWindow: window, maxOutputTokens: 4_000)
    }

    // MARK: - 工具跑完之后用户手动停止

    @Test("stopping after a tool has run keeps the result and marks the turn stopped")
    func stopAfterToolRun() async throws {
        let toolOutput = "最近 7 天睡眠\n08-01 | 7 小时 12 分"
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 200_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "sleep_summary", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                // 工具结果回来之后模型迟迟不说话——用户就是在这个时候按停止的。
                .init(text: "这几晚", beforeResponding: { try await Task.sleep(for: .seconds(30)) }),
                // 停止之后的追问走这一轮。
                .init(text: "深睡还行")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(client: client, capabilities: stubRegistry(["sleep_summary": toolOutput]))
            },
            loadsPersistedSession: false
        )

        viewModel.send("看看最近睡眠")
        try await waitUntil("工具结果回来") {
            viewModel.messages.last?.toolCalls.first?.output != nil
        }

        viewModel.stopReply()
        try await waitUntil("回复结束") { !viewModel.isReplying }

        let assistant = try #require(viewModel.messages.last)
        #expect(assistant.turnState == .stopped)
        #expect(assistant.text == "已停止回复")
        #expect(assistant.textIsPlaceholder)
        // 已经花掉的那次查询要留着:界面上还看得到,追问时也不用重查。
        #expect(assistant.toolCalls.count == 1)
        #expect(assistant.toolCalls.first?.output == toolOutput)

        // 停止之后接着问:上一轮的工具结果照样回放,占位文本不进上下文。
        viewModel.send("那深睡呢")
        try await waitUntil("追问结束") { !viewModel.isReplying }

        #expect(viewModel.messages.last?.text == "深睡还行")
        #expect(client.lastPromptContains(toolOutput))
        #expect(!client.lastPromptText.contains("已停止回复"))
    }

    // MARK: - 长对话触发压缩

    @Test("a long conversation compacts the earlier turn before the next request goes out")
    func longConversationTriggersCompaction() async throws {
        // 窗口刚好装得下一次大查询,装不下两次——第二轮就必须把上一轮压掉。
        let oldOutput = String(repeating: "上个月步数很长。", count: 500)
        let newOutput = String(repeating: "这周锻炼记录。", count: 500)
        let client = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 8_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: #"{"days":30}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "上个月平均一天 9,100 步。"),
                .init(
                    toolCalls: [.init(toolCallId: "call_2", name: "workouts", input: #"{"days":7}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "这周略低一点。")
            ]
        )
        let viewModel = ChatViewModel(
            engineFactory: { _ in
                LoopEngine(
                    client: client,
                    capabilities: stubRegistry(["daily_steps": oldOutput, "workouts": newOutput])
                )
            },
            loadsPersistedSession: false
        )

        viewModel.send("上个月走了多少")
        try await waitUntil("第一轮结束") { !viewModel.isReplying }
        viewModel.send("那这周呢")
        try await waitUntil("第二轮结束") { !viewModel.isReplying }

        // 第二轮的 prompt 里,上一轮的原始工具输出被折叠成摘要了;这一轮自己查的还在。
        #expect(!client.lastPromptContains(oldOutput))
        #expect(client.lastPromptContains(newOutput))
        #expect(client.lastPromptText.contains("上个月平均一天 9,100 步。"))
        #expect(client.lastPromptText.contains("折叠了 1 次健康查询"))
        #expect(client.lastPromptText.contains("那这周呢"))

        let context = try #require(viewModel.messages.last?.context)
        #expect(context.compactedAssistantMessages >= 1)
        #expect(context.droppedConversationTurns == 0)

        // 界面上那条回复不受影响:压缩只发生在发给模型的那一份里。
        #expect(viewModel.messages[1].text == "上个月平均一天 9,100 步。")
        #expect(viewModel.messages[1].toolCalls.first?.output == oldOutput)
    }

    // MARK: - 切模型之后继续追问

    @Test("switching to a smaller model migrates the earlier turn instead of failing the request")
    func modelSwitchMigratesHistory() async throws {
        let detailedOutput = String(repeating: "详细的工具轨迹。", count: 60)
        let bigModel = ScriptedModelClient(
            profile: Self.profile("claude-opus-4-8", window: 200_000),
            turns: [
                .init(
                    toolCalls: [.init(toolCallId: "call_1", name: "daily_steps", input: #"{"days":30}"#)],
                    finishReason: .init(unified: .toolCalls)
                ),
                .init(text: "上周整体还行。", usage: .init(inputTokens: .init(total: 900)))
            ]
        )
        let smallModel = ScriptedModelClient(
            profile: Self.profile("claude-sonnet-5", window: 20_000),
            turns: [.init(text: "继续说说。")]
        )

        let registry = stubRegistry(["daily_steps": detailedOutput])
        let clients = ModelSequence(clients: [bigModel, smallModel])
        let viewModel = ChatViewModel(
            engineFactory: { _ in LoopEngine(client: clients.next(), capabilities: registry) },
            loadsPersistedSession: false
        )

        viewModel.send("先聊聊上周")
        try await waitUntil("大模型这轮结束") { !viewModel.isReplying }

        let firstContext = try #require(viewModel.messages.last?.context)
        #expect(firstContext.requestedModelId == "claude-opus-4-8")
        #expect(firstContext.contextWindow == 200_000)

        viewModel.send("换个模型继续说")
        try await waitUntil("小模型这轮结束") { !viewModel.isReplying }

        let secondContext = try #require(viewModel.messages.last?.context)
        #expect(secondContext.requestedModelId == "claude-sonnet-5")
        // 窗口变小了就主动把老的那轮换成压缩形态,而不是等 provider 报 400。
        #expect(secondContext.migrationNotes.contains(ConversationHistoryPlanner.modelSwitchNote))
        #expect(secondContext.compactedAssistantMessages == 1)
        #expect(!smallModel.lastPromptContains(detailedOutput))
        #expect(smallModel.lastPromptText.contains("上周整体还行。"))

        // 旧模型上的估算/实际比例不能带到新模型上:tokenizer 换了,那把尺子就作废了。
        #expect(secondContext.estimatedPromptTokens == smallModel.estimateTokens(for: .init(
            profile: smallModel.profile,
            prompt: try #require(smallModel.requests.last).prompt,
            capabilities: registry.definitions
        )))
    }
}

/// 一次会话里换模型:每次要引擎就给下一个客户端。
@MainActor
final class ModelSequence {
    private var clients: [ScriptedModelClient]
    private var index = 0

    init(clients: [ScriptedModelClient]) {
        self.clients = clients
    }

    func next() -> ScriptedModelClient {
        defer { index = min(index + 1, clients.count - 1) }
        return clients[index]
    }
}
