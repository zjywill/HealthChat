import Foundation

/// 换模型时怎么处理已有历史。
public enum HistoryMigrationPolicy: String, Codable, Sendable {
    /// 不管窗口大小,历史照原样回放。
    case never
    /// 换到窗口更小(或大小未知)的模型时,老的几轮**优先**被压缩,阈值也压低一档。
    ///
    /// 注意是"优先",不是"无条件"。之前那版换个模型就把所有工具轨迹铲平,哪怕整段对话
    /// 只有两轮、离新窗口还差得远——白丢了追问要用的数据。压不压由预算说了算,换模型只
    /// 决定**先压谁**。
    case whenWindowShrinks
    /// 只要 provider 或模型变了,老的几轮就立刻换成压缩形态。
    case always
}

/// 把 app 的会话历史铺成一份可以直接发给模型的 transcript。
///
/// 三档,从轻到重:
/// 1. 整段摘要(`SummarizationPlan` → `CompactionArtifact`)——由 loop 在跨过阈值时叫模型生成,
///    这里只负责认出并回放它;
/// 2. 逐轮压缩——把某一轮的原始工具输出换成它的摘要形态;
/// 3. 丢掉最老的一轮——前两档都不够时的最后手段。
///
/// 最近 `preservedRecentTurns` 轮在第 1、2 档里受保护,只有真的超预算了才动。
public struct ConversationHistoryPlanner: Sendable {
    public struct PreparedHistory: Equatable, Sendable {
        public var prompt: AgentTranscript
        public var estimatedPromptTokens: Int
        public var compactedAssistantMessages: Int
        public var droppedConversationTurns: Int
        public var summarizedSpans: Int
        public var migrationNotes: [String]
        /// 该压的都压了、该丢的都丢了,还是超预算。
        public var exceedsBudget: Bool

        public var providerId: String
        public var requestedModelId: String
        public var contextWindow: Int?
        public var reservedOutputTokens: Int?

        public func snapshot(
            servedModelId: String?,
            actualPromptTokens: Int?
        ) -> TurnContextSnapshotDTO {
            TurnContextSnapshotDTO(
                providerId: providerId,
                requestedModelId: requestedModelId,
                servedModelId: servedModelId,
                contextWindow: contextWindow,
                reservedOutputTokens: reservedOutputTokens,
                estimatedPromptTokens: estimatedPromptTokens,
                actualPromptTokens: actualPromptTokens,
                compactedAssistantMessages: compactedAssistantMessages,
                droppedConversationTurns: droppedConversationTurns,
                summarizedSpans: summarizedSpans,
                migrationNotes: migrationNotes
            )
        }
    }

    public static let modelSwitchNote = "history_compacted_for_model_switch"

    public var systemInstruction: String
    public var profile: AgentModelProfile
    public var reservedOutputTokens: Int?
    public var compactor: TranscriptCompactor
    public var migrationPolicy: HistoryMigrationPolicy
    public var policy: ContextPolicy
    public var estimateTokens: @Sendable (AgentTranscript) -> Int

    public init(
        systemInstruction: String,
        profile: AgentModelProfile,
        reservedOutputTokens: Int? = nil,
        compactor: TranscriptCompactor = .default,
        migrationPolicy: HistoryMigrationPolicy = .whenWindowShrinks,
        policy: ContextPolicy = .default,
        estimateTokens: @escaping @Sendable (AgentTranscript) -> Int
    ) {
        self.systemInstruction = systemInstruction
        self.profile = profile
        self.reservedOutputTokens = reservedOutputTokens
        self.compactor = compactor
        self.migrationPolicy = migrationPolicy
        self.policy = policy
        self.estimateTokens = estimateTokens
    }

    /// 发得出去的那份预算(窗口减掉留给输出的部分)。
    public var budget: Int? {
        profile.contextWindow.map { max(0, $0 - (reservedOutputTokens ?? 0)) }
    }

    /// 开始压缩的水位。没超之前就动手,别等撞墙。
    public func softBudget(modelSwitched: Bool) -> Int? {
        budget.map { budget in
            let ratio = modelSwitched ? policy.thresholdAfterModelSwitch : policy.compactionThreshold
            return Int((Double(budget) * min(max(ratio, 0.1), 1)).rounded())
        }
    }

