import SwiftUI
import AgentRuntime

struct ChatView: View {
    @Binding var openedCheckIn: CheckInLaunch?

    @State private var model = ChatViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(openedCheckIn: Binding<CheckInLaunch?> = .constant(nil)) {
        _openedCheckIn = openedCheckIn
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    // 不是 Lazy。`LazyVStack` 对屏幕外的气泡只有估算高度,第一条滚出屏幕
                    // 被回收的那一刻真实高度换成估算值,整段内容高度变一下,贴着底的偏移
                    // 就跟着跳——"尤其是第一条消息"说的就是这个。
                    // 代价可控:一段会话最多几十条(`SessionThreadPolicy` 攒够 40 条就
                    // 另起一段),全量布局一次远比每帧猜错一次便宜。
                    VStack(spacing: 16) {
                        if model.isLoadingConversation {
                            ProgressView("正在载入对话")
                                .padding(.top, 40)
                        } else if model.messages.isEmpty {
                            // 锚点挂在整个首屏上,不是只挂欢迎卡:开新会话时归位归到
                            // 欢迎卡顶部的话,排在它上面的那段隐私说明正好被顶出屏幕。
                            VStack(spacing: 16) {
                                // 排在欢迎卡**前面**。挂在后面的话它落在一屏话题加一屏
                                // 建议之后,人点完开关根本看不到——而这段话正是这个开关的
                                // 全部内容。
                                if model.session.isPrivate {
                                    Self.privacyNote
                                }

                                WelcomeCard(
                                    setupGuidance: model.engineGuidance,
                                    questions: model.suggestions,
                                    selectedTopic: model.session.topic,
                                    onSelectTopic: model.selectTopic,
                                    onSelectQuestion: model.send
                                )
                            }
                            .padding(.top, 24)
                            .id(Self.welcomeAnchor)
                            // 挂在这儿而不是整个视图:只有真的要显示问题时才去生成,
                            // 挂 onAppear 会在会话还没载入完(此时 messages 是空的)就先跑一次。
                            .task { model.refreshSuggestionsIfNeeded() }
                        } else {
                            ForEach(model.messages) { message in
                                MessageBubble(
                                    // 正在写的那条不一定是最后一条了:用户能在回复期间接着
                                    // 发消息,那几条排在它后面。
                                    message: message,
                                    isStreaming: message.id == model.replyingMessageID,
                                    canRetry: model.canRetry(message.id),
                                    canBranch: !model.isReplying,
                                    onRetry: { model.retry(message.id) },
                                    onBranch: { model.branch(from: message.id) },
                                    onWithdraw: { model.withdrawQueued(message.id) }
                                )
                                    // 手写判等,见 `MessageBubble.==`。气泡带着闭包,
                                    // SwiftUI 自己判不了,于是流式期间整列气泡每帧全部
                                    // 重跑一遍 body——包括每条都重新解析一次 markdown。
                                    .equatable()
                                    .id(message.id)

                                if let folded = message.foldedSpan {
                                    CompactionDivider(artifact: folded)
                                }
                            }

                            // 退避重试期间界面上什么都不动的话,等十几秒和卡死没有区别。
                            if let notice = model.retryNotice {
                                Label(notice, systemImage: "arrow.trianglehead.2.clockwise")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .transition(.opacity)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
                // 三个角色分开写,别再合回一句 `.defaultScrollAnchor(.bottom)`——那一句
                // 等于把下面三件事一起交给系统,其中两件正好和贴底打架。
                //
                // 进来时落在哪儿:有消息就是最后一条,空会话贴顶(否则欢迎卡被压到屏幕底部)。
                .defaultScrollAnchor(model.messages.isEmpty ? .top : .bottom, for: .initialOffset)
                // 内容不满一屏时顶部对齐。底部对齐的话第一条消息贴着输入区,回复长出来时
                // 整段往上爬,而贴底又在同时改偏移,两边各推各的——那阵跳动就是这么来的。
                .defaultScrollAnchor(.top, for: .alignment)
                // 内容变高时系统不要动偏移。贴底这件事由下面那个 `onChange` 一家说了算:
                // 两套机制盯着同一段内容,谁都不知道对方已经推过一次了。
                .defaultScrollAnchor(nil, for: .sizeChanges)
                .scrollDismissesKeyboard(.interactively)
                // 输入区是浮在内容上的玻璃,内容从它下面过。软边让文字在那儿淡出,
                // 不然一行字会被硬生生切成两半。
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .onChange(of: scrollKey) { old, new in
                    // 新气泡出现是一次跳转,该有动画。其余都是内容自己长高,贴着走就行
                    // ——流式一秒几十次,每次再起一个 0.25 秒的动画,十几个叠在一起各自
                    // 朝一个已经过期的目标去,那就是抖动。
                    scroll(with: proxy, animated: new.messageCount != old.messageCount)
                }
                // 换会话/开新会话时消息可能一样(两条空会话),得跟着 id 再归位一次。
                .onChange(of: model.session.id) {
                    scroll(with: proxy, animated: true)
                }
            }
            .safeAreaInset(edge: .bottom) { ComposerBar(model: model) }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Vana")
            // 隐私是整条会话的属性,不是刚才点过的一个动作,所以它得一直在视线里。放在
            // 标题下面而不是 chip 排里:那排会随着开聊消失,而这条承诺要一直有效。
            .navigationSubtitle(model.session.isPrivate ? "隐私对话 · 不保存" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        SessionListView(model: model)
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .accessibilityLabel("会话列表")
                }

                // 「新对话 / 临时对话」只留输入区那颗 `+`:两个入口做同一件事,而且
                // toolbar 这颗在空会话时是 disabled 的,首屏永远挂着一个灰按钮。
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView(
                            canClearConversation: !model.messages.isEmpty && !model.isReplying,
                            onClearConversation: model.clearConversation
                        )
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .onAppear {
                model.refreshEngineAvailability()
            }
            // 多数会话是聊完直接切走的,不在这儿抽记忆,那段对话可能几天都轮不到抽一次。
            .onChange(of: scenePhase) { _, phase in
                guard phase == .background else { return }
                model.harvestCurrentSessionMemory()
            }
            .onChange(of: openedCheckIn) { _, checkIn in
                guard let checkIn else { return }
                model.open(checkIn)
                openedCheckIn = nil
            }
            .task {
                do {
                    try await HealthStore.shared.requestAuthorizationIfNeeded()
                } catch {
                    print("HealthKit 授权请求失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private static let welcomeAnchor = "welcome"

    /// 会改变内容高度的一切。贴底的触发信号。
    ///
    /// 不拿 `model.messages` 当信号:那要把整条会话深比较一遍,里面含 `storedTurn`
    /// (整份工具原文和逐小时序列),每帧比一遍纯属白干。
    ///
    /// 但也**不能只看正文长度**。回复写完的那一刻正文不再变,而这一帧里高度还在动:
    /// markdown 解析完把星号吃掉、复制那排按钮冒出来、重试提示消失、"正在回复"三个点
    /// 换成正文。少算一样,最后就差那么一截滚不到位——原来差的正是复制那排的高度。
    private struct ScrollKey: Equatable {
        var messageCount = 0
        var isReplying = false
        var hasRetryNotice = false
        var textLength = 0
        /// 思考**有没有**,不是有多长。
        ///
        /// 那颗 chip 是固定尺寸的,思考从 100 字长到 3000 字它一个像素都不动——按长度算的话,
        /// 思考模型每吐一个 token 都会换来一次 `scrollTo`,而 `scrollTo` 要把整列非 Lazy 的
        /// 气泡重新布一遍。真正改高度的只有「从无到有」那一下:chip 冒出来。
        var hasReasoning = false
        var toolCallCount = 0
        /// 已经出结果的工具数。chip 从转圈换成箭头,那一下也在改高度。
        var settledToolCallCount = 0
        /// 排队中的条数。它变的时候不只是多一个气泡:被取走的那条底下那行「Vana 还没看到」
        /// 会消失,整段跟着矮一截。
        var queuedCount = 0
    }

    private var scrollKey: ScrollKey {
        // 正在长高的是那条回复,不一定是最后一条——用户插话之后它后面还跟着几个气泡。
        let replying = model.replyingMessageID.flatMap { id in
            model.messages.last { $0.id == id }
        } ?? model.messages.last
        return ScrollKey(
            messageCount: model.messages.count,
            isReplying: model.isReplying,
            hasRetryNotice: model.retryNotice != nil,
            textLength: replying?.text.count ?? 0,
            hasReasoning: !(replying?.reasoning.isEmpty ?? true),
            toolCallCount: replying?.toolCalls.count ?? 0,
            settledToolCallCount: replying?.toolCalls.count { $0.output != nil } ?? 0,
            queuedCount: model.messages.count { $0.isQueued }
        )
    }

    /// 开着隐私对话、还没开口时说清楚它到底挡住了什么。
    ///
    /// 逐条列出来,而不是笼统一句「保护你的隐私」:这个功能的全部价值就是那句承诺可信,
    /// 而承诺只有具体到「不进哪儿」才可信。最后那句同样要紧——问题终究要发给云端模型才
    /// 有人回答,不说这一句,用户迟早会自己想到,那时候前面几条也跟着不算数了。
    @ViewBuilder
    private static var privacyNote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("这条对话不会被保存", systemImage: "eye.slash")
                .font(.subheadline.weight(.medium))
            Text("不进会话列表，不写进记忆，也不影响之后给你的建议。关掉就没了。")
            // 和上面两条同一个灰度。把这句压成最淡的一行,等于承认它是不想让人看见的
            // 小字——那正好毁掉了写它的意义。
            Text("能问的照样能问——健康数据还是照常查。只是问题本身仍然要发给你配置的模型才能回答，这一步隐私对话挡不住。")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.fill.quaternary, in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// 滚到该看的地方:有消息就是最后一条,空会话就是欢迎卡顶部。
    ///
    /// `animated` 由调用方决定,不是由 `reduceMotion` 一家说了算:贴着流式内容走本来就
    /// 不该有动画,那是"位置跟着内容",不是一次跳转。
    private func scroll(with proxy: ScrollViewProxy, animated: Bool) {
        let target: (id: AnyHashable, anchor: UnitPoint) = model.messages.last
            .map { (AnyHashable($0.id), UnitPoint.bottom) }
            ?? (AnyHashable(Self.welcomeAnchor), UnitPoint.top)

        if animated, !reduceMotion {
            withAnimation(.smooth(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }
        } else {
            proxy.scrollTo(target.id, anchor: target.anchor)
        }
    }

}

/// 折叠分隔线:从这里往上,模型记得的只有一句摘要,不再是逐字的对话。
///
/// 界面上的消息一条没少——压缩只发生在发给模型的那一份里。但用户得知道模型的记忆到哪儿
/// 为止,否则"你刚才不是说过吗"会变成一次莫名其妙的对话。
private struct CompactionDivider: View {
    let artifact: CompactionArtifact

    private var countText: String { "以上 \(artifact.sourceMessageIDs.count) 条已折叠" }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                rule
                Text(countText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .layoutPriority(1)
                rule
            }

            if !artifact.visibleSummary.isEmpty {
                Text(artifact.visibleSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(countText)。\(artifact.visibleSummary)")
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 1)
    }
}

/// 模型思考的入口。和工具那颗 chip 一样,点开是一个面板。
///
/// 思考不是答案。摊在对话流里,几百字的推演会把真正的回答推到屏幕外面去,而且它每一轮
/// 都在长——列表跟着抖。想看的人点一下,不看的人只看到一颗 chip。
private struct ReasoningChip: View {
    let text: String
    /// 还在吐思考。
    let isThinking: Bool

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "brain")
                Text(isThinking ? "正在思考…" : "思考过程")
                if isThinking {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                }
            }
            .inlineChipStyle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isThinking ? "正在思考" : "思考过程")
        .accessibilityHint("打开模型的思考过程")
        .sheet(isPresented: $isPresented) {
            ReasoningPanel(text: text, isThinking: isThinking)
        }
    }
}

/// 从底部弹出的思考面板。开着的时候还在想,内容跟着长。
private struct ReasoningPanel: View {
    let text: String
    let isThinking: Bool

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                thought.padding(20)
            }
            // 内容长出来时贴着底走:开着面板就是想看它**现在**在想什么,而不是盯着开头那段
            // 不动,新的字全长在屏幕外面。
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(isThinking ? "正在思考" : "思考过程")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// 还在想的时候**不挂** `.textSelection`(默认就是不可选)。
    ///
    /// 可选文本走的是另一条明显更重的排版路径,而这段每秒要重排十几次;何况正在动的文字
    /// 本来也选不住。想完了再挂上——那时候它一个字都不会再变了。
    @ViewBuilder
    private var thought: some View {
        let body = Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

        if isThinking {
            body
        } else {
            body.textSelection(.enabled)
        }
    }
}

private struct MessageBubble: View, Equatable {
    let message: ChatMessage
    /// 这条正在生成:生成期间不给操作按钮,retry 一条还没写完的回复没有意义。
    let isStreaming: Bool
    let canRetry: Bool
    let canBranch: Bool
    let onRetry: () -> Void
    let onBranch: () -> Void
    let onWithdraw: () -> Void

    /// 只比画出来会不一样的东西。
    ///
    /// 两个闭包让 SwiftUI 判不了等,于是流式期间上面那二三十条早就定稿的气泡每帧陪着
    /// 重跑一遍 body。闭包捕获的只有 `message.id` 和 view model,判等时忽略它们是安全的
    /// ——不重跑 body 时留在手里的那份捕获的仍然是同一个 id。
    ///
    /// 也顺手绕开 `ChatMessage` 自动合成的 `==`:那里面有 `storedTurn`,整份工具原文加
    /// 每份 `HealthReport` 的逐小时序列,而界面上一个字都不显示。
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isStreaming == rhs.isStreaming
            && lhs.canRetry == rhs.canRetry
            && lhs.canBranch == rhs.canBranch
            && lhs.message.rendersIdentically(to: rhs.message)
    }

    private var isWaiting: Bool {
        isStreaming && message.text.isEmpty && message.reasoning.isEmpty
    }

    @ViewBuilder
    var body: some View {
        if message.role == .user {
            userMessage
        } else {
            assistantMessage
        }
    }

    /// 用户的气泡。排队中的那几条淡一档,底下补一句说清它到底怎么了。
    ///
    /// 「Vana 还没看到」写得这么直白是有原因的:排队和已送达在屏幕上是同一个气泡,而猜错的
    /// 那个方向恰好是最糟的——以为说过了,其实没说。写「发送中」会让人以为只是慢一点,
    /// 而它可能一直排到这一轮结束。
    private var userMessage: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 0) {
                Spacer(minLength: 52)

                Text(displayText)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityLabel(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isQueued ? Color.accentColor.opacity(0.45) : Color.accentColor,
                        in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                    )
                    .layoutPriority(1)
            }

