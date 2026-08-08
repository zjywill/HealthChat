import Foundation
import AIKit

struct AIKitEngine: AgentEngine {
    let name = "云端模型"

    private static let toolDefinitions = HealthTools.all.map { spec in
        ToolDefinition(
            name: spec.name,
            description: spec.description,
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "days": .object([
                        "type": "integer",
                        "description": "查询最近多少天，范围 1–90，默认 7",
                        "minimum": 1,
                        "maximum": 90,
                        "default": 7
                    ])
                ]),
                "required": .array(["days"]),
                "additionalProperties": false
            ])
        )
    }

    private let providerId: String
    private let model: String

    init(providerId: String = "anthropic", model: String = "claude-sonnet-5") {
        self.providerId = providerId
        self.model = model
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
                        prompt: makePrompt(from: history),
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
        prompt initialPrompt: Prompt,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        var prompt = initialPrompt

        for _ in 0..<6 {
            let options = CallOptions(
                model: model,
                prompt: prompt,
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
            guard !response.pendingToolCalls.isEmpty else {
                return
            }

            prompt.append(response.assistantMessage)
            for call in response.pendingToolCalls {
                let days = Self.days(from: call.input)
                guard let spec = HealthTools.spec(named: call.toolName) else {
                    prompt.append(.toolResult(
                        toolCallId: call.toolCallId,
                        toolName: call.toolName,
                        result: .string("不支持名为 \(call.toolName) 的健康工具。"),
                        isError: true
                    ))
                    continue
                }

                continuation.yield(.toolCall(HealthTools.note(for: spec.name, days: days)))
                do {
                    let result = try await spec.run(days)
                    prompt.append(.toolResult(
                        toolCallId: call.toolCallId,
                        toolName: call.toolName,
                        result: .string(result)
                    ))
                } catch {
                    prompt.append(.toolResult(
                        toolCallId: call.toolCallId,
                        toolName: call.toolName,
                        result: .string("健康数据查询失败：\(error.localizedDescription)"),
                        isError: true
                    ))
                }
            }
        }

        throw AgentError.toolLoopLimit
    }

    private func makePrompt(from history: [ChatMessage]) -> Prompt {
        var prompt: Prompt = [.system(HealthAssistantInstructions.text)]
        prompt.append(contentsOf: history.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return .user(message.text)
            case .assistant:
                return .assistant(message.text)
            }
        })
        return prompt
    }

    private static func days(from input: String) -> Int {
        let requested = (try? JSONValue.decode(from: input))?["days"]?.intValue ?? 7
        return min(max(requested, 1), 90)
    }
}
