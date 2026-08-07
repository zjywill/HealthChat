import Foundation

/// M0 占位引擎:流式回显,用来跑通聊天 UI。M3 接入真引擎后删除。
struct EchoEngine: AgentEngine {
    let name = "Echo(占位)"

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        let last = history.last(where: { $0.role == .user })?.text ?? ""
        return AsyncThrowingStream { continuation in
            let task = Task {
                continuation.yield(.toolCall("占位引擎,还没接健康数据"))
                for character in "你说:\(last)" {
                    try await Task.sleep(for: .milliseconds(25))
                    continuation.yield(.textDelta(String(character)))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
