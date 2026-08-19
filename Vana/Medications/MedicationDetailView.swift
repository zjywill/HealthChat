import SwiftUI

/// 一条的详情。
///
/// 排序上有一处是有意的:**他自己的评价排在自动生成的一般说明前面**。一般说明网上到处都是,
/// 模型随时能重写一遍;「我试了两周没感觉」只有他知道,而且正是它决定了下次该不该再提这个
/// 东西。反过来排,这一页读起来就像一份药品说明书,而那不是这张表存在的理由。
struct MedicationDetailView: View {
    let item: MedicationItem
    let onEdit: (MedicationItem) -> Void
    let onDelete: (MedicationItem) -> Void
    let onAsk: (MedicationItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var current: MedicationItem?
    @State private var isShowingDeleteConfirmation = false
    @State private var isRegenerating = false
    @State private var didFailToRegenerate = false

    private var shown: MedicationItem { current ?? item }

    var body: some View {
        Form {
            Section {
                // 不用 `LabeledContent { Label }`:把一个带图标的 `Label` 塞进它的 content,
                // Form 会按多行布局给它留出一大块空白。
                HStack {
                    Text("关系")
                    Spacer()
                    Label(shown.status.title, systemImage: shown.status.icon)
                        .foregroundStyle(shown.status == .cannotTake ? Color.red : Color.secondary)
                }
                if !shown.when.isEmpty { LabeledContent("什么情况下吃", value: shown.when) }
                if !shown.reason.isEmpty { LabeledContent("为什么吃", value: shown.reason) }
                if let startedAt = shown.startedAt {
                    LabeledContent("开始时间", value: startedAt.formatted(.dateTime.year().month().day()))
                }
            } footer: {
                Text(origin(shown))
            }

            Section {
                if shown.outcome.isEmpty {
                    Text("还没记。有没有用、有什么感觉，记一句，Vana 下次就不会再推荐一次你试过的东西。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(shown.outcome)
                }
            } header: {
                Text("你自己的评价")
            }

            if let followUpAt = shown.followUpAt {
                Section {
                    Label(
                        followUpAt <= Date()
                            ? "说好回头看的时间到了"
                            : String(localized: "\(followUpAt.formatted(.dateTime.month().day())) 回头问你一句"),
                        systemImage: "clock.arrow.circlepath"
                    )
                    .foregroundStyle(followUpAt <= Date() ? Color.orange : Color.secondary)
                }
            }

            Section {
                if shown.brief.isEmpty {
                    Text("还没有说明。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text(shown.brief)
                        // 换的是同一段话的新写法,不是来了个新东西,所以是交叉淡入不是滑入。
                        .contentTransition(.opacity)
                        // 正在重写的那两秒里,旧的这段读起来仍然像是当前的说明。压暗它,
                        // 用户才知道自己在等什么被换掉。
                        .opacity(isRegenerating ? 0.35 : 1)
                        .animation(.easeInOut(duration: 0.2), value: isRegenerating)
                        .animation(.easeInOut(duration: 0.25), value: shown.brief)
                }

                Button {
                    regenerate()
                } label: {
                    // 反馈落在手指刚点的那个位置上。整段文字在两秒里一动不动、按钮却已经
                    // 变灰,读起来就是"点了没反应"——而它其实正在跑。
                    Group {
                        if isRegenerating {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在写…")
                            }
                        } else {
                            Label("重新生成", systemImage: "arrow.clockwise")
                        }
                    }
                    // 动画**只挂在会动的这几处**,不用 `withAnimation` 包状态赋值。
                    //
                    // 这不是风格选择:一次全局 transaction 会把整个更新扫一遍,包括这张
                    // sheet 里的 `NavigationStack`——闭包式 destination 的 `NavigationLink`
                    // 会在那一下被丢掉,表现是点「重新生成」当场弹回列表页。
                    .animation(.easeInOut(duration: 0.2), value: isRegenerating)
                }
                // 用户改过的不许被一次点击盖掉——他改成那样就是不认同模型的说法。
                .disabled(isRegenerating || shown.briefIsUserWritten)

                // 这一颗是用户自己点的,失败不能像后台那次一样静默放弃(`MedicationBriefer.fill`
                // 的默认行为)。他点了、等了、什么都没变,而屏幕上没有一个字解释为什么。
                if didFailToRegenerate {
                    Label("这次没写出来。检查一下网络，或者设置里的模型配置。", systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("一般说明")
            } footer: {
                Text(shown.briefIsUserWritten
                    ? "这一段你自己改过，不会被自动覆盖。要恢复自动生成，把它清空再保存。"
                    : "由 Vana 自动写的通用说明，不是给你的建议，也不含剂量和用法。")
            }

            if !shown.note.isEmpty {
                Section("备注") { Text(shown.note) }
            }

            Section {
                Button {
                    onAsk(shown)
                } label: {
                    Label("问问 Vana", systemImage: "bubble.left.and.text.bubble.right")
                }
            } footer: {
                Text("会开一条围绕「\(shown.name)」的对话，下次从这里进来还接着上次那条聊。")
            }

            Section {
                Button(role: .destructive) {
                    isShowingDeleteConfirmation = true
                } label: {
                    // `role: .destructive` 只染文字,图标还跟着 accent 走——一个蓝色垃圾桶
                    // 配一行红字,看着像没做完。
                    Label("删掉这条", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { onEdit(shown) }
            }
        }
        .confirmationDialog(
            "删掉「\(shown.name)」？",
            isPresented: $isShowingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删掉", role: .destructive) {
                onDelete(shown)
                dismiss()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(shown.status == .cannotTake
                ? "删掉之后 Vana 就不知道你不能吃它了，给建议时也不会再避开。"
                : "只删这条记录，不影响「健康」App 里的任何数据。")
        }
        // 编辑完回到这一页时要显示新的。父视图手里那份是打开时的快照。
        .task(id: item.id) { await reload() }
    }

    /// 每条都要能回答「这句哪来的」(同 `MemoryView.subtitle`)。
    private func origin(_ item: MedicationItem) -> String {
        var parts: [String]
        switch item.origin {
        case .manual: parts = [String(localized: "你自己加的")]
        case .asked: parts = [String(localized: "你在对话里让我记的")]
        case .health: parts = [String(localized: "来自「健康」App")]
        }
        parts.append(item.updatedAt.formatted(.relative(presentation: .named)))
        return parts.joined(separator: " · ")
    }

    /// 三个状态一次落地,不走「跑完 → onChange → 再去读盘」那条链。
    ///
    /// 分两跳的话,按钮先恢复、文字过一两帧才换,中间那一下正好是最扎眼的:用户已经看到按钮
    /// 活了,而屏幕上还是旧的那句话。读完盘再一起动,只有一次变化。
    private func regenerate() {
        isRegenerating = true
        didFailToRegenerate = false
        Task {
            let wrote = await MedicationBriefer.fill(shown)
            let latest = await MedicationStore.shared.item(named: item.name)
            current = latest
            didFailToRegenerate = !wrote
            isRegenerating = false
        }
    }

    private func reload() async {
        current = await MedicationStore.shared.item(named: item.name)
    }
}
