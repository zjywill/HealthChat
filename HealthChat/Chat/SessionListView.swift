import SwiftUI

/// 会话列表:切换、新建、删除。
struct SessionListView: View {
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if model.summaries.isEmpty {
                ContentUnavailableView(
                    "还没有会话",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("问一个健康问题，这里就会出现记录。")
                )
            } else {
                ForEach(model.summaries) { summary in
                    Button {
                        model.openSession(id: summary.id)
                        dismiss()
                    } label: {
                        row(for: summary)
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
    }

    private func row(for summary: SessionSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                // 界面文案全是中文写死的,相对时间也得跟上——app 没做本地化,
                // 不指定 locale 就会跟着系统语言变成 "33 seconds ago"。
                Text("\(summary.updatedAt.formatted(.relative(presentation: .named).locale(Locale(identifier: "zh_Hans")))) · \(summary.messageCount) 条消息")
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
