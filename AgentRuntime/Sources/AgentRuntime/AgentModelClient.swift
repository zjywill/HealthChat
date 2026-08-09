import Foundation

/// 一次请求打给哪个模型,以及这个模型的窗口有多大。
///
/// 预算和校准都按 provider+model 归档:换了模型,之前那套估算就不作数了。
public struct AgentModelProfile: Equatable, Codable, Sendable {
    public var providerId: String
    public var modelId: String
    public var contextWindow: Int?
    public var maxOutputTokens: Int?

    public init(
        providerId: String,
        modelId: String,
        contextWindow: Int? = nil,
        maxOutputTokens: Int? = nil
    ) {
        self.providerId = providerId
        self.modelId = modelId
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct AgentModelRequest: Sendable {
    public var profile: AgentModelProfile
    public var prompt: AgentTranscript
    public var capabilities: [CapabilityDefinition]

    public init(
        profile: AgentModelProfile,
        prompt: AgentTranscript,
        capabilities: [CapabilityDefinition]
    ) {
        self.profile = profile
        self.prompt = prompt
        self.capabilities = capabilities
    }
}

/// 一轮请求结束时模型给出的全部东西。
///
/// `assistantMessage` 是要原样存进 transcript 的那条(可能同时含文本和 tool_use);
/// `pendingCalls` 是本轮要执行的调用。两者分开:前者管回放,后者管执行。
public struct AgentModelResponse: Sendable {
    public var assistantMessage: AgentTranscript.Message?
    public var pendingCalls: [CapabilityInvocation]
    public var finishReason: AgentFinishReason?
    public var usage: AgentUsage?
    public var servedModelId: String?
    /// provider 在流里报的错。有值就当这轮失败,不看 finishReason。
    public var failureMessage: String?

    public init(
        assistantMessage: AgentTranscript.Message? = nil,
        pendingCalls: [CapabilityInvocation] = [],
        finishReason: AgentFinishReason? = nil,
        usage: AgentUsage? = nil,
        servedModelId: String? = nil,
        failureMessage: String? = nil
    ) {
        self.assistantMessage = assistantMessage
        self.pendingCalls = pendingCalls
        self.finishReason = finishReason
        self.usage = usage
        self.servedModelId = servedModelId
        self.failureMessage = failureMessage
    }
}

public enum AgentModelStreamEvent: Sendable {
    case textDelta(String)
    /// 模型的思考。和 `.textDelta` 分开发:两者在界面上不是一回事,思考默认要能折起来。
    ///
    /// 不是所有模型都有,有的模型只给摘要而不给原文——这两种情况都表现为这个事件不出现,
    /// 上层不该把「没有思考事件」当成异常。
    case reasoningDelta(String)
    case completed(AgentModelResponse)
}

/// runtime 眼里的「模型」就这么多:能估 token,能流式跑一轮。
///
/// AIKit、FoundationModels 或任何别的 SDK 都各写一个适配器实现它——runtime 本身不 import
/// 任何模型 SDK,这是「通用 agent core」和「某个 SDK 的封装」的分界线。
public protocol AgentModelClient: Sendable {
    var profile: AgentModelProfile { get }

    /// 估算这次请求的 prompt token 数。tokenizer 因 provider 而异,所以放在适配层。
    func estimateTokens(for request: AgentModelRequest) -> Int

    func stream(_ request: AgentModelRequest) throws -> AsyncThrowingStream<AgentModelStreamEvent, any Error>
}
