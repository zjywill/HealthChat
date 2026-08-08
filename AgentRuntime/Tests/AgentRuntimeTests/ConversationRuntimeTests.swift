import Foundation
import Testing

@testable import AgentRuntime

@Suite("Compaction artifact")
struct CompactionArtifactTests {

    @Test("the replay summary carries tool traces the visible summary does not")
    func replaySummaryKeepsToolTrace() {
        let message = AgentChatMessageDTO(
            role: .assistant,
            text: "最近一周平均睡了 7 小时。",
            toolCalls: [
                .init(
                    id: "call_1",
                    name: "sleep_summary",
                    input: #"{"days":7}"#,
                    output: .init(kind: .table, text: "08-01 7 小时 12 分\n08-02 6 小时 48 分")
                )
            ],
            storedTurn: .init(state: .completed)
        )

        let artifact = try! #require(TranscriptCompactor.default.artifact(for: message))

        #expect(artifact.kind == .toolDigest)
        #expect(artifact.foldedToolCalls == 1)
        // 用户看到的还是那句话。
        #expect(artifact.visibleSummary == "最近一周平均睡了 7 小时。")
        // 模型看到的多一份"这轮查过什么"。
        #expect(artifact.replaySummary.text.contains("最近一周平均睡了 7 小时。"))
        #expect(artifact.replaySummary.text.contains("sleep_summary"))
        #expect(artifact.replaySummary.compactionSourceIDs == [message.id])
    }

    @Test("a long tool output is truncated instead of replayed whole")
    func longToolOutputIsTruncated() {
        let compactor = TranscriptCompactor(maxCharactersPerToolCall: 20)
        let message = AgentChatMessageDTO(
            role: .assistant,
            text: "结论",
            toolCalls: [
                .init(
                    id: "call_1",
                    name: "daily_steps",
                    input: "{}",
                    output: .init(kind: .table, text: String(repeating: "步", count: 500))
                )
            ],
            storedTurn: .init(state: .completed)
        )

        let artifact = try! #require(compactor.artifact(for: message))
        #expect(artifact.replaySummary.text.count < 200)
        #expect(artifact.replaySummary.text.hasSuffix("…"))
    }

    @Test("a turn with only an app placeholder produces nothing to replay")
    func placeholderOnlyTurnHasNoArtifact() {
        var message = AgentChatMessageDTO(role: .assistant, text: "")
        message.markStopped()
        message.text = "已停止回复"

        #expect(message.textIsPlaceholder)
        #expect(TranscriptCompactor.default.artifact(for: message) == nil)
        #expect(!message.hasReplayableContent)
    }
}

@Suite("History planner")
struct HistoryPlannerTests {

    private func planner(
        window: Int?,
        reserved: Int?,
        modelId: String = "claude-sonnet-5",
        policy: HistoryMigrationPolicy = .whenWindowShrinks
    ) -> ConversationHistoryPlanner {
        ConversationHistoryPlanner(
            systemInstruction: "system",
            profile: .init(providerId: "anthropic", modelId: modelId, contextWindow: window),
            reservedOutputTokens: reserved,
            migrationPolicy: policy
        ) { transcript in
            transcript.messages.reduce(0) { total, message in
                total + message.parts.reduce(0) { $0 + $1.approximateCharacterCount }
            }
        }
    }

    @Test("compaction runs before the oldest turn gets dropped")
    func compactsBeforeDropping() {
        let assistant = AgentChatMessageDTO(
            role: .assistant,
            text: "第一个回答",
            toolCalls: [
                .init(
                    id: "tool_1",
                    name: "daily_steps",
                    input: #"{"days":30}"#,
                    output: .init(kind: .table, text: String(repeating: "步数数据。", count: 200))
                )
            ],
            storedTurn: .init(state: .completed)
        )

        let prepared = planner(window: 400, reserved: 0).prepare(history: [
            .init(role: .user, text: "第一问"),
            assistant,
            .init(role: .user, text: "第二问")
        ])

        #expect(prepared.compactedAssistantMessages >= 1)
        #expect(prepared.droppedConversationTurns == 0)
        #expect(prepared.prompt.allText.contains("第一个回答"))
        #expect(!prepared.prompt.contains(String(repeating: "步数数据。", count: 40)))
        #expect(!prepared.exceedsBudget)
    }

    @Test("when compaction is not enough the oldest turn is dropped, never the newest question")
    func dropsOldestTurnLast() {
        let prepared = planner(window: 40, reserved: 0).prepare(history: [
            .init(role: .user, text: String(repeating: "很久以前的问题。", count: 5)),
            .init(
                role: .assistant,
                text: String(repeating: "很久以前的回答。", count: 5),
                storedTurn: .init(state: .completed)
            ),
            .init(role: .user, text: "现在的问题")
        ])

        #expect(prepared.droppedConversationTurns == 1)
        #expect(prepared.prompt.allText.contains("现在的问题"))
        #expect(!prepared.prompt.allText.contains("很久以前的问题。"))
    }

    @Test("an impossible budget is reported instead of silently sending an oversized prompt")
    func reportsBudgetOverflow() {
        let prepared = planner(window: 5, reserved: 0).prepare(history: [
            .init(role: .user, text: String(repeating: "放不下的问题。", count: 20))
        ])

        #expect(prepared.exceedsBudget)
    }

