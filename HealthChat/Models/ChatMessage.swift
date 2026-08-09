import Foundation
import AgentRuntime
import AIKit

typealias TurnContextSnapshot = TurnContextSnapshotDTO
typealias TurnState = StoredAgentTurn.State

/// 一次工具调用的完整记录:调用本身和它的结果。
///
/// 聊天气泡和详情面板都认这层 app 自己的结构;真正回放给模型的 transcript 存在
/// `ChatMessage.storedTurn` 里,会话文件里没有任何 AIKit 类型。
struct ToolCallRecord: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let name: String
    let input: String
    var output: String?
    var report: HealthReport?
    var isError: Bool

    init(
        id: String,
        name: String,
        input: String,
        output: String? = nil,
        report: HealthReport? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.report = report
        self.isError = isError
    }

    /// 同 `ChatMessage.rendersIdentically`。`report` 只比行数:它和 `output` 是
    /// `finishToolCall` 里一次写进去的,`output` 变了这条自然就不等了,而逐小时序列
    /// 逐点比一遍是这里唯一真正贵的操作。
    func rendersIdentically(to other: ToolCallRecord) -> Bool {
        id == other.id
            && name == other.name
            && isError == other.isError
            && output == other.output
            && report?.rows.count == other.report?.rows.count
    }
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    /// `text` 是 app 写给用户的占位("已停止回复"/"无法回复：…"),不是模型说的话。
    ///
    /// 有这个标记,runtime 判断该不该回放时就不用去比对某句中文——那句话属于 app。
    var textIsPlaceholder: Bool
    /// 模型这一轮的思考,几段拼在一起。没有思考(或者模型不吐思考)时是空串。
    ///
    /// 存盘:重开一条老会话时思考还在,和刚聊完时看到的是同一屏。它和
    /// `storedTurn.exactTranscript` 里的 `.reasoning` 是同一段话的两种形态——那份带
    /// provider metadata,要原样发回给模型;这份是纯文本,只给人看。
    var reasoning: String
    var toolCalls: [ToolCallRecord]
    var storedTurn: StoredAgentTurn
    var errorDescription: String?
    /// 这条消息是什么时候产生的。
    ///
    /// 可空:这个字段是后加的,之前存下来的会话里没有——与其编一个时间,不如在菜单里
    /// 不显示。
    var createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case textIsPlaceholder
        case reasoning
        case toolCalls
        case storedTurn
        case errorDescription
        case createdAt

        // 旧会话格式:transcript 曾经直接落的是 AIKit 的 Message。
        case replayMessages
        case finishReason
        case usage
        case context
        case turnState
    }

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        textIsPlaceholder: Bool = false,
        reasoning: String = "",
        toolCalls: [ToolCallRecord] = [],
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

    init(_ dto: AgentChatMessageDTO) {
        id = dto.id
        role = Role(dto.role)
        text = dto.text
        textIsPlaceholder = dto.textIsPlaceholder
        reasoning = dto.reasoning
        toolCalls = dto.toolCalls.map(ToolCallRecord.init)
        storedTurn = dto.storedTurn
        errorDescription = dto.errorDescription
        createdAt = dto.createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        textIsPlaceholder = try container.decodeIfPresent(Bool.self, forKey: .textIsPlaceholder) ?? false
        reasoning = try container.decodeIfPresent(String.self, forKey: .reasoning) ?? ""
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)

        // 要问 `contains`,不能用 `try? decodeIfPresent`:键不存在时后者是"成功地解出了 nil",
        // 一样会走进这个分支,底下的旧格式就永远读不到了。
        if container.contains(.storedTurn) {
            self.storedTurn = (try? container.decode(StoredAgentTurn.self, forKey: .storedTurn)) ?? .init()
            return
        }

        // 旧格式:把 AIKit 的消息翻成 app 自己的 transcript,之后就再也不碰 AIKit 类型了。
        let replayMessages = ((try? container.decodeIfPresent([AIKit.Message].self, forKey: .replayMessages)) ?? [])
            .map(\.agentTranscriptMessage)
        let finishReason = (try? container.decodeIfPresent(FinishReason.self, forKey: .finishReason)) ?? nil
        let usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
        let context = (try? container.decodeIfPresent(TurnContextSnapshot.self, forKey: .context)) ?? nil
        let turnState = (try? container.decodeIfPresent(TurnState.self, forKey: .turnState)) ?? nil

        self.storedTurn = .init(
            exactTranscript: .init(messages: replayMessages),
            finishReason: finishReason?.agentFinishReason,
            usage: usage?.agentUsage,
            state: turnState,
            context: context
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(textIsPlaceholder, forKey: .textIsPlaceholder)
        if !reasoning.isEmpty {
            try container.encode(reasoning, forKey: .reasoning)
        }
        try container.encode(toolCalls, forKey: .toolCalls)
        try container.encode(normalizedStoredTurn, forKey: .storedTurn)
        try container.encodeIfPresent(errorDescription, forKey: .errorDescription)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

extension ChatMessage {
    var turnState: TurnState? {
        get { storedTurn.state }
        set { storedTurn.state = newValue }
    }

    var finishReason: AgentFinishReason? { storedTurn.finishReason }
    var usage: AgentUsage? { storedTurn.usage }
    var context: TurnContextSnapshot? { storedTurn.context }

    /// 这条消息的结尾处折叠掉了它上面的一整段。
    ///
    /// 只认跨多条的 artifact:单条那种是发请求时按预算临时决定的,下一轮可能就不压了,
    /// 不该在界面上留痕。整段摘要是实打实存下来的,回不去了,得让用户看见。
    var foldedSpan: CompactionArtifact? {
        guard let compaction = storedTurn.compaction,
              compaction.sourceMessageIDs.count > 1 else {
            return nil
        }
        return compaction
    }

    /// 这一轮是被单轮查询次数上限截住的。
    ///
    /// 不是失败:已经查到的东西都在,只是模型还想接着查。用户需要知道这件事——不然它
    /// 看起来就是说到一半自己停了。
    var stoppedAtToolRoundLimit: Bool {
        storedTurn.finishReason?.raw == AgentLoop.toolRoundLimitReason
    }

    /// 这两条画在屏幕上会不会有区别。
    ///
    /// 给气泡判等用(`MessageBubble.==`),不是给业务逻辑用。合成的 `==` 会把 `storedTurn`
    /// 一起深比较——整份工具原文加每份 `HealthReport` 的逐小时序列,而这些界面上一个字都
    /// 不显示。流式一秒几十帧,每帧比一遍是这一屏最贵的一次白干。
    ///
    /// 加字段时记得跟上:这里漏一个,界面上就是那个字段改了不刷新。
    func rendersIdentically(to other: ChatMessage) -> Bool {
        id == other.id
            && text == other.text
            && reasoning == other.reasoning
            && errorDescription == other.errorDescription
            && createdAt == other.createdAt
            && stoppedAtToolRoundLimit == other.stoppedAtToolRoundLimit
            && toolCalls.count == other.toolCalls.count
            && zip(toolCalls, other.toolCalls).allSatisfy { $0.rendersIdentically(to: $1) }
    }

    /// 交给 runtime 的形态。落盘和回放走的是同一份,不会出现"存的和发的不一样"。
    var agentDTO: AgentChatMessageDTO {
        var dto = rawDTO
        dto.storedTurn = normalizedStoredTurn
        return dto
    }

    /// 不带归一化的原样转换。给 compactor 用——归一化本身要读它,不能反过来依赖归一化。
    private var rawDTO: AgentChatMessageDTO {
        AgentChatMessageDTO(
            id: id,
            role: AgentChatMessageDTO.Role(role),
            text: text,
            textIsPlaceholder: textIsPlaceholder,
            reasoning: reasoning,
            toolCalls: toolCalls.map(\.dto),
            storedTurn: storedTurn,
            errorDescription: errorDescription,
            createdAt: createdAt
        )
    }

    /// 回合一结束就把 compaction artifact 算出来存下,而不是每次要用时现推。
    ///
    /// 现推的问题是它只能拿到当时还剩下的东西;artifact 要在信息最全的时候生成。
    private var normalizedStoredTurn: StoredAgentTurn {
        guard role == .assistant, storedTurn.compaction == nil, storedTurn.state != nil else {
            return storedTurn
        }
        var normalized = storedTurn
        normalized.compaction = TranscriptCompactor.healthChat.artifact(for: rawDTO)
        return normalized
    }
}

/// 事件怎么改状态只写在 runtime 的 `AgentTurnSink.apply` 里;这里只提供存储。
extension ChatMessage: AgentTurnSink {
    mutating func appendText(_ delta: String) {
        if textIsPlaceholder {
            text = ""
            textIsPlaceholder = false
        }
        text += delta
    }

    mutating func appendReasoning(_ delta: String) {
        reasoning += delta
    }

    mutating func startToolCall(_ record: ToolCallRecordDTO) {
        toolCalls.append(ToolCallRecord(record))
    }

    mutating func finishToolCall(id: String, output: AgentToolOutput, isError: Bool) {
        guard let index = toolCalls.firstIndex(where: { $0.id == id }) else { return }
        toolCalls[index].output = output.text
        toolCalls[index].report = HealthReport.decode(fromToolMetadata: output.metadata)
        toolCalls[index].isError = isError
    }

    mutating func completeTurn(
        transcript: AgentTranscript,
        finishReason: AgentFinishReason?,
        usage: AgentUsage?,
        context: TurnContextSnapshotDTO?
    ) {
        storedTurn.exactTranscript = transcript
        storedTurn.finishReason = finishReason
        storedTurn.usage = usage
        storedTurn.context = context
        storedTurn.state = .completed
    }

    mutating func rollBackText(_ characterCount: Int) {
        guard characterCount > 0, !textIsPlaceholder else { return }
        text.removeLast(min(characterCount, text.count))
    }

    mutating func rollBackReasoning(_ characterCount: Int) {
        guard characterCount > 0 else { return }
        reasoning.removeLast(min(characterCount, reasoning.count))
    }

    mutating func markStopped() {
        if text.isEmpty {
            text = "已停止回复"
            textIsPlaceholder = true
        }
        storedTurn.state = .stopped
    }

    mutating func markFailed(_ description: String) {
        if text.isEmpty {
            text = "无法回复：\(description)"
            textIsPlaceholder = true
        }
        storedTurn.state = .failed
        errorDescription = description
    }
}

private extension ToolCallRecord {
    init(_ dto: ToolCallRecordDTO) {
        id = dto.id
        name = dto.name
        input = dto.input
        output = dto.output?.text
        report = dto.output.flatMap { HealthReport.decode(fromToolMetadata: $0.metadata) }
        isError = dto.isError
    }

    var dto: ToolCallRecordDTO {
        ToolCallRecordDTO(
            id: id,
            name: name,
            input: input,
            output: output.map {
                AgentToolOutput(
                    kind: report == nil ? .text : .table,
                    text: $0,
                    metadata: report.flatMap(HealthReport.encodeForToolMetadata)
                )
            },
            isError: isError
        )
    }
}

private extension ChatMessage.Role {
    init(_ role: AgentChatMessageDTO.Role) {
        switch role {
        case .user: self = .user
        case .assistant: self = .assistant
        }
    }
}

private extension AgentChatMessageDTO.Role {
    init(_ role: ChatMessage.Role) {
        switch role {
        case .user: self = .user
        case .assistant: self = .assistant
        }
    }
}
