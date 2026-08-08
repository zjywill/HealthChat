import Foundation

public enum AgentLoopError: Error, Equatable, Sendable {
    /// provider 侧的错误,原文透出。
    case service(String)
    case contentFilter
    /// 工具轮数用光了还没收敛。
    case toolRoundLimit
    /// 流结束了但没拿到 finish reason。
    case incompleteResponse
    /// 在吐 tool_use 的中途被截断,参数可能不完整——照发下去是错的。
    case truncatedDuringToolCall
    /// 压缩和丢弃都做完了还是塞不进窗口。
    case contextWindowExceeded
}

/// 通用 agent loop。
///
/// 它只认三样东西:一个能流式跑一轮的 `AgentModelClient`、一组 `CapabilityRegistry` 里的
/// 能力、一份 app 自己的会话历史。HealthKit、Calendar、Files 对它没有区别,AIKit 和别的
/// SDK 也没有区别。
public struct AgentLoop: Sendable {
    public var client: any AgentModelClient
    public var capabilities: CapabilityRegistry
    public var systemInstruction: String
    public var compactor: TranscriptCompactor
    /// 谁来写整段摘要。给 nil 就退回纯机械压缩(还能跑,只是省不了那么多)。
    public var summarizer: (any AgentSummarizer)?
    public var migrationPolicy: HistoryMigrationPolicy
    public var policy: ContextPolicy
    public var maxToolRounds: Int

    public init(
        client: any AgentModelClient,
        capabilities: CapabilityRegistry,
        systemInstruction: String,
        compactor: TranscriptCompactor = .default,
        summarizer: (any AgentSummarizer)? = nil,
        migrationPolicy: HistoryMigrationPolicy = .whenWindowShrinks,
        policy: ContextPolicy = .default,
        maxToolRounds: Int = 6
    ) {
        self.client = client
        self.capabilities = capabilities
        self.systemInstruction = systemInstruction
        self.compactor = compactor
        self.summarizer = summarizer
        self.migrationPolicy = migrationPolicy
        self.policy = policy
        self.maxToolRounds = maxToolRounds
    }

    public func run(history: [AgentChatMessageDTO]) -> AsyncThrowingStream<AgentTurnEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await execute(history: history, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 留给窗口大小未知的 provider:按窗口的十分之一预留输出,夹在 1k–4k 之间,
    /// 再被模型自己的输出上限压一道。
    public static func reservedOutputTokens(for profile: AgentModelProfile) -> Int? {
        guard let window = profile.contextWindow else { return nil }
        let heuristic = min(4_096, max(1_024, window / 10))
        guard let cap = profile.maxOutputTokens, cap > 0 else { return heuristic }
        return max(256, min(heuristic, cap))
    }
}

private extension AgentLoop {
    func execute(
        history: [AgentChatMessageDTO],
        continuation: AsyncThrowingStream<AgentTurnEvent, any Error>.Continuation
    ) async throws {
        let profile = client.profile
        let definitions = capabilities.definitions
        let reserved = Self.reservedOutputTokens(for: profile)

        var calibration = ContextCalibration(history: history, profile: profile)
        var runtimeTranscript = AgentTranscript()
        // 本轮用的历史。整段摘要生成后就地写进去,同时通过事件让 app 存下来。
        var history = history
        // 一轮里最多总结一次。工具轮之间再压也只能压历史,压不动这一轮刚拿到的大结果,
        // 白花调用。
        var didSummarize = false

        for _ in 0..<maxToolRounds {
            try Task.checkCancellation()

            // 过了水位线就叫模型把远处的对话总结掉,再去发这一轮。
            // 放在发请求之前,而不是撞墙之后——撞墙时已经没有从容处理的余地了。
            if !didSummarize, let compacted = await summarizeIfNeeded(
                history: history,
                runtimeTranscript: runtimeTranscript,
                profile: profile,
                definitions: definitions,
                reserved: reserved,
                calibrationScale: calibration.scale
            ) {
                didSummarize = true
                if let index = history.firstIndex(where: { $0.id == compacted.messageID }) {
                    history[index].storedTurn.compaction = compacted.artifact
                }
                continuation.yield(.historyCompacted(
                    messageID: compacted.messageID,
                    artifact: compacted.artifact
                ))
            }

            let prepared = plan(
                history: history,
                runtimeTranscript: runtimeTranscript,
                profile: profile,
                definitions: definitions,
                reserved: reserved,
                calibrationScale: calibration.scale
            )
            guard !prepared.exceedsBudget else {
                throw AgentLoopError.contextWindowExceeded
            }

            let request = AgentModelRequest(
                profile: profile,
                prompt: prepared.prompt,
                capabilities: definitions
            )

            var response: AgentModelResponse?
            for try await event in try client.stream(request) {
                try Task.checkCancellation()
                switch event {
                case .textDelta(let delta):
                    guard !delta.isEmpty else { continue }
                    continuation.yield(.textDelta(delta))
                case .completed(let completed):
                    response = completed
                }
            }

            guard let response else { throw AgentLoopError.incompleteResponse }
            try validate(response)

            if let assistant = response.assistantMessage, !assistant.parts.isEmpty {
                runtimeTranscript.messages.append(assistant)
            }

            calibration.note(
                actual: response.usage?.inputTokens.total,
                estimated: prepared.estimatedPromptTokens
            )
            let snapshot = prepared.snapshot(
                servedModelId: response.servedModelId,
                actualPromptTokens: response.usage?.inputTokens.total
            )

            guard !response.pendingCalls.isEmpty else {
                continuation.yield(.turnCompleted(
                    transcript: runtimeTranscript,
                    finishReason: response.finishReason,
                    usage: response.usage,
                    context: snapshot
                ))
                return
            }

            for call in response.pendingCalls {
                try Task.checkCancellation()
                continuation.yield(.toolCallStarted(.init(
                    id: call.toolCallId,
                    name: call.name,
                    input: call.input
                )))

                let result = await capabilities.execute(call)

                continuation.yield(.toolCallFinished(
                    id: call.toolCallId,
                    output: result.output,
                    isError: result.isError
                ))
                runtimeTranscript.messages.append(.toolResult(
                    toolCallId: call.toolCallId,
                    toolName: call.name,
                    result: .string(result.output.text),
                    isError: result.isError
                ))
            }
        }

        throw AgentLoopError.toolRoundLimit
    }

