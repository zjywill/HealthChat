import SwiftUI
import AgentRuntime

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

    /// 每轮现造引擎。测试注入一个脚本化的假引擎,就能在不碰 Keychain 和网络的前提下
    /// 走完整条 loop。
    typealias EngineFactory = @MainActor @Sendable (ChatTopic?) throws -> any AgentEngine

    private let engineFactory: EngineFactory?

    var messages: [ChatMessage] { session.messages }

    /// - Parameter loadsPersistedSession: 关掉就不读盘、不写盘,`isLoadingConversation`
    ///   直接是 false。测试用。
    init(engineFactory: EngineFactory? = nil, loadsPersistedSession: Bool = true) {
        self.engineFactory = engineFactory
        refreshEngineAvailability()
        guard loadsPersistedSession else {
            session = ChatSession(isEphemeral: true)
            isLoadingConversation = false
            return
        }
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

    /// 重新回答某一条回复。
    ///
    /// 中间那条也能重答——从它开始后面整段都丢掉,再重新生成。不做"保留旧版本、左右
    /// 切换"那套:想留着旧的走分支就行,那本来就是分支的意思。
    func retry(_ messageID: UUID) {
        guard canRetry(messageID), let index = index(of: messageID) else { return }

        session.messages.removeSubrange(index...)
        startReply()
    }

    func canRetry(_ messageID: UUID) -> Bool {
        guard !isReplying, !isLoadingConversation, let index = index(of: messageID) else {
            return false
        }
        return session.messages[index].role == .assistant
            && session.messages[..<index].contains { $0.role == .user }
    }

    /// 从某条回复分叉出一条新会话:到这条为止的内容照搬过去,原会话原样留在列表里。
    ///
    /// 想试另一个问法又不想毁掉现在这条,走这里;愿意毁掉的走 retry。
    func branch(from messageID: UUID) {
        guard !isReplying, !isLoadingConversation, let index = index(of: messageID) else { return }

        let history = Array(session.messages[...index])
        session = ChatSession(
            messages: history,
            topicId: session.topicId,
            // 临时会话分叉出来的还是临时的——说好不存就不能因为换了条会话就存了。
            isEphemeral: session.isEphemeral
        )
        Task {
            await saveSession()
        }
    }

    private func index(of messageID: UUID) -> Int? {
        session.messages.firstIndex { $0.id == messageID }
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
                // AsyncThrowingStream 的消费者被取消时,`for try await` 是**正常**结束的,
                // 不抛 CancellationError。只靠 catch 抓不到"用户按了停止",那条回复会既没
                // 文本也没状态地存下去。
                if Task.isCancelled {
                    markStopped()
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

    /// 事件落到最后一条(正在写的那条回复)上。语义在 `AgentTurnSink.apply` 里,
    /// 这里只负责找到收件人——每个 delta 都把整条会话翻一遍 DTO 太贵了。
    private func apply(_ event: AgentEvent) {
        guard let last = session.messages.indices.last else { return }
        session.messages[last].apply(event)
    }

    private func markStopped() {
        guard let last = session.messages.indices.last else { return }
        session.messages[last].markStopped()
    }

    private func markFailed(_ error: any Error) {
        guard let last = session.messages.indices.last else { return }
        session.messages[last].markFailed(error.localizedDescription)
    }

    // MARK: - 引擎

    private func resolveEngine() throws -> any AgentEngine {
        if let engineFactory {
            return try engineFactory(session.topic)
        }
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
