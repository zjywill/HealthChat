import Foundation

/// 换模型时怎么处理已有历史。
public enum HistoryMigrationPolicy: String, Codable, Sendable {
    /// 不管窗口大小,历史照原样回放。
    case never
    /// 换到窗口更小(或大小未知)的模型时,先把老的几轮换成压缩形态再发。
    ///
    /// 不这么做的话:第一轮请求直接超窗 → provider 400 → 用户看到一句"上下文过长",
    /// 而他只是换了个模型。主动重整比事后报错好。
    case whenWindowShrinks
    /// 只要 provider 或模型变了就重整。
    case always
}

/// 把 app 的会话历史铺成一份可以直接发给模型的 transcript。
///
/// 负责三件事,顺序固定:换模型时的主动重整 → 逐条压缩 → 实在放不下才丢最老的一轮。
/// 三件事都不认识 HealthKit、也不认识 AIKit。
public struct ConversationHistoryPlanner: Sendable {
    public struct PreparedHistory: Equatable, Sendable {
        public var prompt: AgentTranscript
        public var estimatedPromptTokens: Int
        public var compactedAssistantMessages: Int
        public var droppedConversationTurns: Int
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
    public var estimateTokens: @Sendable (AgentTranscript) -> Int

    public init(
        systemInstruction: String,
        profile: AgentModelProfile,
        reservedOutputTokens: Int? = nil,
        compactor: TranscriptCompactor = .default,
        migrationPolicy: HistoryMigrationPolicy = .whenWindowShrinks,
        estimateTokens: @escaping @Sendable (AgentTranscript) -> Int
    ) {
        self.systemInstruction = systemInstruction
        self.profile = profile
        self.reservedOutputTokens = reservedOutputTokens
        self.compactor = compactor
        self.migrationPolicy = migrationPolicy
        self.estimateTokens = estimateTokens
    }

    public func prepare(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript = .init()
    ) -> PreparedHistory {
        var items = historyItems(from: history)
        let budget = profile.contextWindow.map { max(0, $0 - (reservedOutputTokens ?? 0)) }

        var compacted = items.reduce(into: 0) { count, item in
            if case .assistant(_, _, let isCompacted, _) = item, isCompacted {
                count += 1
            }
        }
        var dropped = 0
        let migrationNotes = items.contains(where: \.wasMigratedForModelSwitch)
            ? [Self.modelSwitchNote]
            : []

        var prompt = render(items: items, runtimeTranscript: runtimeTranscript)
        var estimate = estimateTokens(prompt)

        if let budget {
            while estimate > budget {
                if compactOldestAssistantMessage(in: &items) {
                    compacted += 1
                } else if dropOldestConversationTurn(in: &items) {
                    dropped += 1
                } else {
                    break
                }
                prompt = render(items: items, runtimeTranscript: runtimeTranscript)
                estimate = estimateTokens(prompt)
            }
        }

        return PreparedHistory(
            prompt: prompt,
            estimatedPromptTokens: estimate,
            compactedAssistantMessages: compacted,
            droppedConversationTurns: dropped,
            migrationNotes: migrationNotes,
            exceedsBudget: budget.map { estimate > $0 } ?? false,
            providerId: profile.providerId,
            requestedModelId: profile.modelId,
            contextWindow: profile.contextWindow,
            reservedOutputTokens: reservedOutputTokens
        )
    }
}

private extension ConversationHistoryPlanner {
    enum HistoryItem {
        case user(String)
        case assistant(
            exact: [AgentTranscript.Message],
            compact: [AgentTranscript.Message],
            isCompacted: Bool,
            migratedForModelSwitch: Bool
        )

        var wasMigratedForModelSwitch: Bool {
            if case .assistant(_, _, _, let migratedForModelSwitch) = self {
                return migratedForModelSwitch
            }
            return false
        }
    }

    func historyItems(from history: [AgentChatMessageDTO]) -> [HistoryItem] {
        history.compactMap { message in
            switch message.role {
            case .user:
                guard !message.text.isEmpty, !message.textIsPlaceholder else { return nil }
                return .user(message.text)

            case .assistant:
                guard shouldReplay(message) else { return nil }
                let exact = message.exactReplayMessages.isEmpty
                    ? message.reconstructedReplayMessages
                    : message.exactReplayMessages
                let compact = message.compactReplayMessages(using: compactor)
                guard !exact.isEmpty || !compact.isEmpty else { return nil }
                let migrate = shouldMigrateForModelSwitch(message) && !compact.isEmpty
                return .assistant(
                    exact: exact.isEmpty ? compact : exact,
                    compact: compact,
                    isCompacted: migrate,
                    migratedForModelSwitch: migrate
                )
            }
        }
    }

    func render(items: [HistoryItem], runtimeTranscript: AgentTranscript) -> AgentTranscript {
        var messages: [AgentTranscript.Message] = [.system(systemInstruction)]
        for item in items {
            switch item {
            case .user(let text):
                messages.append(.user(text))
            case .assistant(let exact, let compact, let isCompacted, _):
                messages.append(contentsOf: isCompacted ? compact : exact)
            }
        }
        messages.append(contentsOf: runtimeTranscript.messages)
        return AgentTranscript(messages: messages)
    }

    func compactOldestAssistantMessage(in items: inout [HistoryItem]) -> Bool {
        for index in items.indices {
            guard case .assistant(let exact, let compact, let isCompacted, let migrated) = items[index],
                  !isCompacted,
                  !compact.isEmpty,
                  compact != exact else {
                continue
            }
            items[index] = .assistant(
                exact: exact,
                compact: compact,
                isCompacted: true,
                migratedForModelSwitch: migrated
            )
            return true
        }
        return false
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

    /// 哪些轮次值得回放。
    ///
    /// 失败/被停的那轮里,app 写给用户的占位文本(`textIsPlaceholder`)不回放——它不是模型
    /// 说的话;但已经跑完的工具结果要留着,不然追问时又得重查一遍。
    func shouldReplay(_ message: AgentChatMessageDTO) -> Bool {
        message.hasReplayableContent
    }

    func shouldMigrateForModelSwitch(_ message: AgentChatMessageDTO) -> Bool {
        guard migrationPolicy != .never else { return false }
        guard let context = message.storedTurn.context else { return false }
        guard !context.matches(profile) else { return false }
        guard migrationPolicy != .always else { return true }

        guard let currentWindow = profile.contextWindow else { return true }
        guard let priorWindow = context.contextWindow else { return true }
        return priorWindow > currentWindow
    }
}
