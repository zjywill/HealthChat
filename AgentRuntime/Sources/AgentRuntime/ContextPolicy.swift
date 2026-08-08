import Foundation

/// 上下文什么时候压、压到什么程度、哪些绝对不能动。
///
/// 三条规则各管一件事:
/// - `compactionThreshold`:**没超之前**就开始压。等超了再压就晚了——那一轮已经要么被 provider
///   拒收,要么被迫连最近的几轮一起丢。
/// - `preservedRecentTurns`:最近几轮永远保持原样。刚查完的数据被压成一句摘要,用户下一句
///   "那第三天呢"就答不上来了。压的必须是远处的。
/// - `thresholdAfterModelSwitch`:换模型之后估算本来就不准(校准作废了),阈值再压低一档,
///   给自己留出余量。
public struct ContextPolicy: Equatable, Sendable {
    public var compactionThreshold: Double
    public var preservedRecentTurns: Int
    public var thresholdAfterModelSwitch: Double
    /// 一段少于这么多条消息就不值得单独叫模型总结一次。
    public var minimumSpanMessages: Int

    public init(
        compactionThreshold: Double = 0.8,
        preservedRecentTurns: Int = 2,
        thresholdAfterModelSwitch: Double = 0.6,
        minimumSpanMessages: Int = 3
    ) {
        self.compactionThreshold = compactionThreshold
        self.preservedRecentTurns = preservedRecentTurns
        self.thresholdAfterModelSwitch = thresholdAfterModelSwitch
        self.minimumSpanMessages = minimumSpanMessages
    }

    public static let `default` = ContextPolicy()
}

/// 该被总结掉的那一段。
public struct SummarizationPlan: Equatable, Sendable {
    /// artifact 挂在这条消息上。它是这一段的最后一条,位置正好是摘要该出现的地方。
    public var ownerMessageID: UUID
    /// 这一段覆盖了哪些消息。包含之前已经被压进来的——链子不能断,否则下一次压缩会把
    /// 已经折叠过的内容当成还在原样躺着。
    public var sourceMessageIDs: [UUID]
    /// 摊平成纯文本的原文。
    ///
    /// 不直接把带 tool_use 的消息发去总结:那要求这次请求也声明同一批工具,而且各家
    /// provider 对孤立 tool 块的校验口径不一样。摊平成文本没有这些坑。
    public var spanText: String
    public var messageCount: Int

    public init(
        ownerMessageID: UUID,
        sourceMessageIDs: [UUID],
        spanText: String,
        messageCount: Int
    ) {
        self.ownerMessageID = ownerMessageID
        self.sourceMessageIDs = sourceMessageIDs
        self.spanText = spanText
        self.messageCount = messageCount
    }
}

/// 把一段对话变成一份 artifact。
///
/// 分成协议,是因为「谁来写这份摘要」是可换的:现在是再叫一次模型,以后也可以是端上小模型、
/// 或者一份结构化的 memory object。loop 不关心。
public protocol AgentSummarizer: Sendable {
    func summarize(_ plan: SummarizationPlan) async throws -> CompactionArtifact
}

/// 叫模型自己写摘要。
///
/// 一次调用同时要两份:给用户看的一句话,和给模型回放的详细摘要。分两次调用是白花一次钱,
/// 而这两份的取舍本来就该在同一个上下文里做。
public struct ModelSummarizer: AgentSummarizer {
    public var client: any AgentModelClient
    /// 系统提示。要写明「两份摘要各给谁看」,否则模型只会写一份客套话。
    public var instruction: String
    /// 用户消息的格式串,一个 `%@` 放摊平后的原文。
    public var requestFormat: String
    /// 模型没按标签输出时,给用户看的那句兜底文案(格式串,一个 `%d` 放消息条数)。
    public var fallbackVisibleFormat: String

    public init(
        client: any AgentModelClient,
        instruction: String = ModelSummarizer.defaultInstruction,
        requestFormat: String = "Summarize the conversation below.\n\n%@",
        fallbackVisibleFormat: String = "Earlier conversation folded (%d messages)."
    ) {
        self.client = client
        self.instruction = instruction
        self.requestFormat = requestFormat
        self.fallbackVisibleFormat = fallbackVisibleFormat
    }

    public static let defaultInstruction = """
        You compress an agent conversation so it can continue in a smaller context window.
        Produce exactly two sections, each wrapped in tags:

        <visible>One sentence for the human, recapping what has been covered so far.</visible>
        <replay>A dense briefing for the assistant that will continue this conversation. \
        Keep: conclusions already reached, which tools were called with which arguments, \
        the concrete numbers those tools returned, and any constraint or preference the user stated. \
        Drop: pleasantries, restated questions, and raw rows already summarised by a conclusion. \
        Write it as notes, not prose.</replay>

        Never invent facts that are not in the conversation.
        """

    public func summarize(_ plan: SummarizationPlan) async throws -> CompactionArtifact {
        let request = AgentModelRequest(
            profile: client.profile,
            prompt: AgentTranscript(messages: [
                .system(instruction),
                .user(String(format: requestFormat, plan.spanText))
            ]),
            capabilities: []
        )

        var text = ""
        for try await event in try client.stream(request) {
            try Task.checkCancellation()
            if case .textDelta(let delta) = event {
                text += delta
            }
        }

        let visible = text.taggedSection("visible")
        let replay = text.taggedSection("replay")
        // 标签没解析出来也不能空手而归:整段文本至少还是个摘要,比退回原文省得多。
        let replayText = replay ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !replayText.isEmpty else {
            throw AgentLoopError.incompleteResponse
        }

        return CompactionArtifact(
            kind: .modelGenerated,
            visibleSummary: visible ?? String(format: fallbackVisibleFormat, plan.messageCount),
            replaySummary: .assistantSummary(replayText, sourceIDs: plan.sourceMessageIDs),
            sourceMessageIDs: plan.sourceMessageIDs,
            foldedToolCalls: 0
        )
    }
}

private extension String {
    func taggedSection(_ tag: String) -> String? {
        guard let start = range(of: "<\(tag)>"),
              let end = range(of: "</\(tag)>", range: start.upperBound..<endIndex) else {
            return nil
        }
        let section = self[start.upperBound..<end.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return section.isEmpty ? nil : section
    }
}