            if message.isQueued {
                Label("Vana 还没看到", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("这条还在排队，Vana 还没看到")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .contextMenu {
            if message.isQueued {
                // 只有排队中的能收回。已经发出去的那句模型已经看过了,从列表里抹掉它只会让
                // 屏幕上的对话和模型记得的对话对不上。
                Button(role: .destructive, action: onWithdraw) {
                    Label("收回", systemImage: "arrow.uturn.backward")
                }
            }
        }
    }

    private var assistantMessage: some View {
        // 6 而不是 8:chip 自己带了撑到 44 的点击区,间距再按 8 算,几颗 chip 摞起来会散。
        VStack(alignment: .leading, spacing: 6) {
            if !message.reasoning.isEmpty {
                ReasoningChip(
                    text: message.reasoning,
                    isThinking: isStreaming && message.text.isEmpty
                )
            }

            ForEach(message.toolCalls) { call in
                ToolCallChip(call: call)
            }

            if isWaiting {
                TypingIndicator()
            // 一个字都没说完就被插话劈开的前半段,留着思考和工具 chip 就够了——那儿再挂一个
            // "…" 会让人以为模型说了句什么没看清。真的整条空白才用它顶位。
            } else if !message.text.isEmpty || (!isStreaming && !message.hasVisibleTurnContent) {
                Text(displayText)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityLabel(message.text)
            }

            // 查询次数用光时这一轮是正常收尾的(该查的多半已经查到),但模型是被打断的,
            // 得说一声,否则用户只看到它说到一半自己停了。
            if message.stoppedAtToolRoundLimit {
                Text("这个问题需要的查询次数超出了单轮上限，缩小范围再问一次会更完整。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if message.errorDescription != nil, canRetry {
                // 用 bordered 不用 glass:它跟着对话一起滚,不是浮在内容上的那一层。
                // 见 `inlineChipStyle` 里那条边界。
                Button(action: onRetry) {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 30)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityHint("重新发送上一条问题")
            } else if !isStreaming, !message.text.isEmpty {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 复制放在外面——它是最常用的那个,不值得多点一下。
    /// 重新回答、分支和这条的时间收进菜单:都是低频操作,平时不该占着屏幕。
    private var actions: some View {
        HStack(spacing: 2) {
            CopyButton(text: message.text)

            Menu {
                if let createdAt = message.createdAt {
                    Section(createdAt.formatted(date: .abbreviated, time: .shortened)) {
                        menuItems
                    }
                } else {
                    menuItems
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .accessibilityLabel("更多操作")
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button(action: onRetry) {
            Label("重新回答", systemImage: "arrow.clockwise")
        }
        .disabled(!canRetry)

        Button(action: onBranch) {
            Label("在新对话里分支", systemImage: "arrow.triangle.branch")
        }
        .disabled(!canBranch)
    }

    private var displayText: AttributedString {
        let text = message.text.isEmpty ? "…" : message.text
        guard message.role == .assistant else {
            return AttributedString(text)
        }
        // 只解析行内语法并保留空白:.full 会按 CommonMark 把单换行折叠掉,
        // 模型列的每日数据于是糊成一坨("22:26–05:19" 直接粘上下一行的日期)。
        return (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// 复制回复正文。点完图标变对勾,不弹 toast——这种小反馈就地给最省事。
private struct CopyButton: View {
    let text: String

    @State private var hasCopied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation(.smooth(duration: 0.15)) { hasCopied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation(.smooth(duration: 0.15)) { hasCopied = false }
            }
        } label: {
            Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                .font(.footnote)
                .foregroundStyle(hasCopied ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(hasCopied ? "已复制" : "复制回复")
    }
}

/// 模型还没吐出第一个字时的等待态。
///
/// 原来是一个静止的"…",跟一条真的只写了省略号的回复长得一模一样,看不出在动。
private struct TypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAnimating = false

    var body: some View {
        Group {
            if reduceMotion {
                Text("正在回复…")
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .frame(width: 7, height: 7)
                            .opacity(isAnimating ? 1 : 0.25)
                            .animation(
                                .easeInOut(duration: 0.55)
                                    .repeatForever(autoreverses: true)
                                    .delay(Double(index) * 0.18),
                                value: isAnimating
                            )
                    }
                }
                .foregroundStyle(.secondary)
                .onAppear { isAnimating = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 22)
        .accessibilityLabel("正在回复")
    }
}

/// 新会话选话题。选中的话题会写进系统提示,决定模型先看哪些数据。
///
/// 再点一次取消选择——选错了不该只能重开一条会话。
private struct TopicPicker: View {
    let selected: ChatTopic?
    let onSelect: (ChatTopic?) -> Void

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(ChatTopics.all) { topic in
                let isSelected = topic.id == selected?.id

                Button {
                    onSelect(isSelected ? nil : topic)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: topic.icon)
                            .font(.caption)
                        Text(topic.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            // 一格宽 104,「高强度间歇」这种五个字的名字缩到 0.75 才进得去。
                            // 缩字比截断好:截成「高强度…」等于没说是哪个话题。
                            .minimumScaleFactor(0.75)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 12)
                    // 胶囊,和输入区上面那颗话题 chip 同一个样子:同一件事在一屏里出现
                    // 两种长相,用户会以为它们不是一回事。
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.fill.tertiary),
                        in: .capsule
                    )
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("话题：\(topic.name)")
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

private struct WelcomeCard: View {
    let setupGuidance: String?
    let questions: [SuggestedQuestion]
    let selectedTopic: ChatTopic?
    let onSelectTopic: (ChatTopic?) -> Void
    let onSelectQuestion: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "heart.text.square.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.pink)
                    .accessibilityHidden(true)

                Text("从你的健康数据开始")
                    .font(.title2.weight(.semibold))

                Text("你可以直接询问步数、睡眠、心率、锻炼、体重体脂，以及血压、血氧这类有记录才有的数据。Vana 只读取你授权的数据，不会修改健康记录。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("想聊什么")
                    .font(.headline)

                TopicPicker(selected: selectedTopic, onSelect: onSelectTopic)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("试着问")
                    .font(.headline)

                ForEach(questions) { question in
                    Button {
                        onSelectQuestion(question.text)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: question.icon)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 24)

                            // 一行放不下就缩字号,不换行——换行会把三张卡撑得参差不齐。
                            Text(question.text)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)

                            Spacer(minLength: 8)

                            Image(systemName: "arrow.up")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .padding(.horizontal, 12)
                        .background(
                            .fill.tertiary,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("提问：\(question.text)")
                }
            }

            Label("健康分析仅供参考，不能替代专业医疗建议。", systemImage: "lock.shield")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let setupGuidance {
                Label(setupGuidance, systemImage: "gearshape")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        // 圆角分三档:大容器 20、卡片里的行 12、气泡 18,chip 和控件一律胶囊。
        // 之前从卡片到行到格子全是 8,一张六百多点高的卡片配这个圆角在 iOS 26 里太方了。
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ChatView()
}