    /// 这一轮要不要叫模型写一份整段摘要;要的话总结哪一段。
    ///
    /// 只有跨过水位线才返回非 nil——总结是一次真实的模型调用,不该每轮都花。
    public func summarizationPlan(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript = .init()
    ) -> SummarizationPlan? {
        let items = historyItems(from: history)
        guard let soft = softBudget(modelSwitched: items.contains(where: \.isMigrationCandidate)) else {
            return nil
        }
        guard estimateTokens(render(items: items, runtimeTranscript: runtimeTranscript)) > soft else {
            return nil
        }

        let absorbed = absorbedMessageIDs(in: history)
        let visible = history.filter { !absorbed.contains($0.id) }
        let cut = firstUnprotectedBoundary(in: visible)
        let span = Array(visible[..<cut]).filter { $0.hasReplayableContent || $0.role == .user }
        guard span.count >= policy.minimumSpanMessages, let owner = span.last else { return nil }

        // 已经被吸收进来的那些也要记在账上,否则下次压缩会以为它们还原样躺着。
        var sourceIDs = span.map(\.id)
        for message in span {
            if let existing = message.storedTurn.compaction, existing.sourceMessageIDs.count > 1 {
                sourceIDs.append(contentsOf: existing.sourceMessageIDs)
            }
        }

        let spanTranscript = AgentTranscript(messages: span.flatMap { message -> [AgentTranscript.Message] in
            switch message.role {
            case .user:
                return message.textIsPlaceholder ? [] : [.user(message.text)]
            case .assistant:
                if let artifact = message.storedTurn.compaction, artifact.sourceMessageIDs.count > 1 {
                    return [artifact.replaySummary]
                }
                return message.exactReplayMessages.isEmpty
                    ? message.reconstructedReplayMessages
                    : message.exactReplayMessages
            }
        })
        guard !spanTranscript.messages.isEmpty else { return nil }

        return SummarizationPlan(
            ownerMessageID: owner.id,
            sourceMessageIDs: Array(Set(sourceIDs)).sorted { $0.uuidString < $1.uuidString },
            spanText: spanTranscript.plainTextRendering(),
            messageCount: span.count
        )
    }

    public func prepare(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript = .init()
    ) -> PreparedHistory {
        var items = historyItems(from: history)
        let summarizedSpans = items.reduce(into: 0) { count, item in
            if case .summary = item { count += 1 }
        }
        let modelSwitched = items.contains(where: \.isMigrationCandidate)
        var compacted = 0
        var dropped = 0
        var migrated = false

        var prompt = render(items: items, runtimeTranscript: runtimeTranscript)
        var estimate = estimateTokens(prompt)

        func reRender() {
            prompt = render(items: items, runtimeTranscript: runtimeTranscript)
            estimate = estimateTokens(prompt)
        }

        // 第一档:没超预算但过了水位线,先压远处的,最近几轮不动。
        if let soft = softBudget(modelSwitched: modelSwitched) {
            let protectedFrom = firstProtectedItemIndex(in: items)
            while estimate > soft,
                  compactOldestAssistant(in: &items, before: protectedFrom, migratedOut: &migrated) {
                compacted += 1
                reRender()
            }
        }

        // 第二档:真超了,最近几轮也保不住;还不够就丢最老的一轮。
        if let budget {
            while estimate > budget {
                if compactOldestAssistant(in: &items, before: items.count, migratedOut: &migrated) {
                    compacted += 1
                } else if dropOldestConversationTurn(in: &items) {
                    dropped += 1
                } else {
                    break
                }
                reRender()
            }
        }

        return PreparedHistory(
            prompt: prompt,
            estimatedPromptTokens: estimate,
            compactedAssistantMessages: compacted,
            droppedConversationTurns: dropped,
            summarizedSpans: summarizedSpans,
            // 换模型的记号只有在真因为它压了东西时才写。换个模型什么都没发生,不该留痕。
            migrationNotes: migrated ? [Self.modelSwitchNote] : [],
            exceedsBudget: budget.map { estimate > $0 } ?? false,
            providerId: profile.providerId,
            requestedModelId: profile.modelId,
            contextWindow: profile.contextWindow,
            reservedOutputTokens: reservedOutputTokens
        )
    }
}

private extension ConversationHistoryPlanner {
    struct AssistantItem {
        var exact: [AgentTranscript.Message]
        var compact: [AgentTranscript.Message]
        var isCompacted = false
        /// 换模型之后,这一轮是"该先压的"。不代表一定会被压。
        var isMigrationCandidate = false

        var active: [AgentTranscript.Message] { isCompacted ? compact : exact }
        var canCompact: Bool { !isCompacted && !compact.isEmpty && compact != exact }
    }

    enum HistoryItem {
        case user(String)
        case assistant(AssistantItem)
        /// 一整段的摘要。已经是最紧的形态,不能再压。
        case summary(AgentTranscript.Message)

        var isMigrationCandidate: Bool {
            if case .assistant(let item) = self { return item.isMigrationCandidate }
            return false
        }
    }

