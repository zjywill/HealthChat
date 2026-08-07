import Foundation

// TODO(M3): import FoundationModels

/// 端上引擎:FoundationModels 的 LanguageModelSession + Tool 协议工具调用。
///
/// M3 要做的事:
/// - 可用性检查 `SystemLanguageModel.default.availability`,不可用抛 .modelUnavailable
/// - 五个 HealthTools 各实现一个 `Tool`(@Generable 参数),回调 HealthStore
/// - instructions:健康分析人设、单位习惯、不做医疗诊断
/// - `session.streamResponse` 映射为 AgentEvent;上下文约 4k token,历史要裁剪
struct FoundationModelsEngine: AgentEngine {
    let name = "端上模型"

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.notImplemented) }
    }
}
