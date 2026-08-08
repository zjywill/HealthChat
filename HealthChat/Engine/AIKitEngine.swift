import Foundation
import AIKit

struct AIKitEngine: AgentEngine {
    let name = "云端模型"

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
        // 只有 workouts 支持按类型筛。用 enum 而不是自由字符串:模型写“跑”或者
        // “running”都对不上 HealthKit 那套中文名,筛出来会是空的。
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
            ])
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
                let days = HealthTools.days(fromInput: call.input)

                continuation.yield(.toolCallStarted(ToolCallRecord(
                    id: call.toolCallId,
                    name: call.toolName,
                    input: call.input
                )))

                let outcome: (output: String, isError: Bool)
                if let spec = HealthTools.spec(named: call.toolName) {
                    do {
                        outcome = (
                            try await spec.run(days, HealthTools.activity(fromInput: call.input)),
                            false
                        )
                    } catch {
                        outcome = ("健康数据查询失败：\(error.localizedDescription)", true)
                    }
                } else {
                    outcome = ("不支持名为 \(call.toolName) 的健康工具。", true)
                }

                continuation.yield(.toolCallFinished(
                    id: call.toolCallId,
                    output: outcome.output,
                    isError: outcome.isError
                ))
                prompt.append(.toolResult(
                    toolCallId: call.toolCallId,
                    toolName: call.toolName,
                    result: .string(outcome.output),
                    isError: outcome.isError
                ))
            }
        }

        throw AgentError.toolLoopLimit
    }

    /// 把整段历史还原成 prompt——包括上几轮的工具调用和结果。
    ///
    /// 只回放文本会让模型失忆:它看不到自己查过什么,追问时只能重查或顺着上一段
    /// 总结编。失败的回合整轮跳过——那段"无法回复：…"是 app 写给用户看的,不是
    /// 模型说过的话;而且带着一个没有结果的 tool_use 回去,provider 会直接拒收。
    private func makePrompt(from history: [ChatMessage]) -> Prompt {
        // 话题是用户在新会话时自己选的,写进系统提示比让模型从问题里猜准得多:
        // 它直接决定先调哪个工具、按哪种口径回答。
        let instructions = topic.map {
            "\(HealthAssistantInstructions.text)\n\n本次对话的话题：\($0.name)。\($0.focus)"
        } ?? HealthAssistantInstructions.text
        var prompt: Prompt = [.system(instructions)]

        for message in history {
            switch message.role {
            case .user:
                guard !message.text.isEmpty else { continue }
                prompt.append(.user(message.text))

            case .assistant:
                guard message.errorDescription == nil else { continue }

                let completed = message.toolCalls.filter { $0.output != nil }
                var content: [ContentPart] = []
                if !message.text.isEmpty {
                    content.append(.text(message.text))
                }
                content.append(contentsOf: completed.map { call in
                    .toolCall(ToolCall(
                        toolCallId: call.id,
                        toolName: call.name,
                        input: call.input
                    ))
                })

                guard !content.isEmpty else { continue }
                prompt.append(Message(role: .assistant, content: content))

                // tool_use 后面必须紧跟对应的 tool_result,顺序不能错开。
                for call in completed {
                    prompt.append(.toolResult(
                        toolCallId: call.id,
                        toolName: call.name,
                        result: .string(call.output ?? ""),
                        isError: call.isError
                    ))
                }
            }
        }

        return prompt
    }
}
