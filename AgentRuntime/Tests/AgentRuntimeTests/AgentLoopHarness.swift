import Foundation

@testable import AgentRuntime

/// 脚本化的假模型:每一轮该回什么写死在数组里,不发网络请求。
///
/// 它同时记下每一轮实际收到的 prompt——loop 集成测试真正要验的就是「这一轮到底发了什么
/// 出去」,而不只是「最后 UI 上留下了什么」。
final class ScriptedModelClient: AgentModelClient, @unchecked Sendable {
    struct Turn: Sendable {
        var textDeltas: [String] = []
        var toolCalls: [CapabilityInvocation] = []
        var finishReason: AgentFinishReason = .init(unified: .stop)
        var usage: AgentUsage?
        var servedModelId: String?
        var failureMessage: String?
        /// 这一轮开口之前先跑一下。挂住某一轮,好在模型还没说话时制造取消。
        ///
        /// 必须挂在开口**之前**:挂在之后的话,delta 已经进了 stream 的缓冲区,消费者会先把
        /// 缓冲区抽干再发现自己被取消了——测试就变成看谁跑得快。
        var beforeResponding: (@Sendable () async throws -> Void)?
    }

    let profile: AgentModelProfile

    private let lock = NSLock()
    private var turns: [Turn]
    private var _requests: [AgentModelRequest] = []
    /// 一个字符算一个 token。够用了——测试要的是「压没压」,不是估得准不准。
    private let tokensPerCharacter: Double

    var requests: [AgentModelRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _requests
    }

    var lastPrompt: AgentTranscript? { requests.last?.prompt }

    init(
        profile: AgentModelProfile,
        turns: [Turn],
        tokensPerCharacter: Double = 1
    ) {
        self.profile = profile
        self.turns = turns
        self.tokensPerCharacter = tokensPerCharacter
    }

    func estimateTokens(for request: AgentModelRequest) -> Int {
        let characters = request.prompt.messages.reduce(0) { total, message in
            total + message.parts.reduce(0) { $0 + $1.approximateCharacterCount }
        }
        return Int((Double(characters) * tokensPerCharacter).rounded())
    }

    func stream(_ request: AgentModelRequest) throws -> AsyncThrowingStream<AgentModelStreamEvent, any Error> {
        lock.lock()
        _requests.append(request)
        let turn = turns.isEmpty ? Turn() : turns.removeFirst()
        lock.unlock()

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await turn.beforeResponding?()
                    try Task.checkCancellation()

                    var parts: [AgentTranscript.Part] = []
                    for delta in turn.textDeltas {
                        try Task.checkCancellation()
                        continuation.yield(.textDelta(delta))
                    }
                    let text = turn.textDeltas.joined()
                    if !text.isEmpty {
                        parts.append(.text(text))
                    }
                    parts.append(contentsOf: turn.toolCalls.map {
                        .toolCall(.init(toolCallId: $0.toolCallId, toolName: $0.name, input: $0.input))
                    })

                    continuation.yield(.completed(AgentModelResponse(
                        assistantMessage: parts.isEmpty
                            ? nil
                            : .init(role: .assistant, parts: parts),
                        pendingCalls: turn.toolCalls,
                        finishReason: turn.finishReason,
                        usage: turn.usage,
                        servedModelId: turn.servedModelId,
                        failureMessage: turn.failureMessage
                    )))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

extension AgentTranscript.Part {
    var approximateCharacterCount: Int {
        switch self {
        case .text(let text): return text.count
        case .reasoning(let text, _): return text.count
        case .toolCall(let call): return call.toolName.count + call.input.count
        case .toolResult(let result):
            return result.toolName.count + ((try? result.result.encodedString().count) ?? 0)
        case .file: return 0
        }
    }
}

extension AgentTranscript {
    var allText: String {
        messages.map(\.text).joined(separator: "\n")
    }

    func contains(_ needle: String) -> Bool {
        allText.contains(needle) || messages.contains { message in
            message.parts.contains { part in
                if case .toolResult(let result) = part {
                    return (result.result.stringValue ?? "").contains(needle)
                }
                return false
            }
        }
    }
}

/// 一组固定输出的能力,不碰任何系统框架。
func stubRegistry(
    _ outputs: [String: String],
    onExecute: (@Sendable (CapabilityInvocation) -> Void)? = nil
) -> CapabilityRegistry {
    CapabilityRegistry(
        definitions: outputs.keys.sorted().map { name in
            CapabilityDefinition(
                name: name,
                description: "stub \(name)",
                inputSchema: .object(["type": .string("object")])
            )
        }
    ) { invocation in
        onExecute?(invocation)
        guard let text = outputs[invocation.name] else {
            return CapabilityExecutionResult(
                output: .init(kind: .text, text: "unknown"),
                isError: true
            )
        }
        return CapabilityExecutionResult(output: .init(kind: .table, text: text))
    }
}

func collect(
    _ loop: AgentLoop,
    history: [AgentChatMessageDTO]
) async -> (messages: [AgentChatMessageDTO], error: (any Error)?) {
    var result = history
    AgentTurnReducer.startReply(in: &result)
    do {
        for try await event in loop.run(history: history) {
            AgentTurnReducer.apply(event, in: &result)
        }
    } catch {
        return (result, error)
    }
    return (result, nil)
}
