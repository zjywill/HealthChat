import Foundation

/// 本地估算和 provider 实际计费的比值。
///
/// 本地 tokenizer 和服务端从来对不齐,差个 10%~30% 很正常。拿上一轮的 usage 回来校准,
/// 后面几轮的预算就准得多。
///
/// 关键是这个比值**按模型归档**:换了 provider 或模型,tokenizer 就换了,旧比值直接作废,
/// 宁可回到裸估算也不要拿别人的尺子量。
public struct ContextCalibration: Equatable, Sendable {
    public private(set) var scale: Double?

    public init(scale: Double? = nil) {
        self.scale = scale
    }

    /// 从历史里找最近一轮「同一个模型」留下的估算/实际对照。
    public init(history: [AgentChatMessageDTO], profile: AgentModelProfile) {
        scale = history.reversed().compactMap { message -> Double? in
            guard message.role == .assistant,
                  let context = message.storedTurn.context,
                  context.matches(providerId: profile.providerId, requestedModelId: profile.modelId),
                  let estimated = context.estimatedPromptTokens,
                  let actual = context.actualPromptTokens,
                  estimated > 0,
                  actual > 0 else {
                return nil
            }
            return Double(actual) / Double(estimated)
        }.first
    }

    public mutating func note(actual: Int?, estimated: Int) {
        guard let actual, actual > 0, estimated > 0 else { return }
        scale = Double(actual) / Double(estimated)
    }

    public func apply(to estimate: Int) -> Int {
        guard let scale, scale > 0 else { return estimate }
        return max(1, Int((Double(estimate) * scale).rounded()))
    }
}
