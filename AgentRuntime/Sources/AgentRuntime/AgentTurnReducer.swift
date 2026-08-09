import Foundation

public enum AgentTurnEvent: Sendable {
    case textDelta(String)
    /// 模型的思考。带工具的一轮里会出现好几段——每次要调工具之前都想一次。
    case reasoningDelta(String)
    case toolCallStarted(ToolCallRecordDTO)
    case toolCallFinished(id: String, output: AgentToolOutput, isError: Bool)
    /// 这一轮要重跑了,已经吐出去的半截话得撤掉——重跑会从头再说一遍,不撤就是半句接整句。
    ///
    /// 和 `.retryScheduled` 分开发:重跑不一定是重试(压缩之后重跑那一轮也走这条),
    /// 而「撤字」和「告诉用户在重试」是两件事,合在一起的话压缩会顶着重试的文案出现。
    case textRolledBack(characterCount: Int)
    /// 同上,但撤的是思考。两个计数分开:重跑时两边都要回到这一次尝试之前的样子,
    /// 而它们各自存在各自的地方。
    case reasoningRolledBack(characterCount: Int)
    /// 这一轮失败了,退避之后会再试。纯观测事件,给 UI 用。
    case retryScheduled(AgentRetryNotice)
    /// 开始叫模型写整段摘要。压缩要花钱花时间,静默地做等于线上出问题时无从查起。
    case compactionStarted(AgentCompactionReason)
    /// 总结没写成。不是致命错误——退回机械压缩继续跑,但要留下痕迹。
    case compactionFailed(reason: AgentCompactionReason, message: String)
    /// 早先某一段被总结掉了,artifact 挂在 `messageID` 这条上。
    ///
    /// 唯一一个不落在"正在写的那条回复"上的事件——总结是一次真实的模型调用,算完必须存下来,
    /// 否则每轮都要重算一遍,既慢又费钱。
    case historyCompacted(messageID: UUID, artifact: CompactionArtifact)
    case turnCompleted(
        transcript: AgentTranscript,
        finishReason: AgentFinishReason?,
        usage: AgentUsage?,
        context: TurnContextSnapshotDTO?
    )
}

/// 承接一轮事件的容器。
///
/// app 的 `ChatMessage` 和 runtime 的 `AgentChatMessageDTO` 各实现一份存储,但「事件怎么
/// 改状态」只写在 `apply` 里一处——否则测试里验的和 app 里跑的迟早分家。
public protocol AgentTurnSink {
    mutating func appendText(_ delta: String)
    mutating func appendReasoning(_ delta: String)
    mutating func startToolCall(_ record: ToolCallRecordDTO)
    mutating func finishToolCall(id: String, output: AgentToolOutput, isError: Bool)
    mutating func completeTurn(
        transcript: AgentTranscript,
        finishReason: AgentFinishReason?,
        usage: AgentUsage?,
        context: TurnContextSnapshotDTO?
    )
    /// 撤掉刚吐出去的 `characterCount` 个字符。
    ///
    /// 只在重试前用:那一轮已经说了半句话,重试的完整回答会从头再来一遍,不撤掉就是把
    /// 半句和整句拼在一起。撤的是**这一次尝试**吐的量,更早那几轮的文本不受影响。
    mutating func rollBackText(_ characterCount: Int)
    /// 同上,撤的是思考。
    mutating func rollBackReasoning(_ characterCount: Int)
    /// 用户手动停下。已经收到的文本和工具结果都留着。
    mutating func markStopped()
    mutating func markFailed(_ description: String)
}

public extension AgentTurnSink {
    mutating func apply(_ event: AgentTurnEvent) {
        switch event {
        case .textDelta(let delta):
            appendText(delta)
        case .reasoningDelta(let delta):
            appendReasoning(delta)
        case .toolCallStarted(let record):
            startToolCall(record)
        case .toolCallFinished(let id, let output, let isError):
            finishToolCall(id: id, output: output, isError: isError)
        case .turnCompleted(let transcript, let finishReason, let usage, let context):
            completeTurn(
                transcript: transcript,
                finishReason: finishReason,
                usage: usage,
                context: context
            )
        case .textRolledBack(let characterCount):
            rollBackText(characterCount)
        case .reasoningRolledBack(let characterCount):
            rollBackReasoning(characterCount)
        case .retryScheduled, .compactionStarted, .compactionFailed:
            // 观测用。落到哪条消息上都不合适,由 app 自己决定要不要显示或记日志。
            break
        case .historyCompacted:
            // 这条不是给当前回复的,由数组层按 id 投递。
            break
        }
    }
}

extension AgentChatMessageDTO: AgentTurnSink {
    public mutating func appendText(_ delta: String) {
        if textIsPlaceholder {
            text = ""
            textIsPlaceholder = false
        }
        text += delta
    }

    public mutating func appendReasoning(_ delta: String) {
        reasoning += delta
    }

    public mutating func startToolCall(_ record: ToolCallRecordDTO) {
        toolCalls.append(record)
    }

    public mutating func finishToolCall(id: String, output: AgentToolOutput, isError: Bool) {
        guard let index = toolCalls.firstIndex(where: { $0.id == id }) else { return }
        toolCalls[index].output = output
        toolCalls[index].isError = isError
    }

    public mutating func completeTurn(
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

    public mutating func rollBackText(_ characterCount: Int) {
        guard characterCount > 0, !textIsPlaceholder else { return }
        text.removeLast(min(characterCount, text.count))
    }

    public mutating func rollBackReasoning(_ characterCount: Int) {
        guard characterCount > 0 else { return }
        reasoning.removeLast(min(characterCount, reasoning.count))
    }

    public mutating func markStopped() {
        if text.isEmpty {
            textIsPlaceholder = true
        }
        storedTurn.state = .stopped
    }

    public mutating func markFailed(_ description: String) {
        if text.isEmpty {
            textIsPlaceholder = true
        }
        storedTurn.state = .failed
        errorDescription = description
    }
}

/// 数组层的便利包装:大多数调用方拿着的是整条会话,不是单条消息。
public enum AgentTurnReducer {
    public static func startReply(in history: inout [AgentChatMessageDTO]) {
        history.append(.init(role: .assistant, text: ""))
    }

    public static func apply(_ event: AgentTurnEvent, in history: inout [AgentChatMessageDTO]) {
        if case .historyCompacted(let messageID, let artifact) = event {
            guard let index = history.firstIndex(where: { $0.id == messageID }) else { return }
            history[index].storedTurn.compaction = artifact
            return
        }
        guard let last = history.indices.last else { return }
        history[last].apply(event)
    }

    public static func markStopped(in history: inout [AgentChatMessageDTO]) {
        guard let last = history.indices.last else { return }
        history[last].markStopped()
    }

    public static func markFailed(_ description: String, in history: inout [AgentChatMessageDTO]) {
        guard let last = history.indices.last else { return }
        history[last].markFailed(description)
    }
}
