import Foundation
import AIKit

struct AIKitEngine: AgentEngine {
    let name = "云端模型"

    private let providerId: String
    private let model: String

    init(providerId: String = "anthropic", model: String = "claude-sonnet-5") {
        self.providerId = providerId
        self.model = model
    }

    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
                        throw AgentError.needsAPIKey
                    }
                    let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else {
                        throw AgentError.needsAPIKey
                    }

                    let client = try AIClient(
                        providerId: providerId,
                        configuration: .init(apiKey: key)
                    )
                    let options = CallOptions(
                        model: model,
                        prompt: makePrompt(from: history)
                    )

                    for try await part in try client.stream(options) {
                        try Task.checkCancellation()
                        if case .textDelta(_, let delta, _) = part, !delta.isEmpty {
                            continuation.yield(.textDelta(delta))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makePrompt(from history: [ChatMessage]) -> Prompt {
        var prompt: Prompt = [.system(HealthAssistantInstructions.text)]
        prompt.append(contentsOf: history.compactMap { message in
            guard !message.text.isEmpty else { return nil }
            switch message.role {
            case .user:
                return .user(message.text)
            case .assistant:
                return .assistant(message.text)
            }
        })
        return prompt
    }
}
