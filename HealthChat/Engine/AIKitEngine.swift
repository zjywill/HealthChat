import Foundation
import AIKit

/// 云端引擎:走 AIKit(zjywill/aikitswift,本地包 ../aikitswift)的统一 provider 层,
/// catalog 里 49 个 provider 都能用,默认 anthropic / claude-sonnet-5。
///
/// M4 要做的事:
/// - key 从 Keychain 读,没有则抛 .needsAPIKey;`AIClient(providerId:configuration:)`
/// - HealthTools 映射为 `[ToolDefinition]`(JSON Schema)挂到 `CallOptions.tools`
/// - `client.stream(...)`:`.textDelta` → AgentEvent.textDelta;`.toolCall` →
///   执行 HealthStore 查询并发 AgentEvent.toolCall;`pendingToolCalls` +
///   `assistantMessage` 追加续轮,循环直到没有待执行工具
/// - 只上传聚合摘要(HealthTools 天然如此),不传原始样本
struct AIKitEngine: AgentEngine {
    let name = "云端(AIKit)"

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AgentError.notImplemented) }
    }
}
