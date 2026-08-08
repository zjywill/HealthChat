import Foundation

/// 引擎在一轮回复中吐出的事件:文本增量,或一次健康查询的开始与结束。
///
/// 开始和结束分开发:工具跑起来先让界面有反应,结果回来再补上——合成一个事件的话,
/// 慢查询期间界面上什么都不会动。
enum AgentEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCallRecord)
    case toolCallFinished(id: String, output: String, isError: Bool)
}

enum AgentError: LocalizedError {
    case needsAPIKey
    case needsModelSelection
    case cloudService(String)
    case toolLoopLimit

    var errorDescription: String? {
        switch self {
        case .needsAPIKey: "需要先在设置里填写云端 API key"
        case .needsModelSelection: "需要先在设置里选择云端模型"
        case .cloudService(let message): "云端服务返回错误：\(message)"
        case .toolLoopLimit: "健康查询次数过多，请缩小问题范围后重试"
        }
    }
}

/// 对话引擎统一接口。UI 层只认这个协议和 AgentEvent,不感知引擎差异。
/// 当前唯一实现是 AIKitEngine(端上 FoundationModels 引擎暂时移除,见 PLAN.md M3)。
protocol AgentEngine: Sendable {
    var name: String { get }

    /// 发送一轮对话,流式返回事件。工具调用(HealthTools)在引擎内部完成。
    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error>
}
