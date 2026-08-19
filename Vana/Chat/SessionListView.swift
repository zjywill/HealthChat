import SwiftUI

/// 会话列表整屏盖上来,但是从**左边**进,不是从右边。
///
/// 入口那颗按钮在导航栏最左边,而 `NavigationLink` 的推入永远从右边来:手指点在左上角,
/// 东西却从对面飞过来,一次点击里方向就翻了一回。改成从按钮所在的那条边长出来之后,进、
/// 出、和往回收的手势是同一根轴,不用记。
///
/// 仍然是**整屏**:列表要放下目标区加四组按时间分的会话,留一条缝给下面的对话换不来什么,
/// 反而把每一行的标题挤短。
///
/// 代价是从此没有系统那条「从左边缘往右滑返回」的手势可用——那条手势的方向和这一屏的进出
/// 方向正好反着,留着它,同一根手指往右滑是退出、往左滑也是退出。所以收手势自己实现成
/// 往左滑(和它进来的方向反向),另外在原位留一颗关闭按钮。
struct SessionDrawer: View {
    @Binding var isPresented: Bool
    let model: ChatViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 收手势收到一半的位移。负值,夹在 `[-width, 0]`。
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if isPresented {
                    panel(width: geo.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // 动画挂在容器上而不是交给每个调用点 `withAnimation`:关闭有四个出口(关闭按钮、
        // 往左滑、选中一条会话、新建),漏掉任何一个都是它自己那一下没有动画。
        //
        // 减弱动效时换成淡入淡出:这套东西的意义就是那段位移,位移不能要的话,留一个更短的
        // 淡出比留一个更慢的位移诚实。
        .animation(
            reduceMotion ? .easeOut(duration: 0.18) : .snappy(duration: 0.32, extraBounce: 0.02),
            value: isPresented
        )
        // 收起来的时候这层是空的,但 `GeometryReader` 仍然铺满整屏——不摘掉命中测试,
        // 对话上的气泡和输入框会全部点不动。
        .allowsHitTesting(isPresented)
    }

    private func panel(width: CGFloat) -> some View {
        NavigationStack {
            SessionListView(model: model, onClose: close)
        }
        // 整屏不透明。少了这一层,推进来的那 0.3 秒里两屏内容会叠在一起。
        .background {
            Rectangle()
                .fill(Color(.systemGroupedBackground))
                .ignoresSafeArea()
        }
        // 影子压在朝向对话的那一侧,滑到一半时那条边就是「它盖在上面」这件事;浅色下两屏
        // 底色一样,没有它看着像内容自己换了。
        .shadow(color: .black.opacity(0.18), radius: 12, x: 2, y: 0)
        .offset(x: dragOffset)
        .gesture(closeDrag(width: width))
        .transition(.move(edge: .leading))
    }

    /// 往左滑收起来。
    ///
    /// 只认横向:列表本身在竖着滚,不先比一下两个方向的话,滑列表会顺手把这一屏拖走。
    /// 松手时看滑过的距离**加上甩的速度**——快速一甩不该因为只走了 40pt 就弹回去。
    private func closeDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                dragOffset = min(0, max(-width, value.translation.width))
            }
            .onEnded { value in
                let projected = value.translation.width + value.predictedEndTranslation.width
                if projected < -width * 0.35 {
                    close()
                } else {
                    withAnimation(.snappy(duration: 0.25)) { dragOffset = 0 }
                }
            }
    }

    private func close() {
        isPresented = false
        // 位移归零不带动画:这一屏正在往左滑出去,这时候再让它自己滑回 0,两个位移会打架。
        dragOffset = 0
    }
}

/// 会话列表:切换、新建、删除。按时间分段(今天 / 昨天 / 最近 7 天 / 更早)。
///
/// 由 `SessionDrawer` 从左边推进来,所以关闭走注进来的 `onClose` 而不是 `@Environment(\.dismiss)`
/// ——抽屉里那个 `NavigationStack` 的根就是这一层,`dismiss()` 在这儿什么都不做。
struct SessionListView: View {
    let model: ChatViewModel
    var onClose: () -> Void

    /// 成员切换器就挂在这一屏顶上:切成员 = 换一整个会话空间,那正是这一屏在说的事。
    /// 放 toolbar 的话,leading 那排已经有会话列表和用药表两颗,第三颗只会让它开始需要辨认。
    @Environment(TenantContext.self) private var tenants

    /// 列表打开时定一次「现在」。段的边界不该在用户滚动到一半时跳过去。
    @State private var now = Date()
    /// 正在起名字的那条线;新建时是 nil 加一个空标题。
    @State private var naming: GoalSummary?
    @State private var isNamingNewGoal = false
    @State private var draftName = ""

    /// 目标线的每一段都从下面按时间分的那几组里摘出去。
    ///
    /// 「减脂计划 · 8月9日起」既排在最上面的目标区、又混在「今天」里出现一遍,用户会以为
    /// 那是两条不同的东西。目标区已经把它整条管起来了。
    private var groups: [SessionTimeGroup] {
        let goalThreads = Set(model.goals.map(\.threadId))
        let loose = model.summaries.filter { summary in
            summary.threadId.map { !goalThreads.contains($0) } ?? true
        }
        return SessionTimeGroup.groups(from: loose, now: now)
    }

