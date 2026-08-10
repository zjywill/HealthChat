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
    /// provider 已经报过一次上下文超限。水位线降到 `thresholdAfterOverflow`,压得更早更狠。
    public var isRecoveringFromOverflow: Bool
    /// 只估消息、不带工具面的估算器。
    ///
    /// 逐条计价时用它:工具 schema 是每次请求算一遍的常量,让它跟着每一条重新序列化一遍
    /// 是纯浪费——实测占掉规划耗时的三成。给 nil 就退回 `estimateTokens` 再自己扣常量。
    public var estimateMessageTokens: (@Sendable (AgentTranscript) -> Int)?
    public var estimateTokens: @Sendable (AgentTranscript) -> Int

    public init(
        systemInstruction: String,
        profile: AgentModelProfile,
        reservedOutputTokens: Int? = nil,
        compactor: TranscriptCompactor = .default,
        migrationPolicy: HistoryMigrationPolicy = .whenWindowShrinks,
        policy: ContextPolicy = .default,
        isRecoveringFromOverflow: Bool = false,
        estimateMessageTokens: (@Sendable (AgentTranscript) -> Int)? = nil,
        estimateTokens: @escaping @Sendable (AgentTranscript) -> Int
    ) {
        self.systemInstruction = systemInstruction
        self.profile = profile
        self.reservedOutputTokens = reservedOutputTokens
        self.compactor = compactor
        self.migrationPolicy = migrationPolicy
        self.policy = policy
        self.isRecoveringFromOverflow = isRecoveringFromOverflow
        self.estimateMessageTokens = estimateMessageTokens
        self.estimateTokens = estimateTokens
    }

    /// 发得出去的那份预算(窗口减掉留给输出的部分)。
    public var budget: Int? {
        profile.contextWindow.map { max(0, $0 - (reservedOutputTokens ?? 0)) }
    }

    /// 开始压缩的水位。没超之前就动手,别等撞墙。
    public func softBudget(modelSwitched: Bool) -> Int? {
        budget.map { budget in
            var ratio = modelSwitched ? policy.thresholdAfterModelSwitch : policy.compactionThreshold
            if isRecoveringFromOverflow {
                ratio = min(ratio, policy.thresholdAfterOverflow)
            }
            return Int((Double(budget) * min(max(ratio, 0.1), 1)).rounded())
        }
    }

    /// 这一轮要不要叫模型写一份整段摘要;要的话总结哪一段。
    ///
    /// 只有跨过水位线才返回非 nil——总结是一次真实的模型调用,不该每轮都花。`force` 是
    /// 溢出恢复用的:provider 已经拒收了,水位线怎么算都不重要了。
    public func summarizationPlan(
        history: [AgentChatMessageDTO],
        runtimeTranscript: AgentTranscript = .init(),
        force: Bool = false
    ) -> SummarizationPlan? {
        let items = historyItems(from: history)
        guard let soft = softBudget(modelSwitched: items.contains(where: \.isMigrationCandidate)) else {
            return nil
        }
        if !force {
            guard estimateTokens(render(items: items, runtimeTranscript: runtimeTranscript)) > soft else {
                return nil
            }
        }

        let absorbed = absorbedMessageIDs(in: history)
        let visible = history.filter { !absorbed.contains($0.id) }
        let cut = firstUnprotectedBoundary(in: visible)
        let span = Array(visible[..<cut]).filter { $0.hasReplayableContent || $0.role == .user }
        guard let owner = span.last else { return nil }

        // 已经被吸收进来的那些也要记在账上,否则下次压缩会以为它们还原样躺着。
        var sourceIDs = span.map(\.id)
        for message in span {
            if let existing = message.storedTurn.compaction, existing.sourceMessageIDs.count > 1 {
                sourceIDs.append(contentsOf: existing.sourceMessageIDs)
            }
        }

        // 上一版摘要单独拎出来,不混进要压的原文里——它是"已知",新对话才是"待并入"。
        var previousSummary: String?
        let spanTranscript = AgentTranscript(messages: span.flatMap { message -> [AgentTranscript.Message] in
            switch message.role {
            case .user:
                return message.textIsPlaceholder ? [] : [.user(message.text)]
            case .assistant:
                if let artifact = message.storedTurn.compaction, artifact.sourceMessageIDs.count > 1 {
                    previousSummary = artifact.replaySummary.text
                    return []
                }
                return message.exactReplayMessages.isEmpty
                    ? message.reconstructedReplayMessages
                    : message.exactReplayMessages
            }
        })
        guard !spanTranscript.messages.isEmpty else { return nil }
        // 「太短不值得单独花一次调用」的前提是这次调用可省。溢出恢复时 provider 已经拒收了,
        // 省不掉;接着上一版摘要往下并也一样,两三条新消息就值得。
        guard force || previousSummary != nil || span.count >= policy.minimumSpanMessages else {
            return nil
        }

        return SummarizationPlan(
            ownerMessageID: owner.id,
            sourceMessageIDs: Array(Set(sourceIDs)).sorted { $0.uuidString < $1.uuidString },
            spanText: spanTranscript.plainTextRendering(),
            messageCount: span.count,
            previousSummary: previousSummary
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
        let soft = softBudget(modelSwitched: modelSwitched)

        // 绝大多数会话到这儿就结束了:估一次,发出去。下面那套按条记账是压缩才付的钱,
        // 不该让根本不用压的会话替它买单。
        if soft.map({ estimate > $0 }) == true || budget.map({ estimate > $0 }) == true {
            // 挑压谁靠成本模型,不靠反复全量重估。
            //
            // 每压一条就把整份 transcript 重新估一遍是 O(n²):长会话实测能到七百毫秒,而且
            // 每个工具轮都要重来一遍。模型只在被改动的那一条上重估,搜索退回 O(n)。
            var cost = CostModel(items: items, runtimeTranscript: runtimeTranscript, planner: self)

            // 第一档:没超预算但过了水位线,先压远处的,最近几轮不动。
            if let soft {
                let protectedFrom = firstProtectedItemIndex(in: items)
                while cost.total > soft,
                      compactOldestAssistant(
                          in: &items,
                          before: protectedFrom,
                          migratedOut: &migrated,
                          cost: &cost
                      ) {
                    compacted += 1
                }
            }

            // 第二档:真超了,最近几轮也保不住;还不够就丢最老的一轮。
            if let budget {
                while cost.total > budget {
                    if compactOldestAssistant(
                        in: &items,
                        before: items.count,
                        migratedOut: &migrated,
                        cost: &cost
                    ) {
                        compacted += 1
                    } else if dropOldestConversationTurn(in: &items, cost: &cost) {
                        dropped += 1
                    } else {
                        break
                    }
                }
            }

            // 发出去的那个数必须是估算器自己算的整份 prompt。成本模型是用来**搜索**的,
            // 它假设估算是可加的;真到了要报给上层的数字上,不拿假设当结论。
            prompt = render(items: items, runtimeTranscript: runtimeTranscript)
            estimate = estimateTokens(prompt)

            // 假设不成立时(某个 provider 的估算不可加)模型会偏。偏了就退回逐条重估——
            // 该压的这时候基本已经压完了,循环不会跑几次。
            if let budget, estimate > budget {
                while estimate > budget {
                    if compactOldestAssistant(
                        in: &items,
                        before: items.count,
                        migratedOut: &migrated,
                        cost: &cost
                    ) {
                        compacted += 1
                    } else if dropOldestConversationTurn(in: &items, cost: &cost) {
                        dropped += 1
                    } else {
                        break
                    }
                    prompt = render(items: items, runtimeTranscript: runtimeTranscript)
                    estimate = estimateTokens(prompt)
                }
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
        /// 用户说的一句话,外加随它发出去的图片或文档。
        ///
        /// 图不单独成为一条 `HistoryItem`:它和那句话是同一次发言,压缩时也必须一起走——
        /// 分开的话会出现「图还在、说明它的那句话已经被压成一句摘要」,而模型手上就剩一张
        /// 没有来历的图。
        case user(text: String, files: [AgentTranscript.FilePart] = [])
        case assistant(AssistantItem)
        /// 一整段的摘要。已经是最紧的形态,不能再压。
        case summary(AgentTranscript.Message)

        var isMigrationCandidate: Bool {
            if case .assistant(let item) = self { return item.isMigrationCandidate }
            return false
        }

        /// 这一条当前形态下真正会发出去的消息。
        var messages: [AgentTranscript.Message] {
            switch self {
            case .user(let text, let files):
                guard !files.isEmpty else { return [.user(text)] }
                // 文字排在前面:那句话里写着「原图附在下面」和它是第几张,先读到它,
                // 模型才知道后面这几张图是谁。
                return [.init(role: .user, parts: [.text(text)] + files.map(AgentTranscript.Part.file))]
            case .assistant(let assistant): return assistant.active
            case .summary(let summary): return [summary]
            }
        }
    }

    /// 按条记账的预算模型。
    ///
    /// 搜索「压哪几条才够」时不需要每步都把整份 transcript 交给估算器重算一遍:除了被改动的
    /// 那一条,别的都没变。这里假设估算是可加的——同一个估算器对 [A, B] 的结果等于对 [A]
    /// 加对 [B]。工具 schema 那部分是每次请求算一遍的常量,所以先单独量出来再从每条里扣掉,
    /// 否则每条都会把整个工具面重复计一次。
    ///
    /// 这个假设只用来**挑**,不用来**报**:最终的数字仍然是估算器对整份 prompt 的结果。
    struct CostModel {
        /// 系统提示、工具面、这一轮已经跑出来的 transcript——都不受压缩影响。
        private let baseline: Int
        private let overhead: Int
        private var itemCosts: [Int]
        private let measure: @Sendable ([AgentTranscript.Message]) -> Int

        var total: Int { baseline + itemCosts.reduce(0, +) }

        init(
            items: [HistoryItem],
            runtimeTranscript: AgentTranscript,
            planner: ConversationHistoryPlanner
        ) {
            let estimate = planner.estimateTokens
            // 空 transcript 的开销 = 工具面,压缩动不了它。
            let toolSurface = estimate(AgentTranscript(messages: []))
            let measure: @Sendable ([AgentTranscript.Message]) -> Int
            if let lean = planner.estimateMessageTokens {
                measure = { $0.isEmpty ? 0 : lean(AgentTranscript(messages: $0)) }
            } else {
                // 没有专门的消息估算器,就用整份的那个再把常量扣掉。
                measure = { $0.isEmpty ? 0 : estimate(AgentTranscript(messages: $0)) - toolSurface }
            }

            overhead = toolSurface
            self.measure = measure
            baseline = toolSurface
                + measure([.system(planner.systemInstruction)] + runtimeTranscript.messages)
            itemCosts = items.map { measure($0.messages) }
        }

        mutating func refresh(_ index: Int, with item: HistoryItem) {
            guard itemCosts.indices.contains(index) else { return }
            itemCosts[index] = measure(item.messages)
        }

        mutating func removeSubrange(_ range: Range<Int>) {
            let clamped = range.clamped(to: itemCosts.indices.lowerBound..<itemCosts.count)
            guard !clamped.isEmpty else { return }
            itemCosts.removeSubrange(clamped)
        }
    }

    func absorbedMessageIDs(in history: [AgentChatMessageDTO]) -> Set<UUID> {
        var absorbed: Set<UUID> = []
        for message in history {
            // 在工具轮边界并进那一轮的插话。列表里还留着一条(界面要显示),但 transcript
            // 中间已经有了。
            //
            // 要先确认 transcript 真的存下来了:那一轮被停掉或者失败时它是空的,回放走的是
            // `reconstructedReplayMessages`——那份是从 app 侧的工具记录重建的,里面没有插话。
            // 这时候还跳过,用户补的那句就凭空消失了。
            if !message.storedTurn.exactTranscript.messages.isEmpty {
                absorbed.formUnion(message.storedTurn.inlinedMessageIDs)
            }
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
                items.append(.user(text: message.text, files: message.files))

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
            messages.append(contentsOf: item.messages)
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
        migratedOut: inout Bool,
        cost: inout CostModel
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
                cost.refresh(index, with: items[index])
                if preferMigrated { migratedOut = true }
                return true
            }
            return false
        }

        return compact(preferMigrated: true) || compact(preferMigrated: false)
    }

    func dropOldestConversationTurn(in items: inout [HistoryItem], cost: inout CostModel) -> Bool {
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
        cost.removeSubrange(0..<end)
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
