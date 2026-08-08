import Foundation
import AIKit

struct AIKitEngine: AgentEngine {
    let name = "云端模型"

    private static let maxToolRounds = 6

    private static let toolDefinitions = HealthTools.all.map { spec in
        var properties: [String: JSONValue] = [
            "days": .object([
                "type": "integer",
                "description": "查询最近多少天，范围 1–90，默认 7",
                "minimum": 1,
                "maximum": 90,
                "default": 7
            ])
        ]

        if spec.supportsActivityFilter {
            properties["activity"] = .object([
                "type": "string",
                "description": "只看某一类锻炼时传，留空表示全部",
                "enum": .array(HealthTools.activityNames.map { .string($0) })
            ])
        }

        return ToolDefinition(
            name: spec.name,
            description: spec.description,
            inputSchema: .object([
                "type": "object",
                "properties": .object(properties),
                "required": .array(["days"]),
                "additionalProperties": false
            ]),
            // 现在这份 schema 还不是严格 JSON Schema 兼容形态；先别把整条请求送进 400。
            strict: false
        )
    }

    private let providerId: String
    private let model: String
    private let topic: ChatTopic?

    init(
        providerId: String = "anthropic",
        model: String = "claude-sonnet-5",
        topic: ChatTopic? = nil
    ) {
        self.providerId = providerId
        self.model = model
        self.topic = topic
    }

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
                        throw AgentError.needsAPIKey
                    }
                    let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        throw AgentError.needsAPIKey
                    }

                    let client = try AIClient(
                        providerId: providerId,
                        configuration: .init(apiKey: key)
                    )
                    try await streamToolLoop(
                        client: client,
                        history: history,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamToolLoop(
        client: AIClient,
        history: [ChatMessage],
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        var transcript = ConversationTranscript(
            systemInstruction: systemInstruction(),
            history: history,
            providerId: providerId,
            requestedModelId: model
        )
        var budgetPolicy = ContextBudgetPolicy(
            providerId: providerId,
            requestedModelId: model,
            modelInfo: ProviderCatalog.model(model, provider: providerId)?.1,
            toolDefinitions: Self.toolDefinitions,
            calibrationScale: transcript.calibrationScale
        )
        var replayMessages: [Message] = []
        var finalUsage: Usage?
        var finalFinishReason: FinishReason?
        var finalSnapshot: TurnContextSnapshot?

        for _ in 0..<Self.maxToolRounds {
            let prepared = try budgetPolicy.prepare(transcript: &transcript)
            let options = CallOptions(
                model: model,
                prompt: prepared.prompt,
                tools: Self.toolDefinitions
            )
            var parts: [StreamPart] = []

            for try await part in try client.stream(options) {
                try Task.checkCancellation()
                parts.append(part)
                if case .textDelta(_, let delta, _) = part, !delta.isEmpty {
                    continuation.yield(.textDelta(delta))
                }
            }

            let response = AIResponse(parts: parts)
            if let streamError = response.errors.first {
                throw AgentError.cloudService(streamError.message)
            }
            guard let finishReason = response.finishReason else {
                throw AgentError.incompleteResponse
            }

            switch finishReason.unified {
            case .error:
                throw AgentError.cloudService(response.errors.first?.message ?? "模型执行失败")
            case .contentFilter:
                throw AgentError.cloudService("模型因安全策略拒绝了这次请求")
            case .length where !response.pendingToolCalls.isEmpty:
                throw AgentError.responseTruncatedDuringToolCall
            default:
                break
            }

            let assistantMessage = response.assistantMessage
            if !assistantMessage.content.isEmpty {
                replayMessages.append(assistantMessage)
                transcript.appendRuntime(assistantMessage)
            }

            finalUsage = response.usage
            finalFinishReason = finishReason
            budgetPolicy.noteActualInputTokens(
                actual: response.usage.inputTokens.total,
                estimated: prepared.contextUsage.used
            )
            budgetPolicy.noteServedModel(response.metadata?.modelId)
            finalSnapshot = prepared.snapshot(
                servedModelId: response.metadata?.modelId,
                actualPromptTokens: response.usage.inputTokens.total
            )

            guard !response.pendingToolCalls.isEmpty else {
                continuation.yield(.turnCompleted(
                    replayMessages: replayMessages,
                    finishReason: finalFinishReason,
                    usage: finalUsage,
                    context: finalSnapshot
                ))
                return
            }

            for call in response.pendingToolCalls {
                let days = HealthTools.days(fromInput: call.input)

                continuation.yield(.toolCallStarted(ToolCallRecord(
                    id: call.toolCallId,
                    name: call.toolName,
                    input: call.input
                )))

                let outcome: (output: String, report: HealthReport?, isError: Bool)
                if let spec = HealthTools.spec(named: call.toolName) {
                    do {
                        let report = try await spec.run(days, HealthTools.activity(fromInput: call.input))
                        outcome = (report.modelText, report, false)
                    } catch {
                        outcome = ("健康数据查询失败：\(error.localizedDescription)", nil, true)
                    }
                } else {
                    outcome = ("不支持名为 \(call.toolName) 的健康工具。", nil, true)
                }

                continuation.yield(.toolCallFinished(
                    id: call.toolCallId,
                    output: outcome.output,
                    report: outcome.report,
                    isError: outcome.isError
                ))

                let toolResultMessage = Message.toolResult(
                    toolCallId: call.toolCallId,
                    toolName: call.toolName,
                    result: .string(outcome.output),
                    isError: outcome.isError
                )
                replayMessages.append(toolResultMessage)
                transcript.appendRuntime(toolResultMessage)
            }
        }

        throw AgentError.toolLoopLimit
    }

    private func systemInstruction() -> String {
        var instructions = HealthAssistantInstructions.text
        if let topic {
            instructions += "\n\n本次对话的话题：\(topic.name)。\(topic.focus)"
        }
        let persona = EngineSettings.persona.instruction
        if !persona.isEmpty {
            instructions += "\n\n\(persona)"
        }
        return instructions
    }
}

