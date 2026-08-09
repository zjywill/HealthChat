import SwiftUI
import AgentRuntime

@MainActor
@Observable
final class ChatViewModel {
    private(set) var session = ChatSession()
    var summaries: [SessionSummary] = []
    /// 用户自己开的几件长期的事,最近动过的在前。
    var goals: [GoalSummary] = []
    var input = ""
    var isReplying = false
    var isLoadingConversation = true
    var engineGuidance: String?
    /// 正在退避重试时给用户看的一句话。
    ///
    /// 退避期间界面上什么都不动的话,等十几秒和卡死是一模一样的观感——而这时候 app 其实
    /// 知道发生了什么。
    private(set) var retryNotice: String?
    /// 先给按时段挑的默认问题,AI 生成的回来了再替换。
    var suggestions = SuggestedQuestions.defaults()

    private var currentReplyTask: Task<Void, Never>?
    private var hasRequestedSuggestions = false
    /// 没选话题时该显示的那几条,取消话题选择时用它复位。
    private var situationSuggestions = SuggestedQuestions.defaults()

    /// 这条会话开始时的记忆快照,**会话之内不换**。
    ///
    /// 引擎每轮现造,靠它拿到同一份 system 段:中途换记忆既打掉 prompt 缓存,也让模型对
    /// 用户的认知在一条对话里跳变。抽取写在会话结束、快照读在会话开始,正好配套——这条
    /// 会话学到的东西,下一条会话生效。
    private(set) var memory: MemorySnapshot = .empty
    /// 当前这条会话已经发过请求了。发过之后就不再换快照,哪怕后台刚抽完新记忆。
    private var didStartReplyInSession = false
    /// 抽取排成一队。两个抽取同时读同一份记忆再各写各的,会写出两条一样的。
    private var harvestTail: Task<Void, Never>?

    /// 每轮现造引擎。测试注入一个脚本化的假引擎,就能在不碰 Keychain 和网络的前提下
    /// 走完整条 loop。
    typealias EngineFactory = @MainActor @Sendable (ChatTopic?) throws -> any AgentEngine

    private let engineFactory: EngineFactory?
    private let memoryStore: MemoryStore
    private let sessionStore: SessionStore

    var messages: [ChatMessage] { session.messages }

