import Foundation

public typealias RuntimeProviderMetadata = [String: [String: RuntimeJSONValue]]

public struct AgentTranscript: Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public enum Part: Equatable, Codable, Sendable {
        case text(String)
        case reasoning(String, metadata: RuntimeProviderMetadata = [:])
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case file(FilePart)
    }

    public struct FilePart: Equatable, Codable, Sendable {
        public enum Payload: Equatable, Codable, Sendable {
            case base64(String)
            case url(String)
        }

        public var mediaType: String
        public var data: Payload
        public var filename: String?

        public init(mediaType: String, data: Payload, filename: String? = nil) {
            self.mediaType = mediaType
            self.data = data
            self.filename = filename
        }
    }

    public struct ToolCall: Equatable, Codable, Sendable {
        public var toolCallId: String
        public var toolName: String
        public var input: String
        public var providerExecuted: Bool
        public var dynamic: Bool
        public var metadata: RuntimeProviderMetadata

        public init(
            toolCallId: String,
            toolName: String,
            input: String,
            providerExecuted: Bool = false,
            dynamic: Bool = false,
            metadata: RuntimeProviderMetadata = [:]
        ) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.input = input
            self.providerExecuted = providerExecuted
            self.dynamic = dynamic
            self.metadata = metadata
        }
    }

    public struct ToolResult: Equatable, Codable, Sendable {
        public var toolCallId: String
        public var toolName: String
        public var result: RuntimeJSONValue
        public var isError: Bool
        public var preliminary: Bool
        public var dynamic: Bool
        public var metadata: RuntimeProviderMetadata

        public init(
            toolCallId: String,
            toolName: String,
            result: RuntimeJSONValue,
            isError: Bool = false,
            preliminary: Bool = false,
            dynamic: Bool = false,
            metadata: RuntimeProviderMetadata = [:]
        ) {
            self.toolCallId = toolCallId
            self.toolName = toolName
            self.result = result
            self.isError = isError
            self.preliminary = preliminary
            self.dynamic = dynamic
            self.metadata = metadata
        }
    }

    public struct Message: Equatable, Codable, Sendable {
        public var role: Role
        public var parts: [Part]
        public var metadata: RuntimeProviderMetadata

        public init(role: Role, parts: [Part], metadata: RuntimeProviderMetadata = [:]) {
            self.role = role
            self.parts = parts
            self.metadata = metadata
        }
    }

    public var messages: [Message]

    public init(messages: [Message] = []) {
        self.messages = messages
    }
}

public extension AgentTranscript.Message {
    static func system(_ text: String) -> Self {
        .init(role: .system, parts: [.text(text)])
    }

    static func user(_ text: String) -> Self {
        .init(role: .user, parts: [.text(text)])
    }

    static func assistant(_ text: String) -> Self {
        .init(role: .assistant, parts: [.text(text)])
    }

    static func toolResult(
        toolCallId: String,
        toolName: String,
        result: RuntimeJSONValue,
        isError: Bool = false
    ) -> Self {
        .init(role: .tool, parts: [
            .toolResult(.init(
                toolCallId: toolCallId,
                toolName: toolName,
                result: result,
                isError: isError
            ))
        ])
    }
}

public extension AgentTranscript.Message {
    var text: String {
        parts.compactMap {
            if case .text(let text) = $0 { return text }
            return nil
        }.joined()
    }

    var isEmpty: Bool {
        parts.isEmpty || parts.allSatisfy {
            switch $0 {
            case .text(let text): return text.isEmpty
            default: return false
            }
        }
    }
}