    @Test("switching to a smaller model with room to spare leaves history untouched")
    func harmlessModelSwitchKeepsHistory() {
        let output = String(repeating: "步数数据。", count: 20)
        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "问题"),
            assistantTurn(
                text: "旧模型上的回答",
                output: output,
                model: "claude-opus-4-8",
                window: 200_000
            ),
            .init(role: .user, text: "接着问")
        ]

        // 窗口是变小了,但整段对话离新窗口还差得远——没有任何理由丢掉工具轨迹。
        let prepared = planner(window: 20_000, reserved: 0).prepare(history: history)

        #expect(prepared.migrationNotes.isEmpty)
        #expect(prepared.compactedAssistantMessages == 0)
        #expect(prepared.prompt.contains(output))
    }

    @Test("under pressure the turn carried over from the old model is compacted first")
    func migratedTurnIsCompactedFirst() {
        let fromOldModel = String(repeating: "旧模型那轮。", count: 66)
        let fromNewModel = String(repeating: "新模型那轮。", count: 66)

        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "一问"),
            // 更老,但它是新模型自己产出的。
            assistantTurn(text: "一答", output: fromNewModel, model: "claude-sonnet-5", window: 20_000),
            .init(role: .user, text: "二问"),
            // 更新,但是从大窗口模型带过来的——它才该先被压。
            assistantTurn(text: "二答", output: fromOldModel, model: "claude-opus-4-8", window: 200_000),
            .init(role: .user, text: "三问"),
            assistantTurn(text: "三答", output: "短", model: "claude-sonnet-5", window: 20_000),
            .init(role: .user, text: "四问")
        ]

        let prepared = planner(window: 1_300, reserved: 0).prepare(history: history)

        #expect(prepared.compactedAssistantMessages == 1)
        #expect(prepared.migrationNotes.contains(ConversationHistoryPlanner.modelSwitchNote))
        // 换过来的那轮被压掉了,同样老的本地那轮原样留着——先压谁是按来源挑的,不是按顺序。
        #expect(!prepared.prompt.contains(fromOldModel))
        #expect(prepared.prompt.contains(fromNewModel))
    }

    @Test("the most recent turns are never touched by threshold compaction")
    func recentTurnsAreProtected() {
        let recent = String(repeating: "最近那轮。", count: 80)
        let old = String(repeating: "很早那轮。", count: 80)
        let history: [AgentChatMessageDTO] = [
            .init(role: .user, text: "一问"),
            assistantTurn(text: "一答", output: old, model: "claude-sonnet-5", window: 20_000),
            .init(role: .user, text: "二问"),
            assistantTurn(text: "二答", output: recent, model: "claude-sonnet-5", window: 20_000),
            .init(role: .user, text: "三问")
        ]

        let prepared = planner(window: 1_000, reserved: 0).prepare(history: history)

        // 刚查完的数据被压成一句摘要,用户下一句"那第三天呢"就答不上来了。
        #expect(prepared.prompt.contains(recent))
        #expect(!prepared.prompt.contains(old))
    }

    private func assistantTurn(
        text: String,
        output: String,
        model: String,
        window: Int
    ) -> AgentChatMessageDTO {
        let callId = "call_\(UUID().uuidString.prefix(4))"
        return AgentChatMessageDTO(
            role: .assistant,
            text: text,
            toolCalls: [.init(
                id: callId,
                name: "daily_steps",
                input: #"{"days":30}"#,
                output: .init(kind: .table, text: output)
            )],
            storedTurn: .init(
                exactTranscript: .init(messages: [
                    .init(role: .assistant, parts: [
                        .text(text),
                        .toolCall(.init(toolCallId: callId, toolName: "daily_steps", input: #"{"days":30}"#))
                    ]),
                    .toolResult(toolCallId: callId, toolName: "daily_steps", result: .string(output))
                ]),
                state: .completed,
                context: .init(
                    providerId: "anthropic",
                    requestedModelId: model,
                    contextWindow: window
                )
            )
        )
    }
}

@Suite("Turn sink")
struct TurnSinkTests {

    @Test("text arriving after a stop clears the app placeholder")
    func textReplacesPlaceholder() {
        var message = AgentChatMessageDTO(role: .assistant, text: "")
        message.markStopped()
        #expect(message.textIsPlaceholder)

        message.appendText("其实还有话说")
        #expect(!message.textIsPlaceholder)
        #expect(message.text == "其实还有话说")
    }

    @Test("a finished tool call lands on the record that started it")
    func toolResultLandsOnItsRecord() {
        var message = AgentChatMessageDTO(role: .assistant, text: "")
        message.startToolCall(.init(id: "a", name: "one", input: "{}"))
        message.startToolCall(.init(id: "b", name: "two", input: "{}"))
        message.finishToolCall(id: "b", output: .init(kind: .text, text: "第二个结果"), isError: true)

        #expect(message.toolCalls[0].output == nil)
        #expect(message.toolCalls[1].output?.text == "第二个结果")
        #expect(message.toolCalls[1].isError)
    }
}