    var body: some View {
        List {
            tenantSection
            goalSection

            // 只剩目标线的时候下面这几组是空的,但那不叫"还没有会话"。
            if groups.isEmpty && model.goals.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("问一个健康问题，这里就会出现记录。")
                )
            } else {
                ForEach(groups) { group in
                    Section(group.section.title) {
                        ForEach(group.summaries) { summary in
                            Button {
                                model.openSession(id: summary.id)
                                onClose()
                            } label: {
                                row(for: summary, in: group.section)
                            }
                            .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    model.deleteSession(id: summary.id)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("会话")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 关闭落在**打开它的那颗按钮原来的位置**上:进出是同一个坐标,手指不用挪窝。
            // 不用 `chevron.left`——那个箭头是在说"要回去的东西在左边",而这一屏是从左边
            // 盖上来的,对话在它右边。方向说反了不如不说。
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("返回对话")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.startNewSession()
                        onClose()
                    } label: {
                        Label("新对话", systemImage: "square.and.pencil")
                    }
                    // 从输入区那颗 `+` 挪过来的:那颗现在管「给这句话加张照片」,而这两条是
                    // 「离开这条,开一条新的」——和会话列表是同一件事,本来就该在这儿。
                    Button {
                        model.startNewSession(isPrivate: true)
                        onClose()
                    } label: {
                        Label("隐私对话（不保存）", systemImage: "eye.slash")
                    }
                    Button {
                        draftName = ""
                        naming = nil
                        isNamingNewGoal = true
                    } label: {
                        Label("新目标", systemImage: "target")
                    }
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .disabled(model.isReplying)
                .accessibilityLabel("新建")
            }
        }
        .alert(isNamingNewGoal ? "新目标" : "改个名字", isPresented: isNamingPresented) {
            TextField("比如：减脂、备半马、把作息掰回来", text: $draftName)
            Button("取消", role: .cancel) { endNaming() }
            Button("好") {
                if let naming {
                    model.renameGoal(naming, to: draftName)
                } else {
                    model.startGoal(named: draftName)
                    // 起完名字直接进去问第一句。留在列表里再点一次,那条线还是空的。
                    if !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onClose()
                    }
                }
                endNaming()
            }
        } message: {
            Text("目标是一件要聊很久的事。之后每次回到它，都接着上次说。")
        }
        .onAppear { now = Date() }
    }

    private var isNamingPresented: Binding<Bool> {
        Binding(
            get: { isNamingNewGoal || naming != nil },
            set: { if !$0 { endNaming() } }
        )
    }

    private func endNaming() {
        isNamingNewGoal = false
        naming = nil
        draftName = ""
    }

    /// 成员那一行。**一行,不是一整段名单**。
    ///
    /// 切成员一天最多几次,而这一屏每天要开十几回——把三五位成员平铺在最上面,等于让最常
    /// 用的那件事(找一条会话)每次都先翻过一段几乎不变的内容。所以只留一行,顺带把「当前
    /// 是谁」摆在会话列表的最上面:进这一屏的人正要挑一条会话,而挑之前该先确认这是谁的列表。
    ///
    /// 迁移失败时(`isolationAvailable == false`)整行不出现:一个点进去不起作用的入口,
    /// 比没有这个入口糟。
    @ViewBuilder
    private var tenantSection: some View {
        if tenants.isolationAvailable {
            Section {
                NavigationLink {
                    TenantListView(context: tenants, onSelect: onClose)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                        Text("家庭成员")
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(tenants.current.displayName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minHeight: 44)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    /// 目标区。一条线一行,不管它已经分成几段。
    @ViewBuilder
    private var goalSection: some View {
        if !model.goals.isEmpty {
            Section("目标") {
                ForEach(model.goals) { goal in
                    Button {
                        model.openGoal(goal)
                        onClose()
                    } label: {
                        goalRow(goal)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            model.deleteGoal(goal)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button {
                            naming = goal
                            draftName = goal.title
                        } label: {
                            Label("改名", systemImage: "pencil")
                        }
                        .tint(.gray)
                    }
                }
            }
        }
    }

    private func goalRow(_ goal: GoalSummary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "target")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(goal.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // 分了几段是这条线的年龄,不是它的碎片数——说清楚它一直在往下走。
                Text(
                    """
                        \(SessionTimeSection.earlier.timeLabel(for: goal.updatedAt, now: now, calendar: .current))\
                         · \(goal.messageCount) 条消息
                        """
                        + (goal.segmentCount > 1 ? String(localized: " · \(goal.segmentCount) 段") : "")
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if goal.threadId == model.session.threadId {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(goal.threadId == model.session.threadId ? [.isButton, .isSelected] : .isButton)
    }

    private func row(for summary: SessionSummary, in section: SessionTimeSection) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(section.timeLabel(for: summary.updatedAt, now: now, calendar: .current)) · \(summary.messageCount) 条消息")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if summary.id == model.session.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(summary.id == model.session.id ? [.isButton, .isSelected] : .isButton)
    }
}
