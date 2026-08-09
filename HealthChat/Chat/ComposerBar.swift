import SwiftUI

/// 底部输入区:一颗玻璃胶囊装下输入框和它的动作,快捷 chip 浮在它上方。
///
/// 整块是浮在对话上的玻璃,不是压着对话的一条不透明工具栏——iOS 26 的底部输入区都是这样,
/// 内容从它下面透出来,用户才看得出自己没滚到底。
struct ComposerBar: View {
    @Bindable var model: ChatViewModel

    @FocusState private var isFocused: Bool

    /// 比单行时的半高还大,SwiftUI 会自己夹到胶囊;长成多行之后才真的当成 26 的圆角用。
    private static let cardRadius: CGFloat = 26

    /// 开聊之后的追问快捷。
    ///
    /// 只在有消息时出现:空会话的快捷输入是欢迎卡里那几条建议,在这儿再放一遍是重复。
    /// 这几句短到一个 chip 放得下,而且都是「接着上一句问」的问法——追问真正的成本是
    /// 打字,不是想不出问什么。
    private static let followUps = ["详细一点", "有什么建议？", "和上周比呢？", "可能是什么原因？"]

    var body: some View {
        VStack(spacing: 8) {
            // chip 那排自己贴到屏幕两边:横向滚动的东西在离边 12pt 处被切断,看着像是
            // 排版错了而不是「右边还有」。
            quickRow
            card.padding(.horizontal, 12)
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    // MARK: - 快捷 chip

    @ViewBuilder
    private var quickRow: some View {
        // 正在回复时全部收起来:这时候点哪个都只会排到后面去,留着只是一排点不动的东西。
        if !model.isReplying {
            ScrollView(.horizontal) {
                // 一个容器里的玻璃互相认识:靠近时会融到一起,而不是各糊各的背景。
                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        goalChip
                        topicChip
                        privacyChip

                        if !model.messages.isEmpty {
                            ForEach(Self.followUps, id: \.self) { question in
                                Button {
                                    model.send(question)
                                } label: {
                                    ChipLabel(icon: nil, title: question, isOn: false)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("追问：\(question)")
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .scrollIndicators(.hidden)
            .transition(.opacity)
        }
    }

    /// 正在哪条目标线里。
    ///
    /// 只显示,不可点:换目标是换一件事,该回列表里挑,不是在输入框上方顺手切掉。用户得
    /// 一眼看见这句话会落进哪条线——尤其是刚从列表点进来、屏幕上还什么都没有的时候。
    @ViewBuilder
    private var goalChip: some View {
        if model.session.thread?.isGoal == true {
            ChipLabel(
                icon: "target",
                title: model.session.threadTitle ?? SessionThread.goal(UUID()).title,
                isOn: true
            )
            .accessibilityLabel("目标：\(model.session.threadTitle ?? "长期目标")")
        }
    }

    /// 话题。会话还空着时是个可选的菜单,开聊之后只剩显示——中途换话题,前面的上下文就
    /// 对不上了(`selectTopic` 本身也拦着)。
    ///
    /// 目标线不给话题:那条线本来就是横跨好几个话题的一件事,而话题一旦写进 system 段,
    /// 聊到第三段就和正在问的事对不上了(同 `ChatViewModel.open`)。
    @ViewBuilder
    private var topicChip: some View {
        if model.session.thread?.isGoal == true {
            EmptyView()
        } else if model.messages.isEmpty {
            Menu {
                Button {
                    model.selectTopic(nil)
                } label: {
                    Label("不限话题", systemImage: "circle.dashed")
                }

                Section("运动") {
                    ForEach(ChatTopics.workouts) { topic in
                        Button {
                            model.selectTopic(topic)
                        } label: {
                            Label(topic.name, systemImage: topic.icon)
                        }
                    }
                }

                Section("指标") {
                    ForEach(ChatTopics.metrics) { topic in
                        Button {
                            model.selectTopic(topic)
                        } label: {
                            Label(topic.name, systemImage: topic.icon)
                        }
                    }
                }
            } label: {
                ChipLabel(
                    icon: model.session.topic?.icon ?? "text.bubble",
                    title: model.session.topic?.name ?? "话题",
                    isOn: model.session.topic != nil
                )
            }
            // Menu 会拿 tint 给 label 上色,盖过 chip 自己的前景色——不改的话没选话题
            // 的 chip 也是一颗蓝的,和「已选中」长得一样。
            .tint(model.session.topic == nil ? Color.secondary : Color.accentColor)
            .accessibilityLabel("话题：\(model.session.topic?.name ?? "不限")")
        } else if let topic = model.session.topic {
            ChipLabel(icon: topic.icon, title: topic.name, isOn: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("话题：\(topic.name)")
        }
    }

    /// 隐私对话开关。**只在会话还空着时出现**。
    ///
    /// 开聊之后这颗就整个消失,不留一条不可点的说明文字:那条文字长得和旁边的追问 chip
    /// 一模一样,点不动只会让人以为坏了。开聊之后的状态归导航栏副标题
    /// (`ChatView`),那是整条会话的属性,本来就该一直挂在那儿,而不是混在一排动作里。
    ///
    /// 开关本身也只在空会话时能动:说好不存就是不存,不给中途推翻的机会。
    @ViewBuilder
    private var privacyChip: some View {
        if model.messages.isEmpty {
            Button {
                model.setPrivate(!model.session.isPrivate)
            } label: {
                // 用 eye.slash 而不是 lock:锁在这个语境里读作「加密了」,而这一句照样
                // 要发给云端模型。图标也是承诺的一部分,不能替文案吹一个做不到的牛。
                ChipLabel(
                    icon: "eye.slash",
                    title: "隐私",
                    isOn: model.session.isPrivate
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("隐私对话，不保存这条对话")
            .accessibilityAddTraits(model.session.isPrivate ? [.isButton, .isSelected] : .isButton)
        }
    }

    // MARK: - 输入卡片

    /// 平时是一行:加号、输入框、发送,空着的时候就是一颗胶囊。
    ///
    /// 长到三行就换成上下两层,输入框独占一整幅宽度,按钮沉到底边:粘一整段病历进来的时候,
    /// 夹在两颗按钮中间的那一栏只有七成宽,同样的字要多占两行,还越读越窄。
    ///
    /// 两种排法走同一个 `Layout`,不是 `if` 出两棵树:`if` 换支的那一下输入框会被拆了
    /// 重建,焦点跟着没,重建之后敲进去的字直接掉在地上——打到第三行正好触发,再打就没了。
    private var card: some View {
        ComposerLayout(isStacked: isStacked) {
            moreMenu
            field
            sendButton
        }
        .animation(.smooth(duration: 0.2), value: isStacked)
        .padding(.horizontal, 4)
        .padding(.bottom, isStacked ? 4 : 0)
        // iOS 26 的底部输入区是浮在内容上的玻璃,不是压在内容上的一条不透明工具栏:
        // 对话往上滚的时候从它下面透出来,用户才知道自己没滚到底。
        .glassEffect(.regular, in: .rect(cornerRadius: Self.cardRadius, style: .continuous))
        // 卡片比输入框大一圈,点空白处理应也能落进输入框。
        .contentShape(.rect(cornerRadius: Self.cardRadius, style: .continuous))
        .onTapGesture { isFocused = true }
    }

    /// 输入框本体。
    ///
    /// `lineLimit(1...6)` 是给超长粘贴兜底的那一档:到第六行就不再长,里面自己滚。没有它
    /// 的话粘一篇文章进来,输入框会一路顶到屏幕顶上,对话一条都看不见。
    private var field: some View {
        TextField("问问你的健康数据…", text: $model.input, axis: .vertical)
            .lineLimit(1...6)
            .focused($isFocused)
            .submitLabel(.send)
            .onSubmit { model.send() }
            .padding(.vertical, 13)
            .accessibilityLabel("消息")
    }

    /// 换不换排,只看这段文字本身,不看输入框量出来多高。
    ///
    /// 量高度那版会绕回来:高度决定排版,排版决定输入框有多宽,宽度又决定高度。SwiftUI
    /// 在这个环里会拿着一份过期的行数排版,粘进来的长文有一半根本不显示。
    ///
    /// 汉字按两格宽估:窄排下一行大约 34 格,超过两行就铺开。估得不精准没关系——排版选错
    /// 的代价是这一段窄了点,而 `lineLimit` 那道上限一直都在。
    private var isStacked: Bool {
        if model.input.contains("\n") { return true }

        var width = 0
        for scalar in model.input.unicodeScalars {
            width += scalar.value > 0x2E80 ? 2 : 1
            if width > 68 { return true }
        }
        return false
    }

    private var moreMenu: some View {
        Menu {
            Button {
                model.startNewSession()
            } label: {
                Label("新对话", systemImage: "square.and.pencil")
            }
            .disabled(model.messages.isEmpty)

            // 两条都是「离开这条，开一条新的」,所以停用条件也一样。空会话时想切隐私走
            // chip:菜单这条会连话题一起清掉,而那时候人多半刚选完话题。
            Button {
                model.startNewSession(isPrivate: true)
            } label: {
                Label("隐私对话（不保存）", systemImage: "eye.slash")
            }
            .disabled(model.messages.isEmpty)
        } label: {
            RoundIcon(
                systemName: "plus",
                foreground: AnyShapeStyle(.secondary),
                background: AnyShapeStyle(.fill.tertiary)
            )
        }
        .tint(Color.secondary)
        .disabled(model.isReplying)
        .accessibilityLabel("更多")
    }

    private var sendButton: some View {
        let isDisabled = !model.isReplying
            && (
                model.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || model.isLoadingConversation
            )

        return Button {
            if model.isReplying {
                model.stopReply()
            } else {
                model.send()
            }
        } label: {
            RoundIcon(
                systemName: model.isReplying ? "stop.fill" : "arrow.up",
                foreground: AnyShapeStyle(isDisabled ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white)),
                background: model.isReplying
                    ? AnyShapeStyle(Color(.systemRed))
                    : (isDisabled ? AnyShapeStyle(.fill.tertiary) : AnyShapeStyle(Color.accentColor))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(model.isReplying ? "停止回复" : "发送")
    }
}

/// 加号、输入框、发送三样东西的两种排法。
///
/// 写成 `Layout` 而不是两个 `HStack`/`VStack` 分支,是为了让这三个视图从头到尾是同一份:
/// 换排的时候输入框不重建,焦点、选区、正在输入的拼音都还在。
private struct ComposerLayout: Layout {
    /// 铺开排:输入框独占一整幅宽度在上,两颗按钮沉到底边。
    var isStacked: Bool
    var spacing: CGFloat = 4
    /// 铺开时输入框两侧留的空,让文字和下面那颗加号对不齐得不难看。
    var stackedInset: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: metrics(width: width, subviews: subviews).height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let m = metrics(width: bounds.width, subviews: subviews)
        let fieldProposal = ProposedViewSize(width: m.fieldWidth, height: m.fieldHeight)

        subviews[0].place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY),
            anchor: .bottomLeading,
            proposal: ProposedViewSize(m.plus)
        )
        subviews[2].place(
            at: CGPoint(x: bounds.maxX, y: bounds.maxY),
            anchor: .bottomTrailing,
            proposal: ProposedViewSize(m.send)
        )
        subviews[1].place(
            at: isStacked
                ? CGPoint(x: bounds.minX + stackedInset, y: bounds.minY)
                : CGPoint(x: bounds.minX + m.plus.width + spacing, y: bounds.maxY),
            anchor: isStacked ? .topLeading : .bottomLeading,
            proposal: fieldProposal
        )
    }

    private struct Metrics {
        var plus: CGSize
        var send: CGSize
        var fieldWidth: CGFloat
        var fieldHeight: CGFloat
        var height: CGFloat
    }

    private func metrics(width: CGFloat, subviews: Subviews) -> Metrics {
        let plus = subviews[0].sizeThatFits(.unspecified)
        let send = subviews[2].sizeThatFits(.unspecified)
        let buttons = max(plus.height, send.height)

        let fieldWidth = max(
            0,
            isStacked
                ? width - stackedInset * 2
                : width - plus.width - send.width - spacing * 2
        )
        // 高度让输入框自己说了算:它内部有 lineLimit 的上限,到第六行就不再长。
        let fieldHeight = subviews[1]
            .sizeThatFits(ProposedViewSize(width: fieldWidth, height: nil))
            .height

        return Metrics(
            plus: plus,
            send: send,
            fieldWidth: fieldWidth,
            fieldHeight: fieldHeight,
            height: isStacked ? fieldHeight + spacing + buttons : max(buttons, fieldHeight)
        )
    }
}

/// 卡片底边那两颗圆钮。画到 34,点得到 44——图标再大就把卡片撑高了,但手指够不到的
/// 按钮等于没有。
private struct RoundIcon: View {
    let systemName: String
    let foreground: AnyShapeStyle
    let background: AnyShapeStyle

    var body: some View {
        Image(systemName: systemName)
            .font(.subheadline.weight(.bold))
            .foregroundStyle(foreground)
            .frame(width: 34, height: 34)
            .background(background, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(.rect)
    }
}

private struct ChipLabel: View {
    var icon: String?
    let title: String
    let isOn: Bool

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
            }
            Text(title)
                .font(.subheadline)
                .lineLimit(1)
        }
        .foregroundStyle(isOn ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 14)
        .frame(height: 38)
        // 选中的那颗染成主色玻璃,不是换一层不透明底色:同一排东西一半玻璃一半实心,
        // 看着像两套控件。
        .glassEffect(
            isOn ? .regular.tint(Color.accentColor).interactive() : .regular.interactive(),
            in: .capsule
        )
        .contentShape(.capsule)
    }
}
