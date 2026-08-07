import Foundation

/// 引擎在一轮回复中吐出的事件:文本增量,或一次健康查询的说明(如"查询了最近 7 天步数")。
enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCall(String)
}

enum AgentError: LocalizedError {
    case notImplemented
    case modelUnavailable
    case needsAPIKey

    var errorDescription: String? {
        switch self {
        case .notImplemented: "这个引擎还没实现"
        case .modelUnavailable: "端上模型不可用(需要开启 Apple Intelligence)"
        case .needsAPIKey: "需要先在设置里填 Claude API key"
        }
    }
}

/// 对话引擎统一接口。UI 层只认这个协议和 AgentEvent,不感知引擎差异。
/// 实现:EchoEngine(M0 占位)、FoundationModelsEngine(M3)、ClaudeEngine(M4)。
protocol AgentEngine: Sendable {
    var name: String { get }

    /// 发送一轮对话,流式返回事件。工具调用(HealthTools)在引擎内部完成。
    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error>
}
