import Foundation
import AIKit

/// 一次工具调用的完整记录:调用本身和它的结果。
///
/// 存进消息里而不是只留一句"查询了最近 7 天睡眠",是因为下一轮要把它原样回放给
/// 模型——只回放文本的话,模型看不到自己上轮查到过什么,只能重查或者顺着总结瞎编。
struct ToolCallRecord: Identifiable, Equatable, Codable, Sendable {
    /// provider 给的 toolCallId,回放时要原样带回去。
    let id: String
    let name: String
    /// 参数的 JSON 字符串,保留原样(重新编码一遍不会得到相同的字节)。
    let input: String
    /// nil 表示还在跑。回放给模型的就是这段文本。
    var output: String?
    /// 同一次查询的结构化形式,面板拿它画表格。查询失败、或者是旧版本存下来的
    /// 会话,这里是 nil——面板那时退回显示 `output`。
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
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    enum TurnState: String, Codable, Sendable {
        case completed
        case stopped
        case failed
    }

    let id: UUID
    let role: Role
    var text: String
    var toolCalls: [ToolCallRecord]
    /// 这一轮里模型实际看到/说出的完整消息序列,按顺序保存:
    /// assistant -> tool result -> assistant ...
    ///
    /// UI 仍然把它们压成一个气泡展示,但多轮回放必须保留原顺序,否则工具调用轮次一多,
    /// prompt 很快就和真实对话漂移。
    var replayMessages: [Message]
    var finishReason: FinishReason?
    var usage: Usage?
    var turnState: TurnState?
    /// 这一轮请求所处的预算环境。它是 app 自己的结构,不是 provider transcript 的一部分:
    /// 下一次如果要按当前模型窗口压缩历史,靠它判断"这条 usage 能不能拿来校准"。
    var context: TurnContextSnapshot?
    var errorDescription: String?
    /// 这条消息是什么时候产生的。
    ///
    /// 可空:这个字段是后加的,之前存下来的会话里没有——与其编一个时间,不如在菜单里
    /// 不显示。
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolCalls: [ToolCallRecord] = [],
        replayMessages: [Message] = [],
        finishReason: FinishReason? = nil,
        usage: Usage? = nil,
        turnState: TurnState? = nil,
        context: TurnContextSnapshot? = nil,
        errorDescription: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.replayMessages = replayMessages
        self.finishReason = finishReason
        self.usage = usage
        self.turnState = turnState
        self.context = context
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case text
        case toolCalls
        case replayMessages
        case finishReason
        case usage
        case turnState
        case context
        case errorDescription
        case createdAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(Role.self, forKey: .role)
        text = try container.decode(String.self, forKey: .text)
        toolCalls = try container.decodeIfPresent([ToolCallRecord].self, forKey: .toolCalls) ?? []
        replayMessages = (try? container.decodeIfPresent([Message].self, forKey: .replayMessages)) ?? []
        finishReason = (try? container.decodeIfPresent(FinishReason.self, forKey: .finishReason)) ?? nil
        usage = (try? container.decodeIfPresent(Usage.self, forKey: .usage)) ?? nil
        turnState = (try? container.decodeIfPresent(TurnState.self, forKey: .turnState)) ?? nil
        context = (try? container.decodeIfPresent(TurnContextSnapshot.self, forKey: .context)) ?? nil
        errorDescription = try container.decodeIfPresent(String.self, forKey: .errorDescription)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(text, forKey: .text)
        try container.encode(toolCalls, forKey: .toolCalls)
        if !replayMessages.isEmpty {
            try container.encode(replayMessages, forKey: .replayMessages)
        }
        try container.encodeIfPresent(finishReason, forKey: .finishReason)
        try container.encodeIfPresent(usage, forKey: .usage)
        try container.encodeIfPresent(turnState, forKey: .turnState)
        try container.encodeIfPresent(context, forKey: .context)
        try container.encodeIfPresent(errorDescription, forKey: .errorDescription)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

extension ChatMessage {
    var hasReplayableContent: Bool {
        !exactReplayMessages.isEmpty || !reconstructedReplayMessages.isEmpty
    }

    /// 持久化过的精确 transcript。没有时返回空,由调用方决定要不要退回重建。
    var exactReplayMessages: [Message] {
        replayMessages
    }

    /// 用当前消息内容重建一份可回放 transcript。
    ///
    /// 只包含已经完成的工具调用。未完成的 tool_use 带回 provider 基本都会被拒收。
    var reconstructedReplayMessages: [Message] {
        let completed = toolCalls.filter { $0.output != nil }
        var result: [Message] = []
        var content: [ContentPart] = []
        if !text.isEmpty {
            content.append(.text(text))
        }
        content.append(contentsOf: completed.map { call in
            .toolCall(ToolCall(
                toolCallId: call.id,
                toolName: call.name,
                input: call.input
            ))
        })

        if !content.isEmpty {
            result.append(Message(role: .assistant, content: content))
        }
        result.append(contentsOf: completed.map { call in
            .toolResult(
                toolCallId: call.id,
                toolName: call.name,
                result: .string(call.output ?? ""),
                isError: call.isError
            )
        })
        return result
    }

    /// 预算吃紧时的紧凑 transcript。优先保留用户可见总结,没有总结再退回完整重建。
    var compactReplayMessages: [Message] {
        guard !text.isEmpty else {
            return exactReplayMessages.isEmpty ? reconstructedReplayMessages : exactReplayMessages
        }
        return [.assistant(text)]
    }
}

/// 一轮回复落地时的预算快照。
///
/// 它只回答三件事:这轮是按哪个模型窗口算的、最后大概占了多少上下文、为了塞进窗口
/// 做了多少压缩/裁剪。后面无论接更多数据源还是换成别的 agent capability,这层都能继续用。
struct TurnContextSnapshot: Equatable, Codable, Sendable {
    var providerId: String
    var requestedModelId: String
    var servedModelId: String?
    var contextWindow: Int?
    var reservedOutputTokens: Int?
    var estimatedPromptTokens: Int?
    var actualPromptTokens: Int?
    var compactedAssistantMessages: Int
    var droppedConversationTurns: Int

    init(
        providerId: String,
        requestedModelId: String,
        servedModelId: String? = nil,
        contextWindow: Int? = nil,
        reservedOutputTokens: Int? = nil,
        estimatedPromptTokens: Int? = nil,
        actualPromptTokens: Int? = nil,
        compactedAssistantMessages: Int = 0,
        droppedConversationTurns: Int = 0
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
    }
}
