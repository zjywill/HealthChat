import Foundation
import AgentRuntime
import AIKit

/// AIKit 在 runtime 眼里的样子。
///
/// 这是 app 里唯一还认识 AIKit 的执行路径:token 怎么估、流怎么拆、一轮结束时拿到什么,
/// 都收在这儿。`AgentLoop` 只看得见 `AgentModelClient`,换 SDK 时不用动 loop。
struct AIKitModelClient: AgentModelClient {
    let profile: AgentModelProfile

    private let client: AIClient
    private let reporter = ContextReporter()
    /// 思考开关。nil 表示这个模型压根没有思考这回事,那就什么都别说。
    ///
    /// 「什么都不说」不等于「不思考」——DeepSeek、Qwen、GLM 默认就是开的,想关必须显式说。
    /// 反过来也一样要小心:对着一个不会思考的模型发 `thinking: {type: enabled}`,
    /// 有些 provider 直接 400。所以只在目录说这个模型支持思考时才发。
    private let thinking: Thinking?

    init(providerId: String, modelId: String, apiKey: String, thinking: Thinking = .on) throws {
        let info = ProviderCatalog.model(modelId, provider: providerId)?.1
        // 目录里没有的模型(自建 endpoint、比目录新)也按"不会思考"处理:发一个它没听过的
        // 字段,比少发一个字段的后果严重得多。
        self.thinking = (info?.supportsReasoning ?? false) ? thinking : nil
        profile = AgentModelProfile(
            providerId: providerId,
            modelId: modelId,
            contextWindow: info?.contextWindow,
            maxOutputTokens: info?.maxOutputTokens
        )
        client = try AIClient(
            providerId: providerId,
            configuration: .init(apiKey: apiKey)
        )
    }

    func estimateTokens(for request: AgentModelRequest) -> Int {
        reporter.report(callOptions(for: request), contextWindow: profile.contextWindow).used
    }

    func stream(_ request: AgentModelRequest) throws -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        let parts = try client.stream(callOptions(for: request))
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var collected: [StreamPart] = []
                    for try await part in parts {
                        try Task.checkCancellation()
                        collected.append(part)
                        switch part {
                        case .textDelta(_, let delta, _) where !delta.isEmpty:
                            continuation.yield(.textDelta(delta))
                        case .reasoningDelta(_, let delta, _) where !delta.isEmpty:
                            continuation.yield(.reasoningDelta(delta))
                        default:
                            break
                        }
                    }
                    continuation.yield(.completed(AIResponse(parts: collected).agentModelResponse))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func callOptions(for request: AgentModelRequest) -> CallOptions {
        CallOptions(
            model: request.profile.modelId,
            prompt: request.prompt.aiKitPrompt,
            tools: request.capabilities.map(\.aiKitToolDefinition),
            thinking: thinking
        )
    }
}

/// 云端引擎。
///
/// 到这一步它只剩三件 app 自己的事:拿 key、拼系统提示、把 runtime 的错误翻成中文。
/// 工具循环、上下文预算、压缩、换模型迁移全在 `AgentLoop` 里,和健康数据没关系。
struct AIKitEngine: AgentEngine {
    let name = "云端模型"

    private static let maxToolRounds = 6

    private let providerId: String
    private let model: String
    private let topic: ChatTopic?
    private let capabilityRegistry: CapabilityRegistry

    init(
        providerId: String = "anthropic",
        model: String = "claude-sonnet-5",
        topic: ChatTopic? = nil,
        capabilityRegistry: CapabilityRegistry = HealthTools.registry
    ) {
        self.providerId = providerId
        self.model = model
        self.topic = topic
        self.capabilityRegistry = capabilityRegistry
    }

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let client = try AIKitModelClient(
                        providerId: providerId,
                        modelId: model,
                        apiKey: try resolvedAPIKey(),
                        thinking: EngineSettings.thinkingEnabled ? .on : .off
                    )
                    let loop = AgentLoop(
                        client: client,
                        capabilities: capabilityRegistry,
                        systemInstruction: systemInstruction(),
                        compactor: .healthChat,
                        // 总结走同一个模型。理论上换个便宜的更划算,但那要用户再配一份 key
                        // 和模型;等真有人抱怨这笔钱再说。
                        summarizer: ModelSummarizer.healthChat(client: client),
                        policy: .healthChat,
                        maxToolRounds: Self.maxToolRounds,
                        truncatedToolCallNotice: healthChatTruncatedToolCallNotice
                    )
                    for try await event in loop.run(history: history.map(\.agentDTO)) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AgentError.wrapping(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func resolvedAPIKey() throws -> String {
        guard let stored = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }
        return key
    }

    private func systemInstruction() -> String {
        var instructions = HealthAssistantInstructions.text()
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
