import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input = ""
    var isReplying = false
    var isLoadingConversation = true
    var engineGuidance: String?

    private let onDeviceEngine = FoundationModelsEngine()
    private var currentReplyTask: Task<Void, Never>?

    init() {
        refreshEngineAvailability()
        Task {
            await loadConversation()
        }
    }

    func send(_ suggestedQuestion: String? = nil) {
        let text = (suggestedQuestion ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying, !isLoadingConversation else { return }
        input = ""
        messages.append(ChatMessage(role: .user, text: text))
        startReply()
    }

    func stopReply() {
        currentReplyTask?.cancel()
    }

    func retry(_ messageID: UUID) {
        guard !isReplying,
              !isLoadingConversation,
              let index = messages.firstIndex(where: { $0.id == messageID }),
              index == messages.index(before: messages.endIndex),
              messages[index].role == .assistant,
              messages[index].errorDescription != nil,
              messages[..<index].last(where: { $0.role == .user }) != nil else {
            return
        }

        messages.remove(at: index)
        onDeviceEngine.reset()
        startReply()
    }

    private func startReply() {
        messages.append(ChatMessage(role: .assistant, text: ""))
        isReplying = true

        currentReplyTask = Task {
            do {
                let engine = try resolveEngine()
                for try await event in engine.reply(to: messages) {
                    switch event {
                    case .textDelta(let delta):
                        messages[messages.count - 1].text += delta
                    case .toolCall(let note):
                        messages[messages.count - 1].toolNotes.append(note)
                    }
                }
            } catch is CancellationError {
                if messages[messages.count - 1].text.isEmpty {
                    messages[messages.count - 1].text = "已停止回复"
                }
            } catch {
                if Task.isCancelled {
                    if messages[messages.count - 1].text.isEmpty {
                        messages[messages.count - 1].text = "已停止回复"
                    }
                } else {
                    let description = error.localizedDescription
                    if messages[messages.count - 1].text.isEmpty {
                        messages[messages.count - 1].text = "无法回复：\(description)"
                    } else {
                        messages[messages.count - 1].text += "\n\n无法继续：\(description)"
                    }
                    messages[messages.count - 1].errorDescription = description
                }
            }
            isReplying = false
            currentReplyTask = nil
            await saveConversation()
        }
    }

    func refreshEngineAvailability() {
        let hasCloudKey = (try? cloudKeyAvailable()) ?? false
        engineGuidance = FoundationModelsEngine.isAvailable || hasCloudKey
            ? nil
            : "端上模型暂不可用。请开启 Apple Intelligence，或前往设置填写云端 API key。"
    }

    func clearConversation() {
        guard !isReplying else { return }
        messages = []
        onDeviceEngine.reset()
        Task {
            do {
                try await ConversationStore.shared.clear()
            } catch {
                print("清空对话失败：\(error.localizedDescription)")
            }
        }
    }

    private func resolveEngine() throws -> any AgentEngine {
        let defaults = UserDefaults.standard
        let storedChoice = defaults.string(forKey: EngineSettings.choiceKey)
            ?? EngineSettings.defaultChoice
        let choice = EngineChoice(rawValue: storedChoice) ?? .automatic

        switch choice {
        case .automatic:
            if FoundationModelsEngine.isAvailable {
                return onDeviceEngine
            }
            guard try cloudKeyAvailable() else {
                throw AgentError.noEngineAvailable
            }
            return makeCloudEngine(defaults: defaults)
        case .onDevice:
            return onDeviceEngine
        case .cloud:
            return makeCloudEngine(defaults: defaults)
        }
    }

    private func makeCloudEngine(defaults: UserDefaults) -> AIKitEngine {
        AIKitEngine(
            providerId: nonEmptySetting(
                defaults.string(forKey: EngineSettings.providerKey),
                fallback: EngineSettings.defaultProvider
            ),
            model: nonEmptySetting(
                defaults.string(forKey: EngineSettings.modelKey),
                fallback: EngineSettings.defaultModel
            )
        )
    }

    private func cloudKeyAvailable() throws -> Bool {
        let key = try KeychainStore.get(account: KeychainStore.apiKeyAccount) ?? ""
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func nonEmptySetting(_ value: String?, fallback: String) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func loadConversation() async {
        defer { isLoadingConversation = false }
        do {
            messages = try await ConversationStore.shared.load()
        } catch {
            print("载入对话失败：\(error.localizedDescription)")
        }
    }

    private func saveConversation() async {
        do {
            try await ConversationStore.shared.save(messages)
        } catch {
            print("保存对话失败：\(error.localizedDescription)")
        }
    }
}