private struct PreparedPrompt {
    let prompt: Prompt
    let contextUsage: ContextUsage
    let providerId: String
    let requestedModelId: String
    let contextWindow: Int?
    let reservedOutputTokens: Int?
    let compactedAssistantMessages: Int
    let droppedConversationTurns: Int

    func snapshot(servedModelId: String?, actualPromptTokens: Int?) -> TurnContextSnapshot {
        TurnContextSnapshot(
            providerId: providerId,
            requestedModelId: requestedModelId,
            servedModelId: servedModelId,
            contextWindow: contextWindow,
            reservedOutputTokens: reservedOutputTokens,
            estimatedPromptTokens: contextUsage.used,
            actualPromptTokens: actualPromptTokens,
            compactedAssistantMessages: compactedAssistantMessages,
            droppedConversationTurns: droppedConversationTurns
        )
    }
}

private struct ContextBudgetPolicy {
    let providerId: String
    let requestedModelId: String
    let modelInfo: ModelInfo?
    let toolDefinitions: [ToolDefinition]

    private let reporter = ContextReporter()
    private var calibrationScale: Double?
    private(set) var servedModelId: String?

    init(
        providerId: String,
        requestedModelId: String,
        modelInfo: ModelInfo?,
        toolDefinitions: [ToolDefinition],
        calibrationScale: Double?
    ) {
        self.providerId = providerId
        self.requestedModelId = requestedModelId
        self.modelInfo = modelInfo
        self.toolDefinitions = toolDefinitions
        self.calibrationScale = calibrationScale
    }

    mutating func prepare(transcript: inout ConversationTranscript) throws -> PreparedPrompt {
        guard let contextWindow = modelInfo?.contextWindow else {
            let prompt = transcript.prompt
            return PreparedPrompt(
                prompt: prompt,
                contextUsage: usage(for: prompt, contextWindow: nil),
                providerId: providerId,
                requestedModelId: requestedModelId,
                contextWindow: nil,
                reservedOutputTokens: nil,
                compactedAssistantMessages: transcript.compactedAssistantMessages,
                droppedConversationTurns: transcript.droppedConversationTurns
            )
        }

        let reservedOutputTokens = reserveOutputTokens(contextWindow: contextWindow)
        let budget = max(0, contextWindow - reservedOutputTokens)

        while true {
            let prompt = transcript.prompt
            let contextUsage = usage(for: prompt, contextWindow: contextWindow)
            if contextUsage.used <= budget {
                return PreparedPrompt(
                    prompt: prompt,
                    contextUsage: contextUsage,
                    providerId: providerId,
                    requestedModelId: requestedModelId,
                    contextWindow: contextWindow,
                    reservedOutputTokens: reservedOutputTokens,
                    compactedAssistantMessages: transcript.compactedAssistantMessages,
                    droppedConversationTurns: transcript.droppedConversationTurns
                )
            }

            if transcript.compactOldestAssistantMessage() {
                continue
            }
            if transcript.dropOldestConversationTurn() {
                continue
            }
            throw AgentError.contextWindowExceeded
        }
    }

    mutating func noteActualInputTokens(actual: Int?, estimated: Int) {
        guard let actual, estimated > 0 else { return }
        calibrationScale = Double(actual) / Double(estimated)
    }

    mutating func noteServedModel(_ modelId: String?) {
        guard let modelId, !modelId.isEmpty else { return }
        servedModelId = modelId
    }