    /// - Parameters:
    ///   - loadsPersistedSession: 关掉就不读盘、不写盘,`isLoadingConversation` 直接是
    ///     false。测试用。
    ///   - memoryStore: 测试必须传自己的。app 侧的测试跑在 app host 里,
    ///     `MemoryStore.shared` 就是模拟器上那份真的 `memory.json`。
    ///   - sessionStore: 同上。`loadsPersistedSession: false` 只挡住了**写**,而延续线要
    ///     去读盘找上一段——读到用户真实的会话,测试就会把它拽进来当成自己的。
    init(
        engineFactory: EngineFactory? = nil,
        loadsPersistedSession: Bool = true,
        memoryStore: MemoryStore = .shared,
        sessionStore: SessionStore = .shared
    ) {
        self.engineFactory = engineFactory
        self.memoryStore = memoryStore
        self.sessionStore = sessionStore
        refreshEngineAvailability()
        guard loadsPersistedSession else {
            session = ChatSession(isPrivate: true)
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
            // 分叉出来的**不**继承延续线:两条会话都认领同一条线的话,下次 check-in 接哪条
            // 就成了看谁最后更新的,而用户完全看不出规则。分叉是"另开一支",本来就该断开。
            threadId: nil,
            // 隐私会话分叉出来的还是隐私的——说好不存就不能因为换了条会话就存了。
            isPrivate: session.isPrivate,
            // 水位跟着搬过来:这段对话原会话已经抽过了,分叉不该让它再被抽一遍。
            memoryHarvestedMessageCount: min(session.memoryHarvestedMessageCount, history.count)
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
    func startNewSession(isPrivate: Bool = false) {
        guard !isReplying else { return }
        replaceSession(with: ChatSession(isPrivate: isPrivate), harvestingPrevious: true)
        suggestions = situationSuggestions
        Task { await refreshSummaries() }
    }

    /// 会话还空着时可以随时切换隐私与否;开聊之后就定了,不然"说好不存"会被推翻。
    func setPrivate(_ isPrivate: Bool) {
        guard messages.isEmpty, !isReplying else { return }
        session.isPrivate = isPrivate
    }

    /// 从 check-in 通知或者 Siri 进来:开一条带话题的新会话,把开场问题填进输入框。
    ///
    /// 默认不自动发送——通知是邀请不是命令,让用户看一眼再决定问不问。Siri 那条置了
    /// `autoSend`:问题已经说出口了,再要求按一次发送很没道理。
    func open(_ checkIn: CheckInLaunch) {
        guard !isReplying else { return }

        if let question = checkIn.question {
            input = question
        }
        // 说好回头看的事,这就在看了。留着它只会在接下来几天的早上重复同一句。
        if let followUpId = checkIn.followUpId {
            Task {
                _ = try? await memoryStore.delete(id: followUpId)
                refreshMemory()
            }
        }

        // 找线程要读盘,这几十毫秒里 `sendWhenReady` 会被 `isLoadingConversation` 挡着等,
        // 正好——Siri 冷启动那条路本来就在等它。
        isLoadingConversation = true
        Task {
            var continued: ChatSession?
            if let thread = checkIn.thread {
                continued = await sessionStore.openThread(thread)
            }
            replaceSession(
                with: continued ?? ChatSession(
                    // 延续线不带话题。一条攒了四天 check-in 的会话,今天问活动量、明天问睡眠;
                    // 话题写死在 system 段里,聊到第三天就和正在问的事对不上了,而中途改它
                    // 又会让模型对这次对话的认知跳变。重点由那句开场问题自己带。
                    topicId: checkIn.thread == nil ? checkIn.topicId : nil,
                    threadId: checkIn.thread?.id
                ),
                harvestingPrevious: true
            )
            isLoadingConversation = false

            if let topic = session.topic {
                suggestions = topic.questions.map { SuggestedQuestion(icon: topic.icon, text: $0) }
            }
            if let question = checkIn.question, checkIn.autoSend {
                sendWhenReady(question)
            }
            await refreshSummaries()
        }
    }

    // MARK: - 目标线

    /// 开一条新的目标线。
    ///
    /// 这条会话空着,所以**还不会落盘**(空会话不落盘那条规矩没有例外)。用户问出第一句它才
    /// 真正存在——比在列表里先摆一条什么都没有的「减脂计划」诚实。
    func startGoal(named name: String) {
        guard !isReplying else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        replaceSession(
            with: ChatSession(threadId: SessionThread.goal(UUID()).id, threadTitle: trimmed),
            harvestingPrevious: true
        )
        suggestions = situationSuggestions
        Task { await refreshSummaries() }
    }

    /// 回到某条目标线:接得上就接着上一段聊,接不上就在同一条线上另起一段。
    ///
    /// 「另起一段」不是丢历史——上一段一条不少地留在列表和 `search_sessions` 里,模型问一句
    /// 就能翻回去。换来的是这条线不会长成一份永不结束的日志。
    func openGoal(_ goal: GoalSummary) {
        guard !isReplying, let thread = goal.thread else { return }

        isLoadingConversation = true
        Task {
            let continued = await sessionStore.openThread(thread)
            replaceSession(
                with: continued ?? ChatSession(threadId: thread.id, threadTitle: goal.title),
                harvestingPrevious: true
            )
            isLoadingConversation = false
            await refreshSummaries()
        }
    }

    func renameGoal(_ goal: GoalSummary, to name: String) {
        guard !isReplying, let thread = goal.thread else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != goal.title else { return }

        Task {
            try? await sessionStore.renameThread(thread, to: trimmed)
            // 改的可能正是当前这条。盘上改了、手里这份没改,标题栏就会一直显示旧名字。
            if session.threadId == thread.id {
                session.threadTitle = trimmed
            }
            await refreshSummaries()
        }
    }

    /// 整条删掉,包括它已经分出去的每一段。
    ///
    /// 用户是把它当成一件事在管的,删的时候也该是一件事——只删最新那段,剩下两段会以
    /// 「减脂计划 · 7月2日起」的样子留在列表里,看着像没删干净。
    func deleteGoal(_ goal: GoalSummary) {
        guard !isReplying, let thread = goal.thread else { return }
        Task {
            let isCurrent = session.threadId == thread.id
            try? await sessionStore.deleteThread(thread)
            if isCurrent {
                // 不抽记忆:用户刚把这条线删了,再从里面记下点什么是反着来的。
                let next = (try? await sessionStore.mostRecent()) ?? ChatSession()
                replaceSession(with: next, harvestingPrevious: false)
            }
            await refreshSummaries()
        }
    }

    /// 等会话载入完再发。
    ///
    /// Siri 冷启动 app 时,这一句多半赶在会话还没载入完的时候到,而 `send` 会被
    /// `isLoadingConversation` 挡掉——问题就这么无声无息地没了。宁可多等几十毫秒。
    /// 等超过一秒就放弃自动发送,把它留在输入框里:那时候多半是别的地方出了问题,
    /// 让用户自己按一下,总好过一直转圈。
    private func sendWhenReady(_ question: String) {
        // 没配 key 就别自动发了:发出去只会立刻收到一条报错,还占掉一条会话。
        guard engineGuidance == nil else { return }

        Task {
            let deadline = Date().addingTimeInterval(1)
            while isLoadingConversation, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            guard !isLoadingConversation, input == question else { return }
            send(question)
        }
    }

    func openSession(id: UUID) {
        guard !isReplying, id != session.id else { return }
        Task {
            if let opened = try? await sessionStore.load(id: id) {
                replaceSession(with: opened, harvestingPrevious: true)
            }
            await refreshSummaries()
        }
    }

    func deleteSession(id: UUID) {
        guard !isReplying else { return }
        Task {
            try? await sessionStore.delete(id: id)
            // 删掉的正是当前这条,就换上剩下里最近的一条,没有就开新的。
            if id == session.id {
                // 不抽记忆:用户刚把这段对话删了,再从里面记下点什么是反着来的。
                let next = (try? await sessionStore.mostRecent()) ?? ChatSession()
                replaceSession(with: next, harvestingPrevious: false)
            }
            await refreshSummaries()
        }
    }

    func clearConversation() {
        guard !isReplying else { return }
        let id = session.id
        replaceSession(with: ChatSession(), harvestingPrevious: false)
        Task {
            try? await sessionStore.delete(id: id)
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
            let situation = await HealthSituation.detect(
                interests: await sessionStore.interests()
            )
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

    // MARK: - 记忆

    /// 换会话:走的那条该抽的记忆在这里抽,新的那条配一份最新的快照。
    private func replaceSession(with next: ChatSession, harvestingPrevious: Bool) {
        let previous = session
        // 接着的正是当前这条(用户已经在这条延续线里了)。不能当成"换会话"处理:那会拿它
        // 自己去抽一次记忆,还会把盘上那份盖掉刚打的字。
        guard next.id != previous.id else { return }
        session = next
        didStartReplyInSession = false
        if harvestingPrevious {
            harvestMemory(from: previous)
        }
        refreshMemory()
    }

    /// app 退到后台。多数会话是聊完就切走的,不在这儿抽,那段对话可能几天都轮不到抽一次。
    func harvestCurrentSessionMemory() {
        guard !isReplying else { return }
        harvestMemory(from: session)
    }

    private func refreshMemory() {
        guard EngineSettings.memoryEnabled else {
            memory = .empty
            return
        }
        let targetId = session.id
        Task {
            let snapshot = await memoryStore.snapshot()
            // 回来得太晚:人已经换到别的会话,或者已经在这条里问出第一句了。
            guard session.id == targetId, !didStartReplyInSession else { return }
            memory = snapshot
        }
    }

    /// 后台抽一次记忆。全程失败即放弃——记忆学不到东西是小事,让用户这一步卡住是大事。
    private func harvestMemory(from harvested: ChatSession) {
        guard EngineSettings.memoryEnabled, MemoryHarvest.shouldHarvest(harvested) else { return }
        // 注入了假引擎就是在测试里,别真去调模型。
        guard engineFactory == nil, let settings = try? cloudSettings() else { return }

        let previous = harvestTail
        let messageCount = harvested.messages.count
        harvestTail = Task {
            await previous?.value
            // 用此刻盘上的记忆,不是这条会话开始时那份快照——中间可能已经抽过别的会话了,
            // 拿旧的会把同一件事再记一遍。
            let snapshot = await memoryStore.snapshot()
            let extractor = MemoryExtractor(
                providerId: settings.provider,
                model: settings.model,
                snapshot: snapshot
            )
            guard let operations = try? await extractor.operations(from: harvested) else { return }
            _ = try? await memoryStore.apply(operations, sessionId: harvested.id)
            try? await sessionStore.markMemoryHarvested(
                id: harvested.id,
                messageCount: messageCount
            )
            refreshMemory()
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
        didStartReplyInSession = true
        retryNotice = nil

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
            retryNotice = nil
            currentReplyTask = nil
            await saveSession()
        }
    }

    /// 事件落到最后一条(正在写的那条回复)上。语义在 `AgentTurnSink.apply` 里,
    /// 这里只负责找到收件人——每个 delta 都把整条会话翻一遍 DTO 太贵了。
    private func apply(_ event: AgentEvent) {
        switch event {
        // 例外:整段摘要挂在早先某条上。存下来,下轮就不用再叫一次模型重算。
        case .historyCompacted(let messageID, let artifact):
            guard let index = session.messages.firstIndex(where: { $0.id == messageID }) else { return }
            session.messages[index].storedTurn.compaction = artifact
            return
        case .retryScheduled(let notice):
            retryNotice = "连接不稳定，正在重试（\(notice.attempt)/\(notice.maxAttempts)）"
        case .textDelta:
            // 重试成功了,模型开口了。
            retryNotice = nil
        default:
            break
        }
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
            topic: session.topic,
            goal: session.thread?.isGoal == true ? session.threadTitle : nil,
            // 隐私会话照样**读**记忆:承诺的是不往盘上写,不是失忆。真要把已经知道的也关掉,
            // 用户恰恰是在想问点私密事的时候拿到一个不认识他的助手,那这个开关只会没人用。
            memory: memory,
            // 写的那一头堵死:`remember` 在这条会话里根本不挂出去。
            capabilityRegistry: .healthChat(
                allowsMemoryWrites: !session.isPrivate,
                memoryStore: memoryStore,
                sessionStore: sessionStore,
                currentSessionId: session.id
            )
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

    /// 冷启动落在新对话上,不接着上次那条。
    ///
    /// 打开 app 的时候人多半是想问一件新的事。续上几天前那句「那第三天呢」,既要先读完
    /// 才知道自己在哪儿,想问新的还得再点一次「新对话」。上一条一条没丢,在会话列表里
    /// 一点就回得去。
    ///
    /// 代价是被系统回收之后再进来,不会自动回到刚才那条——换来的是每次进来都可预测。
    private func loadInitialSession() async {
        defer { isLoadingConversation = false }
        if EngineSettings.memoryEnabled {
            memory = await memoryStore.snapshot()
        }
        await refreshSummaries()
    }

    private func saveSession() async {
        // 空会话不落盘,否则每次点「新对话」都在列表里留一条空壳。
        // 隐私会话永远不落盘——这是它唯一的意义。会话文件是所有本机痕迹的源头:不落盘,
        // 会话列表、兴趣统计(`InterestProfile.build(from:)` 只数存下来的会话)就一并没有它。
        guard !session.isEmpty, !session.isPrivate else { return }
        session.updatedAt = Date()
        do {
            try await sessionStore.save(session)
        } catch {
            print("保存会话失败：\(error.localizedDescription)")
        }
        await refreshSummaries()
    }

    private func refreshSummaries() async {
        summaries = await sessionStore.summaries()
        // 同一次索引扫描的两个读者,一起刷。分两次去问 actor,列表和目标区就可能有一瞬
        // 对不上——刚删掉的那条线还在上面挂着。
        goals = await sessionStore.goals()
    }
}
