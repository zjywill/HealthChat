import Foundation
import AgentRuntime
import AIKit

extension CapabilityDefinition {
    var aiKitToolDefinition: ToolDefinition {
        ToolDefinition(
            name: name,
            description: description,
            inputSchema: inputSchema.aiKitJSONValue,
            strict: strictPreferred
        )
    }
}

extension AgentTranscript {
    var aiKitPrompt: Prompt {
        messages.map(\.aiKitMessage)
    }
}

extension AIKit.Message {
    var agentTranscriptMessage: AgentTranscript.Message {
        .init(
            role: .init(role),
            parts: content.map(\.agentTranscriptPart),
            metadata: providerOptions.runtimeProviderMetadata
        )
    }
}

extension AgentTranscript.Message {
    var aiKitMessage: AIKit.Message {
        AIKit.Message(
            role: .init(role),
            content: parts.map(\.aiKitContentPart),
            providerOptions: metadata.aiKitProviderMetadata
        )
    }
}

extension FinishReason {
    var agentFinishReason: AgentFinishReason {
        .init(unified: .init(unified), raw: raw)
    }
}

extension Usage {
    var agentUsage: AgentUsage {
        .init(
            inputTokens: .init(
                total: inputTokens.total,
                noCache: inputTokens.noCache,
                cacheRead: inputTokens.cacheRead,
                cacheWrite: inputTokens.cacheWrite
            ),
            outputTokens: .init(
                total: outputTokens.total,
                text: outputTokens.text,
                reasoning: outputTokens.reasoning
            ),
            raw: raw.map(RuntimeJSONValue.init)
        )
    }
}

extension AIResponse {
    /// 一轮流跑完后,AIKit 的响应折成 runtime 认识的形状。
    ///
    /// `assistantMessage` 原样进 transcript(文本和 tool_use 都在里面),`pendingCalls`
    /// 单独拎出来给 loop 执行——回放和执行是两件事。
    var agentModelResponse: AgentModelResponse {
        AgentModelResponse(
            assistantMessage: assistantMessage.content.isEmpty
                ? nil
                : assistantMessage.agentTranscriptMessage,
            pendingCalls: pendingToolCalls.map {
                CapabilityInvocation(
                    toolCallId: $0.toolCallId,
                    name: $0.toolName,
                    input: $0.input
                )
            },
            finishReason: finishReason?.agentFinishReason,
            usage: usage.agentUsage,
            servedModelId: metadata?.modelId,
            failureMessage: errors.first?.message
        )
    }
}

extension HealthReport {
    static func encodeForToolMetadata(_ report: HealthReport) -> RuntimeJSONValue? {
        guard let data = try? JSONEncoder().encode(report) else { return nil }
        return try? JSONDecoder().decode(RuntimeJSONValue.self, from: data)
    }

    static func decode(fromToolMetadata metadata: RuntimeJSONValue?) -> HealthReport? {
        guard let metadata else { return nil }
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return try? JSONDecoder().decode(HealthReport.self, from: data)
    }
}

extension RuntimeJSONValue {
    init(_ value: AIKit.JSONValue) {
        switch value {
        case .null:
            self = .null
        case .bool(let bool):
            self = .bool(bool)
        case .number(let number):
            if number.rounded() == number, let exact = Int(exactly: number) {
                self = .int(exact)
            } else {
                self = .double(number)
            }
        case .string(let string):
            self = .string(string)
        case .array(let array):
            self = .array(array.map(RuntimeJSONValue.init))
        case .object(let object):
            self = .object(object.mapValues(RuntimeJSONValue.init))
        }
    }

    var aiKitJSONValue: AIKit.JSONValue {
        switch self {
        case .string(let string):
            return .string(string)
        case .int(let int):
            return .number(Double(int))
        case .double(let double):
            return .number(double)
        case .bool(let bool):
            return .bool(bool)
        case .object(let object):
            return .object(object.mapValues(\.aiKitJSONValue))
        case .array(let array):
            return .array(array.map(\.aiKitJSONValue))
        case .null:
            return .null
        }
    }
}

