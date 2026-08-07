import Foundation

/// Claude 引擎:Anthropic Messages API + tool use 循环 + SSE 流式。
///
/// M4 要做的事:
/// - key 从 Keychain 读,没有则抛 .needsAPIKey
/// - 默认 `claude-sonnet-5`,设置可切 `claude-opus-5`
/// - tools 用 HealthTools 的 JSON Schema;stop_reason == tool_use 时执行查询、
///   以 tool_result 续请求,循环直到文本结束
/// - SSE 增量映射为 .textDelta,工具调用映射为 .toolCall
/// - 只上传聚合摘要(HealthTools 天然如此),不传原始样本
struct ClaudeEngine: AgentEngine {
    let name = "Claude"

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.notImplemented) }
    }
}
