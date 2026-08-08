import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isReplying = false

    /// T4.5 起改为按「引擎选择策略」自动选(见 PLAN.md)。
    private let engine: any AgentEngine = FoundationModelsEngine()

    func send(_ suggestedQuestion: String? = nil) {
        let text = (suggestedQuestion ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        messages.append(ChatMessage(role: .assistant, text: ""))
        isReplying = true

        Task {
            defer { isReplying = false }
            do {
                for try await event in engine.reply(to: messages) {
                    switch event {
                    case .textDelta(let delta):
                        messages[messages.count - 1].text += delta
                    case .toolCall(let note):
                        messages[messages.count - 1].toolNotes.append(note)
                    }
                }
            } catch {
                messages[messages.count - 1].text = "出错了:\(error.localizedDescription)"
            }
        }
    }
}