    /// 跨过水位线就叫 summarizer 写一份整段摘要。
    ///
    /// 失败不上抛:总结只是省 token 的手段,它挂了应该退回机械压缩,而不是让用户这一句问不出去。
    func summarizeIfNeeded(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript,
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?
    ) async -> (messageID: UUID, artifact: CompactionArtifact)? {
        guard let summarizer else { return nil }
        let planner = makePlanner(
            profile: profile,
            definitions: definitions,
            reserved: reserved,
            calibrationScale: calibrationScale
        )
        guard let plan = planner.summarizationPlan(
            history: history,
            runtimeTranscript: runtimeTranscript
        ) else {
            return nil
        }
        guard let artifact = try? await summarizer.summarize(plan) else { return nil }
        return (plan.ownerMessageID, artifact)
    }

    func plan(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript,
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?
    ) -> ConversationHistoryPlanner.PreparedHistory {
        makePlanner(
            profile: profile,
            definitions: definitions,
            reserved: reserved,
            calibrationScale: calibrationScale
        ).prepare(history: history, runtimeTranscript: runtimeTranscript)
    }

    func makePlanner(
        profile: AgentModelProfile,
        definitions: [CapabilityDefinition],
        reserved: Int?,
        calibrationScale: Double?
    ) -> ConversationHistoryPlanner {
        let client = client
        let calibration = ContextCalibration(scale: calibrationScale)
        return ConversationHistoryPlanner(
            systemInstruction: systemInstruction,
            profile: profile,
            reservedOutputTokens: reserved,
            compactor: compactor,
            migrationPolicy: migrationPolicy,
            policy: policy
        ) { transcript in
            calibration.apply(to: client.estimateTokens(for: AgentModelRequest(
                profile: profile,
                prompt: transcript,
                capabilities: definitions
            )))
        }
    }

    func validate(_ response: AgentModelResponse) throws {
        if let failure = response.failureMessage {
            throw AgentLoopError.service(failure)
        }
        guard let reason = response.finishReason else {
            throw AgentLoopError.incompleteResponse
        }
        switch reason.unified {
        case .error:
            throw AgentLoopError.service(reason.raw ?? "model execution failed")
        case .contentFilter:
            throw AgentLoopError.contentFilter
        case .length where !response.pendingCalls.isEmpty:
            throw AgentLoopError.truncatedDuringToolCall
        default:
            break
        }
    }
}
