import Foundation

public struct CapabilityDefinition: Equatable, Codable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: RuntimeJSONValue
    public var strictPreferred: Bool

    public init(
        name: String,
        description: String? = nil,
        inputSchema: RuntimeJSONValue,
        strictPreferred: Bool = false
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strictPreferred = strictPreferred
    }
}

public struct CapabilityInvocation: Equatable, Codable, Sendable {
    public var toolCallId: String
    public var name: String
    public var input: String

    public init(toolCallId: String, name: String, input: String) {
        self.toolCallId = toolCallId
        self.name = name
        self.input = input
    }
}

public struct CapabilityExecutionResult: Equatable, Codable, Sendable {
    public var output: AgentToolOutput
    public var isError: Bool

    public init(output: AgentToolOutput, isError: Bool = false) {
        self.output = output
        self.isError = isError
    }
}

/// runtime 和「能干什么」之间的唯一接口。
///
/// HealthKit、Calendar、Files 在这一层长得一模一样:一组 JSON Schema 加一个执行闭包。
/// loop 不知道自己在查步数还是在读日历,这正是它能被别的 app 复用的原因。
public struct CapabilityRegistry: Sendable {
    public static let empty = CapabilityRegistry(definitions: []) { invocation in
        CapabilityExecutionResult(
            output: .init(kind: .text, text: "no capability named \(invocation.name)"),
            isError: true
        )
    }

    public var definitions: [CapabilityDefinition]
    private let executeClosure: @Sendable (CapabilityInvocation) async -> CapabilityExecutionResult

    public init(
        definitions: [CapabilityDefinition],
        execute: @escaping @Sendable (CapabilityInvocation) async -> CapabilityExecutionResult
    ) {
        self.definitions = definitions
        self.executeClosure = execute
    }

    public func execute(_ invocation: CapabilityInvocation) async -> CapabilityExecutionResult {
        await executeClosure(invocation)
    }

    public func definition(named name: String) -> CapabilityDefinition? {
        definitions.first { $0.name == name }
    }
}
