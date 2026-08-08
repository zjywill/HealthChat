import Foundation
import FoundationModels

final class FoundationModelsEngine: AgentEngine, @unchecked Sendable {
    let name = "端上模型"

    private var session: LanguageModelSession

    init() {
        session = Self.makeSession()
    }

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        let text = history.last(where: { $0.role == .user })?.text ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Self.checkAvailability()
                    try await streamReply(
                        to: text,
                        continuation: continuation,
                        canRetryAfterContextReset: true
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamReply(
        to text: String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation,
        canRetryAfterContextReset: Bool
    ) async throws {
        var previousText = ""

        do {
            for try await snapshot in session.streamResponse(to: text) {
                try Task.checkCancellation()
                let currentText = snapshot.content
                let delta: String
                if currentText.hasPrefix(previousText) {
                    delta = String(currentText.dropFirst(previousText.count))
                } else {
                    delta = currentText
                }
                if !delta.isEmpty {
                    continuation.yield(.textDelta(delta))
                }
                previousText = currentText
            }
        } catch let error as LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize where canRetryAfterContextReset:
                session = Self.makeSession()
                try await streamReply(
                    to: text,
                    continuation: continuation,
                    canRetryAfterContextReset: false
                )
            case .guardrailViolation, .refusal:
                continuation.yield(.textDelta("这个问题无法由端上模型回答。你可以换一种更具体、只关注健康数据趋势的问法。"))
            default:
                throw error
            }
        }
    }

    private static func makeSession() -> LanguageModelSession {
        LanguageModelSession(
            instructions: """
            你是 HealthChat 的中文健康助手。回答简洁、清楚，不编造用户数据。
            健康分析仅供参考，不做医疗诊断。
            """
        )
    }

    private static func checkAvailability() throws {
        switch SystemLanguageModel.default.availability {
        case .available:
            return
        case .unavailable(let reason):
            let message: String
            switch reason {
            case .deviceNotEligible:
                message = "此设备不支持 Apple Intelligence"
            case .appleIntelligenceNotEnabled:
                message = "请先开启 Apple Intelligence"
            case .modelNotReady:
                message = "模型仍在下载或准备中"
            @unknown default:
                message = "端上模型暂不可用"
            }
            throw AgentError.modelUnavailable(message)
        }
    }
}
