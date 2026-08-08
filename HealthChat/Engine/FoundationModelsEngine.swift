import Foundation
import FoundationModels

final class FoundationModelsEngine: AgentEngine, @unchecked Sendable {
    let name = "端上模型"

    private let toolEventSink: FoundationToolEventSink
    private var session: LanguageModelSession

    init() {
        let toolEventSink = FoundationToolEventSink()
        self.toolEventSink = toolEventSink
        session = Self.makeSession(toolEventSink: toolEventSink)
    }

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        let text = history.last(where: { $0.role == .user })?.text ?? ""

        return AsyncThrowingStream { continuation in
            let task = Task {
                await toolEventSink.setHandler { note in
                    continuation.yield(.toolCall(note))
                }

                do {
                    try Self.checkAvailability()
                    try await streamReply(
                        to: text,
                        continuation: continuation,
                        canRetryAfterContextReset: true
                    )
                    await toolEventSink.setHandler(nil)
                    continuation.finish()
                } catch {
                    await toolEventSink.setHandler(nil)
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
                session = Self.makeSession(toolEventSink: toolEventSink)
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

    private static func makeSession(toolEventSink: FoundationToolEventSink) -> LanguageModelSession {
        let tools: [any Tool] = HealthTools.all.map {
            FoundationHealthTool(spec: $0, eventSink: toolEventSink)
        }
        return LanguageModelSession(
            tools: tools,
            instructions: HealthAssistantInstructions.text
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

private struct FoundationHealthTool: Tool {
    @Generable
    struct Arguments {
        @Guide(description: "查询最近多少天，范围 1–90", .range(1...90))
        var days: Int
    }

    let name: String
    let description: String

    private let spec: HealthToolSpec
    private let eventSink: FoundationToolEventSink

    init(spec: HealthToolSpec, eventSink: FoundationToolEventSink) {
        name = spec.name
        description = spec.description
        self.spec = spec
        self.eventSink = eventSink
    }

    func call(arguments: Arguments) async throws -> String {
        let days = min(max(arguments.days, 1), 90)
        await eventSink.emit(HealthTools.note(for: name, days: days))
        return try await spec.run(days)
    }
}

private actor FoundationToolEventSink {
    private var handler: (@Sendable (String) -> Void)?

    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        self.handler = handler
    }

    func emit(_ note: String) {
        handler?(note)
    }
}
