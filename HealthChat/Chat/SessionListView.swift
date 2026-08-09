import SwiftUI

/// 会话列表:切换、新建、删除。按时间分段(今天 / 昨天 / 最近 7 天 / 更早)。
struct SessionListView: View {
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss

    /// 列表打开时定一次「现在」。段的边界不该在用户滚动到一半时跳过去。
    @State private var now = Date()

    private var groups: [SessionTimeGroup] {
        SessionTimeGroup.groups(from: model.summaries, now: now)
    }

    var body: some View {
        List {
            if model.summaries.isEmpty {
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
            Button {
                model.startNewSession()
                dismiss()
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .disabled(model.isReplying)
            .accessibilityLabel("新对话")
        }
        .onAppear { now = Date() }
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
