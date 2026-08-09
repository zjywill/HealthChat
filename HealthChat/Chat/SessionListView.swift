import SwiftUI

/// 会话列表:切换、新建、删除。按时间分段(今天 / 昨天 / 最近 7 天 / 更早)。
struct SessionListView: View {
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss

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
                                dismiss()
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
            Menu {
                Button {
                    model.startNewSession()
                    dismiss()
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
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
                        dismiss()
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

    /// 目标区。一条线一行,不管它已经分成几段。
    @ViewBuilder
    private var goalSection: some View {
        if !model.goals.isEmpty {
            Section("目标") {
                ForEach(model.goals) { goal in
                    Button {
                        model.openGoal(goal)
                        dismiss()
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
                    "\(SessionTimeSection.earlier.timeLabel(for: goal.updatedAt, now: now, calendar: .current))"
                        + " · \(goal.messageCount) 条消息"
                        + (goal.segmentCount > 1 ? " · \(goal.segmentCount) 段" : "")
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
