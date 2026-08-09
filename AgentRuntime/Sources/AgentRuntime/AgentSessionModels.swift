import Foundation

public struct AgentUsage: Equatable, Codable, Sendable {
    public struct Input: Equatable, Codable, Sendable {
        public var total: Int?
        public var noCache: Int?
        public var cacheRead: Int?
        public var cacheWrite: Int?

        public init(total: Int? = nil, noCache: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil) {
            self.total = total
            self.noCache = noCache
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    public struct Output: Equatable, Codable, Sendable {
        public var total: Int?
        public var text: Int?
        public var reasoning: Int?

        public init(total: Int? = nil, text: Int? = nil, reasoning: Int? = nil) {
            self.total = total
            self.text = text
            self.reasoning = reasoning
        }
    }

    public var inputTokens: Input
    public var outputTokens: Output
    public var raw: RuntimeJSONValue?

    public init(
        inputTokens: Input = .init(),
        outputTokens: Output = .init(),
        raw: RuntimeJSONValue? = nil
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.raw = raw
    }
}

public struct AgentFinishReason: Equatable, Codable, Sendable {
    public enum Unified: String, Codable, Sendable {
        case stop
        case length
        case contentFilter = "content-filter"
        case toolCalls = "tool-calls"
        case error
        case other
    }

    public var unified: Unified
    public var raw: String?

    public init(unified: Unified, raw: String? = nil) {
        self.unified = unified
        self.raw = raw
    }
}

public struct AgentToolOutput: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case table
        case text
    }

    public var kind: Kind
    /// 送进模型上下文的那段文本。
    public var text: String
    /// 只给界面看的结构化负载(图表、原始行)。不进上下文。
    public var metadata: RuntimeJSONValue?

    public init(kind: Kind, text: String, metadata: RuntimeJSONValue? = nil) {
        self.kind = kind
        self.text = text
        self.metadata = metadata
    }

    /// 截到 `maxCharacters` 以内。
    ///
    /// 这是上下文预算的**源头闸门**:一次工具调用返回几万字符,后面所有的压缩都只是在
    /// 亡羊补牢——那一轮的原始输出在被压之前必须先原样发出去一次。截断放在 loop 里而不是
    /// 每个能力里,是因为能力是可以随便加的,防线不能指望每个作者都记得。
    ///
    /// 只截 `text`(进模型的那份),`metadata` 原样留着——图表和原始行只给界面看,不占预算。
    func limited(to maxCharacters: Int, notice: String) -> AgentToolOutput {
        guard maxCharacters > 0, text.count > maxCharacters else { return self }

        // 按行切。半行数字比没有数字更危险:模型会把 "08-0" 当成一个日期读下去。
        var kept = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard kept.count + line.count + 1 <= maxCharacters else { break }
            if !kept.isEmpty { kept += "\n" }
            kept += line
        }
        if kept.isEmpty {
            kept = String(text.prefix(maxCharacters))
        }

        var limited = self
        limited.text = kept + "\n" + String(format: notice, text.count - kept.count, text.count)
        return limited
    }
}

public struct ToolCallRecordDTO: Identifiable, Equatable, Codable, Sendable {
    public var id: String
    public var name: String
    public var input: String
    public var output: AgentToolOutput?
    public var isError: Bool

    public init(
        id: String,
        name: String,
        input: String,
        output: AgentToolOutput? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.isError = isError
    }
}

/// 一轮被压缩后留下的东西。
///
/// 显式区分两个读者:`visibleSummary` 给用户,`replaySummary` 给模型。生成方式见
/// `TranscriptCompactor`。
public struct CompactionArtifact: Equatable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// 只留可见回答——这轮没跑工具。
        case answerOnly
        /// 可见回答 + 工具轨迹摘要。
        case toolDigest
        /// 模型自己写的 summary(还没接,占位:接上以后 artifact 的形状不用变)。
        case modelGenerated
    }

    public var kind: Kind
    public var visibleSummary: String
    public var replaySummary: AgentTranscript.Message
    public var sourceMessageIDs: [UUID]
    public var foldedToolCalls: Int
    public var createdAt: Date

    public init(
        kind: Kind = .answerOnly,
        visibleSummary: String,
        replaySummary: AgentTranscript.Message,
        sourceMessageIDs: [UUID],
        foldedToolCalls: Int = 0,
        createdAt: Date = Date()
    ) {
        self.kind = kind
        self.visibleSummary = visibleSummary
        self.replaySummary = replaySummary
        self.sourceMessageIDs = sourceMessageIDs
        self.foldedToolCalls = foldedToolCalls
        self.createdAt = createdAt
    }

    // kind / foldedToolCalls 是后加的:老会话里没有,缺了就按最保守的形态算。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .answerOnly
        visibleSummary = try container.decode(String.self, forKey: .visibleSummary)
        replaySummary = try container.decode(AgentTranscript.Message.self, forKey: .replaySummary)
        sourceMessageIDs = try container.decodeIfPresent([UUID].self, forKey: .sourceMessageIDs) ?? []
        foldedToolCalls = try container.decodeIfPresent(Int.self, forKey: .foldedToolCalls) ?? 0
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// 没有工具轨迹时的最简形态。
    public static func answerOnly(_ summary: String, sourceMessageIDs: [UUID]) -> Self {
        .init(
            kind: .answerOnly,
            visibleSummary: summary,
            replaySummary: .assistantSummary(summary, sourceIDs: sourceMessageIDs),
            sourceMessageIDs: sourceMessageIDs
        )
    }
}

