import SwiftUI

@MainActor
@Observable
final class ChatViewModel {
    private(set) var session = ChatSession()
    var summaries: [SessionSummary] = []
    var input = ""
    var isReplying = false
    var isLoadingConversation = true
    var engineGuidance: String?
    /// 先给按时段挑的默认问题,AI 生成的回来了再替换。
    var suggestions = SuggestedQuestions.defaults()

    private var currentReplyTask: Task<Void, Never>?
    private var hasRequestedSuggestions = false
    /// 没选话题时该显示的那几条,取消话题选择时用它复位。
    private var situationSuggestions = SuggestedQuestions.defaults()

    var messages: [ChatMessage] { session.messages }

    init() {
        refreshEngineAvailability()
        Task {
            await loadInitialSession()
        }
    }

    func send(_ suggestedQuestion: String? = nil) {
        let text = (suggestedQuestion ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying, !isLoadingConversation else { return }
        input = ""
        session.messages.append(ChatMessage(role: .user, text: text))
        startReply()
    }

    func stopReply() {
        currentReplyTask?.cancel()
    }

    func retry(_ messageID: UUID) {
        guard !isReplying,
              !isLoadingConversation,
              let index = session.messages.firstIndex(where: { $0.id == messageID }),
              index == session.messages.index(before: session.messages.endIndex),
              session.messages[index].role == .assistant,
              session.messages[index].errorDescription != nil,
              session.messages[..<index].last(where: { $0.role == .user }) != nil else {
            return
        }

        session.messages.remove(at: index)
        startReply()
    }

    // MARK: - 会话

    /// 开一条新会话。当前这条已经存过盘,不会丢。
    func startNewSession(ephemeral: Bool = false) {
        guard !isReplying else { return }
        session = ChatSession(isEphemeral: ephemeral)
        suggestions = situationSuggestions
        Task { await refreshSummaries() }
    }

    /// 会话还空着时可以随时切换临不临时;开聊之后就定了,不然"说好不存"会被推翻。
    func setEphemeral(_ isEphemeral: Bool) {
        guard messages.isEmpty, !isReplying else { return }
        session.isEphemeral = isEphemeral
    }

    /// 从 check-in 通知点进来:直接开一条带话题的新会话,并把开场问题填进输入框。
    ///
    /// 不自动发送——通知是邀请不是命令,让用户看一眼再决定问不问。
    func open(_ checkIn: CheckInLaunch) {
        guard !isReplying else { return }
        session = ChatSession(topicId: checkIn.topicId)
        if let topic = session.topic {
            suggestions = topic.questions.map { SuggestedQuestion(icon: topic.icon, text: $0) }
        }
        if let question = checkIn.question {
            input = question
        }
        Task { await refreshSummaries() }
    }

    func openSession(id: UUID) {
        guard !isReplying, id != session.id else { return }
        Task {
            if let opened = try? await SessionStore.shared.load(id: id) {
                session = opened
            }
            await refreshSummaries()
        }
    }

    func deleteSession(id: UUID) {
        guard !isReplying else { return }
        Task {
            try? await SessionStore.shared.delete(id: id)
            // 删掉的正是当前这条,就换上剩下里最近的一条,没有就开新的。
            if id == session.id {
                session = (try? await SessionStore.shared.mostRecent()) ?? ChatSession()
            }
            await refreshSummaries()
        }
    }

    func clearConversation() {
        guard !isReplying else { return }
        let id = session.id
        session = ChatSession()
        Task {
            try? await SessionStore.shared.delete(id: id)
            await refreshSummaries()
        }
    }

    /// 选话题。只在会话还空着时能改——聊到一半换话题,前面的上下文就对不上了。
    ///
    /// 选完直接换成这个话题的默认问题:话题已经把范围说清楚了,不值得再花一次模型调用。
    func selectTopic(_ topic: ChatTopic?) {
        guard messages.isEmpty, !isReplying else { return }
        session.topicId = topic?.id
        suggestions = topic.map { chosen in
            chosen.questions.map { SuggestedQuestion(icon: chosen.icon, text: $0) }
        } ?? situationSuggestions
    }

    /// 每次启动只生成一次:模型那步是一次真实调用,不该每回到首屏就花一遍钱。
    ///
    /// 分两级:先本地判定处境(纯 HealthKit 查询,没配 key 也有),再交给模型润色成人话。
    func refreshSuggestionsIfNeeded() {
        guard !hasRequestedSuggestions, !isLoadingConversation, messages.isEmpty else { return }
        hasRequestedSuggestions = true

        Task {
            let situation = await HealthSituation.detect()
            guard messages.isEmpty else { return }
            situationSuggestions = situation.questions
            if session.topicId == nil {
                suggestions = situationSuggestions
            }

            guard let settings = try? cloudSettings() else { return }
            let suggester = QuestionSuggester(
                providerId: settings.provider,
                model: settings.model,
                situation: situation
            )
            guard let generated = try? await suggester.suggestions() else { return }
            // 回来得太晚就别抢了——用户已经开聊或者已经自己选了话题。
            guard messages.isEmpty else { return }
            situationSuggestions = generated
            if session.topicId == nil {
                suggestions = generated
            }
        }
    }

    func refreshEngineAvailability() {
        let hasCloudKey = (try? cloudKeyAvailable()) ?? false
        engineGuidance = hasCloudKey
            ? nil
            : "还没配置云端模型。请前往设置填写 API key，并选择 provider 和模型。"
    }

    // MARK: - 回复

    private func startReply() {
        session.messages.append(ChatMessage(role: .assistant, text: ""))
        isReplying = true

        currentReplyTask = Task {
            do {
                let engine = try resolveEngine()
                for try await event in engine.reply(to: session.messages) {
                    apply(event)
                }
            } catch is CancellationError {
                markStopped()
            } catch {
                if Task.isCancelled {
                    markStopped()
                } else {
                    markFailed(error)
                }
            }
            isReplying = false
            currentReplyTask = nil
            await saveSession()
        }
    }

    private func apply(_ event: AgentEvent) {
        let last = session.messages.count - 1
        switch event {
        case .textDelta(let delta):
            session.messages[last].text += delta
        case .toolCallStarted(let record):
            session.messages[last].toolCalls.append(record)
        case .toolCallFinished(let id, let output, let isError):
            guard let index = session.messages[last].toolCalls.firstIndex(where: { $0.id == id })
            else { return }
            session.messages[last].toolCalls[index].output = output
            session.messages[last].toolCalls[index].isError = isError
        }
    }

    private func markStopped() {
        let last = session.messages.count - 1
        if session.messages[last].text.isEmpty {
            session.messages[last].text = "已停止回复"
        }
    }

    private func markFailed(_ error: any Error) {
        let last = session.messages.count - 1
        let description = error.localizedDescription
        if session.messages[last].text.isEmpty {
            session.messages[last].text = "无法回复：\(description)"
        } else {
            session.messages[last].text += "\n\n无法继续：\(description)"
        }
        session.messages[last].errorDescription = description
    }

    // MARK: - 引擎

    private func resolveEngine() throws -> any AgentEngine {
        let settings = try cloudSettings()
        return AIKitEngine(
            providerId: settings.provider,
            model: settings.model,
            topic: session.topic
        )
    }

    /// 云端调用要齐的三样:key、provider、model。缺一样就别发请求。
    private func cloudSettings() throws -> (provider: String, model: String) {
        guard try cloudKeyAvailable() else {
            throw AgentError.needsAPIKey
        }

        let defaults = UserDefaults.standard
        // 模型是在设置里选的,选空了就别拿默认模型顶上——那多半属于另一个 provider。
        let model = defaults.string(forKey: EngineSettings.modelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else {
            throw AgentError.needsModelSelection
        }

        return (
            nonEmptySetting(
                defaults.string(forKey: EngineSettings.providerKey),
                fallback: EngineSettings.defaultProvider
            ),
            model
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

    // MARK: - 存取

    private func loadInitialSession() async {
        defer { isLoadingConversation = false }
        session = (try? await SessionStore.shared.mostRecent()) ?? ChatSession()
        await refreshSummaries()
    }

    private func saveSession() async {
        // 空会话不落盘,否则每次点「新对话」都在列表里留一条空壳。
        // 临时会话永远不落盘——这是它唯一的意义。
        guard !session.isEmpty, !session.isEphemeral else { return }
        session.updatedAt = Date()
        do {
            try await SessionStore.shared.save(session)
        } catch {
            print("保存会话失败：\(error.localizedDescription)")
        }
        await refreshSummaries()
    }

    private func refreshSummaries() async {
        summaries = (try? await SessionStore.shared.summaries()) ?? []
    }
}
