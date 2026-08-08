import Foundation

/// 把一轮完整的 agent 活动压成一个显式的 compaction artifact。
///
/// 「压缩」不等于「退回可见回答文本」。一轮里真正发生的事有两份读者:
/// - 用户要的是那段可见回答(`visibleSummary`),折叠提示、会话摘要都用它;
/// - 模型要的是「这轮我查了什么、查出来大概是什么」(`replaySummary`),纯回答文本会把
///   工具轨迹整个丢掉,追问时模型就不知道自己上次查过 daily_steps 了。
///
/// 两份分开生成、一起存,才是能被别的 agent 复用的 artifact,而不是一个临时的省 token 技巧。
public struct TranscriptCompactor: Sendable {
    /// 每次工具调用在摘要里最多占多少字符。超了截断加后缀。
    public var maxCharactersPerToolCall: Int
    /// 摘要里最多列几次工具调用,再多只报个数。
    public var maxToolCallsInDigest: Int
    /// 折叠提示的格式串,只有一个 `%d`(折叠了几次调用)。
    public var digestHeaderFormat: String
    public var truncationSuffix: String
    /// 还有多少次调用没列出来,格式串只有一个 `%d`。
    public var overflowFormat: String

    public init(
        maxCharactersPerToolCall: Int = 160,
        maxToolCallsInDigest: Int = 6,
        digestHeaderFormat: String = "[folded %d tool call(s) from this turn]",
        truncationSuffix: String = "…",
        overflowFormat: String = "(+%d more)"
    ) {
        self.maxCharactersPerToolCall = maxCharactersPerToolCall
        self.maxToolCallsInDigest = maxToolCallsInDigest
        self.digestHeaderFormat = digestHeaderFormat
        self.truncationSuffix = truncationSuffix
        self.overflowFormat = overflowFormat
    }

    public static let `default` = TranscriptCompactor()

    /// 给一条 assistant 消息造 artifact。没有任何可留下的内容就返回 nil。
    public func artifact(for message: AgentChatMessageDTO) -> CompactionArtifact? {
        guard message.role == .assistant else { return nil }

        let visible = message.textIsPlaceholder ? "" : message.text
        let executed = message.toolCalls.filter { $0.output != nil }
        guard !visible.isEmpty || !executed.isEmpty else { return nil }

        let digest = toolDigest(for: executed)
        let replayText = [visible, digest]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !replayText.isEmpty else { return nil }

        return CompactionArtifact(
            kind: digest.isEmpty ? .answerOnly : .toolDigest,
            visibleSummary: visible,
            replaySummary: .assistantSummary(replayText, sourceIDs: [message.id]),
            sourceMessageIDs: [message.id],
            foldedToolCalls: executed.count
        )
    }

    private func toolDigest(for calls: [ToolCallRecordDTO]) -> String {
        guard !calls.isEmpty else { return "" }

        var lines = [String(format: digestHeaderFormat, calls.count)]
        for call in calls.prefix(maxToolCallsInDigest) {
            let output = call.output?.text ?? ""
            let flattened = output
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " / ")
            lines.append("- \(call.name) \(call.input) → \(truncated(flattened))")
        }
        let overflow = calls.count - maxToolCallsInDigest
        if overflow > 0 {
            lines.append(String(format: overflowFormat, overflow))
        }
        return lines.joined(separator: "\n")
    }

    private func truncated(_ text: String) -> String {
        guard text.count > maxCharactersPerToolCall else { return text }
        return text.prefix(maxCharactersPerToolCall) + truncationSuffix
    }
}
