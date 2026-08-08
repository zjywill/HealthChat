import Foundation

public enum AgentTurnEvent: Sendable {
    case textDelta(String)
    case toolCallStarted(ToolCallRecordDTO)
    case toolCallFinished(id: String, output: AgentToolOutput, isError: Bool)
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
    mutating func startToolCall(_ record: ToolCallRecordDTO)
    mutating func finishToolCall(id: String, output: AgentToolOutput, isError: Bool)
    mutating func completeTurn(
        transcript: AgentTranscript,
        finishReason: AgentFinishReason?,
        usage: AgentUsage?,
        context: TurnContextSnapshotDTO?
    )
    /// 用户手动停下。已经收到的文本和工具结果都留着。
    mutating func markStopped()
    mutating func markFailed(_ description: String)
}

public extension AgentTurnSink {
    mutating func apply(_ event: AgentTurnEvent) {
        switch event {
        case .textDelta(let delta):
            appendText(delta)
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