    private func usage(for prompt: Prompt, contextWindow: Int?) -> ContextUsage {
        let options = CallOptions(
            model: requestedModelId,
            prompt: prompt,
            tools: toolDefinitions
        )
        let estimated = reporter.report(options, contextWindow: contextWindow)
        guard let calibrationScale, calibrationScale > 0 else {
            return estimated
        }
        let calibratedTotal = max(1, Int((Double(estimated.used) * calibrationScale).rounded()))
        return estimated.calibrated(toTotal: calibratedTotal)
    }

    private func reserveOutputTokens(contextWindow: Int) -> Int {
        let heuristic = min(4_096, max(1_024, contextWindow / 10))
        guard let outputCap = modelInfo?.maxOutputTokens, outputCap > 0 else {
            return heuristic
        }
        return max(256, min(heuristic, outputCap))
    }
}

private struct ConversationTranscript {
    private enum Item {
        case user(String)
        case assistant(AssistantTurn)
    }

    private struct AssistantTurn {
        let exactMessages: [Message]
        let compactMessages: [Message]
        var isCompacted = false

        var activeMessages: [Message] {
            isCompacted ? compactMessages : exactMessages
        }

        var canCompact: Bool {
            !isCompacted && !compactMessages.isEmpty && compactMessages != exactMessages
        }
    }

    private let systemInstruction: String
    private var items: [Item]
    private var runtimeMessages: [Message] = []

    private(set) var compactedAssistantMessages = 0
    private(set) var droppedConversationTurns = 0
    let calibrationScale: Double?

    init(
        systemInstruction: String,
        history: [ChatMessage],
        providerId: String,
        requestedModelId: String
    ) {
        self.systemInstruction = systemInstruction
        self.items = []
        self.calibrationScale = history.reversed().compactMap { message -> Double? in
            guard message.role == .assistant,
                  let context = message.context,
                  context.matches(providerId: providerId, requestedModelId: requestedModelId),
                  let estimated = context.estimatedPromptTokens,
                  let actual = context.actualPromptTokens,
                  estimated > 0,
                  actual > 0 else {
                return nil
            }
            return Double(actual) / Double(estimated)
        }.first

        for message in history {
            switch message.role {
            case .user:
                guard !message.text.isEmpty else { continue }
                items.append(.user(message.text))

            case .assistant:
                guard message.shouldReplayInContext else { continue }
                let exact = message.exactReplayMessages.isEmpty
                    ? message.reconstructedReplayMessages
                    : message.exactReplayMessages
                let compact = message.compactReplayMessages
                guard !exact.isEmpty || !compact.isEmpty else { continue }
                items.append(.assistant(AssistantTurn(
                    exactMessages: exact.isEmpty ? compact : exact,
                    compactMessages: compact
                )))
            }
        }
    }

    var prompt: Prompt {
        var prompt: Prompt = [.system(systemInstruction)]
        for item in items {
            switch item {
            case .user(let text):
                prompt.append(.user(text))
            case .assistant(let turn):
                prompt.append(contentsOf: turn.activeMessages)
            }
        }
        prompt.append(contentsOf: runtimeMessages)
        return prompt
    }

    mutating func appendRuntime(_ message: Message) {
        guard !message.content.isEmpty else { return }
        runtimeMessages.append(message)
    }

    mutating func compactOldestAssistantMessage() -> Bool {
        for index in items.indices {
            guard case .assistant(var turn) = items[index], turn.canCompact else { continue }
            turn.isCompacted = true
            items[index] = .assistant(turn)
            compactedAssistantMessages += 1
            return true
        }
        return false
    }

    mutating func dropOldestConversationTurn() -> Bool {
        guard userMessageCount > 1, !items.isEmpty else { return false }

        var end = 1
        while end < items.count {
            if case .user = items[end] {
                break
            }
            end += 1
        }
        items.removeSubrange(0..<end)
        droppedConversationTurns += 1
        return true
    }

    private var userMessageCount: Int {
        items.reduce(into: 0) { count, item in
            if case .user = item {
                count += 1
            }
        }
    }
}

private extension ChatMessage {
    var shouldReplayInContext: Bool {
        switch turnState {
        case .failed:
            return hasReplayableContent
        case .stopped:
            if text == "已停止回复", exactReplayMessages.isEmpty, toolCalls.allSatisfy({ $0.output == nil }) {
                return false
            }
            return hasReplayableContent
        case .completed, .none:
            return hasReplayableContent
        }
    }
}

private extension TurnContextSnapshot {
    func matches(providerId: String, requestedModelId: String) -> Bool {
        guard self.providerId == providerId else { return false }
        let effectiveModelId = servedModelId ?? self.requestedModelId
        return effectiveModelId == requestedModelId
    }
}