    func absorbedMessageIDs(in history: [AgentChatMessageDTO]) -> Set<UUID> {
        var absorbed: Set<UUID> = []
        for message in history {
            guard let artifact = message.storedTurn.compaction,
                  artifact.sourceMessageIDs.count > 1 else {
                continue
            }
            absorbed.formUnion(artifact.sourceMessageIDs.filter { $0 != message.id })
        }
        return absorbed
    }

    func historyItems(from history: [AgentChatMessageDTO]) -> [HistoryItem] {
        let absorbed = absorbedMessageIDs(in: history)
        var items: [HistoryItem] = []

        for message in history {
            // 已经被某段摘要吸收掉了,不再单独出现。
            if absorbed.contains(message.id) { continue }

            if let artifact = message.storedTurn.compaction, artifact.sourceMessageIDs.count > 1 {
                items.append(.summary(artifact.replaySummary))
                continue
            }

            switch message.role {
            case .user:
                guard !message.text.isEmpty, !message.textIsPlaceholder else { continue }
                items.append(.user(message.text))

            case .assistant:
                guard message.hasReplayableContent else { continue }
                let exact = message.exactReplayMessages.isEmpty
                    ? message.reconstructedReplayMessages
                    : message.exactReplayMessages
                let compact = message.compactReplayMessages(using: compactor)
                guard !exact.isEmpty || !compact.isEmpty else { continue }
                items.append(.assistant(AssistantItem(
                    exact: exact.isEmpty ? compact : exact,
                    compact: compact,
                    isMigrationCandidate: shouldPreferCompactionAfterModelSwitch(message)
                )))
            }
        }
        return items
    }

    func render(items: [HistoryItem], runtimeTranscript: AgentTranscript) -> AgentTranscript {
        var messages: [AgentTranscript.Message] = [.system(systemInstruction)]
        for item in items {
            switch item {
            case .user(let text):
                messages.append(.user(text))
            case .assistant(let assistant):
                messages.append(contentsOf: assistant.active)
            case .summary(let summary):
                messages.append(summary)
            }
        }
        messages.append(contentsOf: runtimeTranscript.messages)
        return AgentTranscript(messages: messages)
    }

    /// 最近 `preservedRecentTurns` 轮从哪儿开始。它之后的东西在第一档里碰不得。
    func firstProtectedItemIndex(in items: [HistoryItem]) -> Int {
        var userIndices: [Int] = []
        for (index, item) in items.enumerated() {
            if case .user = item { userIndices.append(index) }
        }
        guard userIndices.count > policy.preservedRecentTurns else { return 0 }
        return userIndices[userIndices.count - policy.preservedRecentTurns]
    }

    /// 同样的边界,但按原始消息数组算——给 `summarizationPlan` 切段用。
    func firstUnprotectedBoundary(in messages: [AgentChatMessageDTO]) -> Int {
        var userIndices: [Int] = []
        for (index, message) in messages.enumerated() where message.role == .user {
            userIndices.append(index)
        }
        guard userIndices.count > policy.preservedRecentTurns else { return 0 }
        return userIndices[userIndices.count - policy.preservedRecentTurns]
    }

    /// 压一条。换模型的候选排在前面——它们本来就是从别的窗口带过来的。
    func compactOldestAssistant(
        in items: inout [HistoryItem],
        before limit: Int,
        migratedOut: inout Bool
    ) -> Bool {
        let range = 0..<min(limit, items.count)

        func compact(preferMigrated: Bool) -> Bool {
            for index in range {
                guard case .assistant(var item) = items[index],
                      item.canCompact,
                      item.isMigrationCandidate == preferMigrated else {
                    continue
                }
                item.isCompacted = true
                items[index] = .assistant(item)
                if preferMigrated { migratedOut = true }
                return true
            }
            return false
        }

        return compact(preferMigrated: true) || compact(preferMigrated: false)
    }

    func dropOldestConversationTurn(in items: inout [HistoryItem]) -> Bool {
        let userCount = items.reduce(into: 0) { count, item in
            if case .user = item { count += 1 }
        }
        // 最后一轮是用户刚问的那句,丢了就没得答了。
        guard userCount > 1 else { return false }

        var end = 1
        while end < items.count {
            if case .user = items[end] { break }
            end += 1
        }
        items.removeSubrange(0..<end)
        return true
    }

    func shouldPreferCompactionAfterModelSwitch(_ message: AgentChatMessageDTO) -> Bool {
        guard migrationPolicy != .never else { return false }
        guard let context = message.storedTurn.context else { return false }
        guard !context.matches(profile) else { return false }
        guard migrationPolicy != .always else { return true }

        guard let currentWindow = profile.contextWindow else { return true }
        guard let priorWindow = context.contextWindow else { return true }
        return priorWindow > currentWindow
    }
}
