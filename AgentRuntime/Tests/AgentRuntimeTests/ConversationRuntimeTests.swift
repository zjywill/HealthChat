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

    @Test("migration only fires when the new window is actually smaller")
    func migrationRespectsWindowSize() {
        let assistant = AgentChatMessageDTO(
            role: .assistant,
            text: "旧模型上的回答",
            storedTurn: .init(
                state: .completed,
                context: .init(
                    providerId: "anthropic",
                    requestedModelId: "claude-opus-4-8",
                    contextWindow: 200_000
                )
            )
        )
        let history: [AgentChatMessageDTO] = [.init(role: .user, text: "问题"), assistant]

        let shrunk = planner(window: 20_000, reserved: 0).prepare(history: history)
        #expect(shrunk.migrationNotes.contains(ConversationHistoryPlanner.modelSwitchNote))

        let grown = planner(window: 400_000, reserved: 0).prepare(history: history)
        #expect(grown.migrationNotes.isEmpty)

        let sameModel = planner(window: 20_000, reserved: 0, modelId: "claude-opus-4-8")
            .prepare(history: history)
        #expect(sameModel.migrationNotes.isEmpty)
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