private extension AIKit.MessageRole {
    init(_ role: AgentTranscript.Role) {
        switch role {
        case .system: self = .system
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .tool
        }
    }
}

private extension AgentTranscript.Role {
    init(_ role: AIKit.MessageRole) {
        switch role {
        case .system: self = .system
        case .user: self = .user
        case .assistant: self = .assistant
        case .tool: self = .tool
        }
    }
}

private extension AIKit.ContentPart {
    var agentTranscriptPart: AgentTranscript.Part {
        switch self {
        case .text(let text):
            return .text(text)
        case .file(let file):
            return .file(.init(
                mediaType: file.mediaType,
                data: .init(file.data),
                filename: file.filename
            ))
        case .reasoning(let text, let providerMetadata):
            return .reasoning(text, metadata: providerMetadata.runtimeProviderMetadata)
        case .toolCall(let call):
            return .toolCall(.init(
                toolCallId: call.toolCallId,
                toolName: call.toolName,
                input: call.input,
                providerExecuted: call.providerExecuted,
                dynamic: call.dynamic,
                metadata: call.providerMetadata.runtimeProviderMetadata
            ))
        case .toolResult(let result):
            return .toolResult(.init(
                toolCallId: result.toolCallId,
                toolName: result.toolName,
                result: .init(result.result),
                isError: result.isError,
                preliminary: result.preliminary,
                dynamic: result.dynamic,
                metadata: result.providerMetadata.runtimeProviderMetadata
            ))
        }
    }
}

private extension AgentTranscript.Part {
    var aiKitContentPart: AIKit.ContentPart {
        switch self {
        case .text(let text):
            return .text(text)
        case .reasoning(let text, let metadata):
            return .reasoning(
                text,
                providerMetadata: metadata.aiKitProviderMetadata
            )
        case .toolCall(let call):
            return .toolCall(AIKit.ToolCall(
                toolCallId: call.toolCallId,
                toolName: call.toolName,
                input: call.input,
                providerExecuted: call.providerExecuted,
                dynamic: call.dynamic,
                providerMetadata: call.metadata.aiKitProviderMetadata
            ))
        case .toolResult(let result):
            return .toolResult(AIKit.ToolResult(
                toolCallId: result.toolCallId,
                toolName: result.toolName,
                result: result.result.aiKitJSONValue,
                isError: result.isError,
                preliminary: result.preliminary,
                dynamic: result.dynamic,
                providerMetadata: result.metadata.aiKitProviderMetadata
            ))
        case .file(let file):
            return .file(AIKit.FilePart(
                mediaType: file.mediaType,
                data: .init(file.data),
                filename: file.filename
            ))
        }
    }
}

private extension AIKit.FilePart.Payload {
    init(_ payload: AgentTranscript.FilePart.Payload) {
        switch payload {
        case .base64(let value):
            self = .base64(value)
        case .url(let value):
            self = .url(value)
        }
    }
}

private extension AgentTranscript.FilePart.Payload {
    init(_ payload: AIKit.FilePart.Payload) {
        switch payload {
        case .base64(let value):
            self = .base64(value)
        case .url(let value):
            self = .url(value)
        }
    }
}

private extension AgentFinishReason.Unified {
    init(_ unified: FinishReason.Unified) {
        switch unified {
        case .stop: self = .stop
        case .length: self = .length
        case .contentFilter: self = .contentFilter
        case .toolCalls: self = .toolCalls
        case .error: self = .error
        case .other: self = .other
        }
    }
}

private extension RuntimeProviderMetadata {
    var aiKitProviderMetadata: AIKit.ProviderMetadata? {
        guard !isEmpty else { return nil }
        return mapValues { $0.mapValues(\.aiKitJSONValue) }
    }
}

private extension Optional where Wrapped == AIKit.ProviderMetadata {
    var runtimeProviderMetadata: RuntimeProviderMetadata {
        guard let wrapped = self else { return [:] }
        return wrapped.mapValues { $0.mapValues(RuntimeJSONValue.init) }
    }
}