public struct TurnContextSnapshotDTO: Equatable, Codable, Sendable {
    public var providerId: String
    public var requestedModelId: String
    public var servedModelId: String?
    public var contextWindow: Int?
    public var reservedOutputTokens: Int?
    public var estimatedPromptTokens: Int?
    public var actualPromptTokens: Int?
    public var compactedAssistantMessages: Int
    public var droppedConversationTurns: Int
    /// 这一轮的 prompt 里有几段是整段摘要(而不是原样回放)。
    public var summarizedSpans: Int
    public var migrationNotes: [String]

    public init(
        providerId: String,
        requestedModelId: String,
        servedModelId: String? = nil,
        contextWindow: Int? = nil,
        reservedOutputTokens: Int? = nil,
        estimatedPromptTokens: Int? = nil,
        actualPromptTokens: Int? = nil,
        compactedAssistantMessages: Int = 0,
        droppedConversationTurns: Int = 0,
        summarizedSpans: Int = 0,
        migrationNotes: [String] = []
    ) {
        self.providerId = providerId
        self.requestedModelId = requestedModelId
        self.servedModelId = servedModelId
        self.contextWindow = contextWindow
        self.reservedOutputTokens = reservedOutputTokens
        self.estimatedPromptTokens = estimatedPromptTokens
        self.actualPromptTokens = actualPromptTokens
        self.compactedAssistantMessages = compactedAssistantMessages
        self.droppedConversationTurns = droppedConversationTurns
        self.summarizedSpans = summarizedSpans
        self.migrationNotes = migrationNotes
    }

    // summarizedSpans 是后加的:老会话的快照里没有。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        providerId = try container.decode(String.self, forKey: .providerId)
        requestedModelId = try container.decode(String.self, forKey: .requestedModelId)
        servedModelId = try container.decodeIfPresent(String.self, forKey: .servedModelId)
        contextWindow = try container.decodeIfPresent(Int.self, forKey: .contextWindow)
        reservedOutputTokens = try container.decodeIfPresent(Int.self, forKey: .reservedOutputTokens)
        estimatedPromptTokens = try container.decodeIfPresent(Int.self, forKey: .estimatedPromptTokens)
        actualPromptTokens = try container.decodeIfPresent(Int.self, forKey: .actualPromptTokens)
        compactedAssistantMessages = try container.decodeIfPresent(Int.self, forKey: .compactedAssistantMessages) ?? 0
        droppedConversationTurns = try container.decodeIfPresent(Int.self, forKey: .droppedConversationTurns) ?? 0
        summarizedSpans = try container.decodeIfPresent(Int.self, forKey: .summarizedSpans) ?? 0
        migrationNotes = try container.decodeIfPresent([String].self, forKey: .migrationNotes) ?? []
    }

    public func matches(providerId: String, requestedModelId: String) -> Bool {
        guard self.providerId == providerId else { return false }
        let effectiveModelId = servedModelId ?? self.requestedModelId
        return effectiveModelId == requestedModelId
    }

    public func matches(_ profile: AgentModelProfile) -> Bool {
        matches(providerId: profile.providerId, requestedModelId: profile.modelId)
    }
}

public struct StoredAgentTurn: Equatable, Codable, Sendable {
    public enum State: String, Codable, Sendable {
        case completed
        case stopped
        case failed
    }

