import SwiftUI
import AgentRuntime

struct ChatView: View {
    @Binding var openedCheckIn: CheckInLaunch?

    @State private var model = ChatViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(openedCheckIn: Binding<CheckInLaunch?> = .constant(nil)) {
        _openedCheckIn = openedCheckIn
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if model.isLoadingConversation {
                            ProgressView("正在载入对话")
                                .padding(.top, 40)
                        } else if model.messages.isEmpty {
                            WelcomeCard(
                                setupGuidance: model.engineGuidance,
                                questions: model.suggestions,
                                selectedTopic: model.session.topic,
                                onSelectTopic: model.selectTopic,
                                onSelectQuestion: model.send
                            )
                            .padding(.top, 24)
                            .id(Self.welcomeAnchor)
                            // 挂在卡片上而不是整个视图:只有真的要显示问题时才去生成,
                            // 挂 onAppear 会在会话还没载入完(此时 messages 是空的)就先跑一次。
                            .task { model.refreshSuggestionsIfNeeded() }
                        } else {
                            ForEach(model.messages) { message in
                                MessageBubble(
                                    message: message,
                                    isStreaming: model.isReplying
                                        && message.id == model.messages.last?.id,
                                    canRetry: model.canRetry(message.id),
                                    canBranch: !model.isReplying,
                                    onRetry: { model.retry(message.id) },
                                    onBranch: { model.branch(from: message.id) }
                                )
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
                // 有消息时贴底跟着流式内容走;空会话贴顶,否则欢迎卡会被压到屏幕底部。
                .defaultScrollAnchor(model.messages.isEmpty ? .top : .bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.messages) {
                    scroll(with: proxy)
                }
                // 换会话/开新会话时消息可能一样(两条空会话),得跟着 id 再归位一次。
                .onChange(of: model.session.id) {
                    scroll(with: proxy)
                }
            }
            .safeAreaInset(edge: .bottom) { inputBar }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Vana")
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

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            model.startNewSession()
                        } label: {
                            Label("新对话", systemImage: "square.and.pencil")
                        }

                        Button {
                            model.startNewSession(ephemeral: true)
                        } label: {
                            Label("临时对话（不保存）", systemImage: "eye.slash")
                        }
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .disabled(model.isReplying || model.messages.isEmpty)
                    .accessibilityLabel("新对话")
                }

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

    /// 滚到该看的地方:有消息就是最后一条,空会话就是欢迎卡顶部。
    private func scroll(with proxy: ScrollViewProxy) {
        let target: (id: AnyHashable, anchor: UnitPoint) = model.messages.last
            .map { (AnyHashable($0.id), UnitPoint.bottom) }
            ?? (AnyHashable(Self.welcomeAnchor), UnitPoint.top)

        if reduceMotion {
            proxy.scrollTo(target.id, anchor: target.anchor)
        } else {
            withAnimation(.smooth(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: target.anchor)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            // 开聊之后话题还留在提示词里,界面上也得看得见,否则用户不知道
            // 为什么模型一直在围着跑步说。
            if model.session.isEphemeral || (model.session.topic != nil && !model.messages.isEmpty) {
                HStack(spacing: 6) {
                    if let topic = model.session.topic, !model.messages.isEmpty {
                        Image(systemName: topic.icon)
                        Text("话题：\(topic.name)")
                    }
                    if model.session.isEphemeral {
                        Image(systemName: "eye.slash")
                        Text("临时对话，不会保存")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }

            messageField
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var messageField: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("问问你的健康数据…", text: $model.input, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { model.send() }
                .submitLabel(.send)
                .accessibilityLabel("消息")

            Button {
                if model.isReplying {
                    model.stopReply()
                } else {
                    model.send()
                }
            } label: {
                Image(systemName: model.isReplying ? "stop.fill" : "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(
                        model.isReplying ? Color(.systemRed) : Color.accentColor,
                        in: Circle()
                    )
            }
            .buttonStyle(.plain)
            .disabled(
                !model.isReplying
                    && (
                        model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || model.isLoadingConversation
                    )
            )
            .accessibilityLabel(model.isReplying ? "停止回复" : "发送")
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
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(minHeight: 32)
            .background(.fill.quaternary, in: Capsule())
            .contentShape(.capsule)
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
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(20)
            }
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
}

private struct MessageBubble: View {
    let message: ChatMessage
    /// 这条正在生成:生成期间不给操作按钮,retry 一条还没写完的回复没有意义。
    let isStreaming: Bool
    let canRetry: Bool
    let canBranch: Bool
    let onRetry: () -> Void
    let onBranch: () -> Void

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

    private var userMessage: some View {
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
                    Color.accentColor,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var assistantMessage: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            } else if !message.text.isEmpty || !isStreaming {
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
                Button(action: onRetry) {
                    Label("重试", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
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
                    .frame(width: 32, height: 32)
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
                .frame(width: 32, height: 32)
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
                    HStack(spacing: 6) {
                        Image(systemName: topic.icon)
                            .font(.caption)
                        Text(topic.name)
                            .font(.subheadline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(
                        isSelected
                            ? AnyShapeStyle(Color.accentColor)
                            : AnyShapeStyle(.fill.tertiary),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .contentShape(.rect)
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
                        .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 8))
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
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

#Preview {
    ChatView()
}