    /// 这轮真正发生的一切,原样存着——回放的首选。
    public var exactTranscript: AgentTranscript
    /// 上下文不够时用它顶替 `exactTranscript`。
    public var compaction: CompactionArtifact?
    public var finishReason: AgentFinishReason?
    public var usage: AgentUsage?
    public var state: State?
    public var context: TurnContextSnapshotDTO?

    public init(
        exactTranscript: AgentTranscript = .init(),
        compaction: CompactionArtifact? = nil,
        finishReason: AgentFinishReason? = nil,
        usage: AgentUsage? = nil,
        state: State? = nil,
        context: TurnContextSnapshotDTO? = nil
    ) {
        self.exactTranscript = exactTranscript
        self.compaction = compaction
        self.finishReason = finishReason
        self.usage = usage
        self.state = state
        self.context = context
    }
}

public struct AgentChatMessageDTO: Identifiable, Equatable, Codable, Sendable {
    public enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    public var id: UUID
    public var role: Role
    public var text: String
    /// `text` 是 app 写给用户的占位("已停止回复"之类),不是模型说的话。
    ///
    /// 有这个标记,runtime 就不用靠比对某句中文来判断该不该回放——那句话属于 app,
    /// 不属于通用 core。
    public var textIsPlaceholder: Bool
    /// 模型这一轮的思考,几段拼在一起。
    ///
    /// 只给界面看。回放给模型的那一份在 `storedTurn.exactTranscript` 的 `.reasoning` 里,
    /// 两份不能互相顶替:transcript 那份要带 provider metadata 原样发回去,这份是纯文本。
    public var reasoning: String
    public var toolCalls: [ToolCallRecordDTO]
    public var storedTurn: StoredAgentTurn
    public var errorDescription: String?
    public var createdAt: Date?

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        textIsPlaceholder: Bool = false,
        reasoning: String = "",
        toolCalls: [ToolCallRecordDTO] = [],
        storedTurn: StoredAgentTurn = .init(),
        errorDescription: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.textIsPlaceholder = textIsPlaceholder
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.storedTurn = storedTurn
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }
}

public extension AgentChatMessageDTO {
    var exactReplayMessages: [AgentTranscript.Message] {
        storedTurn.exactTranscript.messages
    }

    /// 没有 exact transcript 时(老会话、或工具跑完就被停掉的那轮)从 app 侧记录重建。
    var reconstructedReplayMessages: [AgentTranscript.Message] {
        let completed = toolCalls.compactMap { call -> (ToolCallRecordDTO, AgentToolOutput)? in
            guard let output = call.output else { return nil }
            return (call, output)
        }
        var messages: [AgentTranscript.Message] = []
        var parts: [AgentTranscript.Part] = []
        if !text.isEmpty, !textIsPlaceholder {
            parts.append(.text(text))
        }
        parts.append(contentsOf: completed.map { pair in
            .toolCall(.init(
                toolCallId: pair.0.id,
                toolName: pair.0.name,
                input: pair.0.input
            ))
        })
        if !parts.isEmpty {
            messages.append(.init(role: .assistant, parts: parts))
        }
        messages.append(contentsOf: completed.map { pair in
            .toolResult(
                toolCallId: pair.0.id,
                toolName: pair.0.name,
                result: .string(pair.1.text),
                isError: pair.0.isError
            )
        })
        return messages
    }

    /// 压缩形态。存了 artifact 就用存的,没存就现算一个。
    func compactReplayMessages(using compactor: TranscriptCompactor = .default) -> [AgentTranscript.Message] {
        if let compaction = storedTurn.compaction {
            return [compaction.replaySummary]
        }
        guard let artifact = compactor.artifact(for: self) else { return [] }
        return [artifact.replaySummary]
    }

    var hasReplayableContent: Bool {
        !exactReplayMessages.isEmpty || !reconstructedReplayMessages.isEmpty
    }
}

public extension AgentTranscript.Message {
    /// 摘要消息带上它是从哪几条压出来的,方便以后回溯或者再压一层。
    static func assistantSummary(_ text: String, sourceIDs: [UUID]) -> Self {
        .init(
            role: .assistant,
            parts: [.text(text)],
            metadata: [
                "agent-runtime": [
                    "compaction_sources": .array(sourceIDs.map { .string($0.uuidString) })
                ]
            ]
        )
    }

    var compactionSourceIDs: [UUID] {
        metadata["agent-runtime"]?["compaction_sources"]?
            .arrayValue?
            .compactMap { $0.stringValue.flatMap(UUID.init(uuidString:)) } ?? []
    }
}
