import SwiftUI

/// 正在编辑(或新建)的一条。`editing` 为 nil 就是新建。
struct MedicationDraft: Identifiable {
    let id = UUID()
    var editing: MedicationItem?
    var name = ""
    var status: MedicationStatus = .asNeeded
    var when = ""
    var reason = ""
    var outcome = ""
    var brief = ""
    var note = ""
    var followUpDays = 0

    init(status: MedicationStatus = .asNeeded) {
        self.status = status
    }

    init(_ item: MedicationItem) {
        editing = item
        name = item.name
        status = item.status
        when = item.when
        reason = item.reason
        outcome = item.outcome
        brief = item.brief
        note = item.note
        if let followUpAt = item.followUpAt {
            followUpDays = max(
                Calendar.current.dateComponents([.day], from: Date(), to: followUpAt).day ?? 0,
                0
            )
        }
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 存回去。`briefIsUserWritten` 只在他真的动过那一段时才翻——翻了之后重新生成就不会
    /// 再覆盖它(同 `MemoryItem.pinned`)。
    func applied() -> MedicationItem {
        var item = editing ?? MedicationItem(name: trimmedName, origin: .manual)
        let briefChanged = brief.trimmingCharacters(in: .whitespacesAndNewlines)
            != (editing?.brief ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        item.name = trimmedName
        item.status = status
        item.when = when.trimmingCharacters(in: .whitespacesAndNewlines)
        item.reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        item.outcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        item.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        item.brief = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        if briefChanged { item.briefIsUserWritten = !item.brief.isEmpty }
        item.followUpAt = followUpDays > 0
            ? Date().addingTimeInterval(Double(followUpDays) * 86_400)
            : nil
        if item.startedAt == nil, status == .ongoing || status == .asNeeded {
            item.startedAt = Date()
        }
        return item
    }
}

struct MedicationEditView: View {
    @State var draft: MedicationDraft
    let onSave: (MedicationDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名字，比如：褪黑素", text: $draft.name)
                        .focused($isNameFocused)

                    Picker("关系", selection: $draft.status) {
                        ForEach(MedicationStatus.allCases) { status in
                            Label(status.title, systemImage: status.icon).tag(status)
                        }
                    }
                } footer: {
                    Text(draft.status.hint)
                }

                Section {
                    TextField("什么情况下吃，比如：头疼时", text: $draft.when)
                    TextField("为什么吃 / 谁让你吃的", text: $draft.reason, axis: .vertical)
                        .lineLimit(1...3)
                } footer: {
                    Text("不用写剂量。Vana 不做用药提醒，剂量和按时吃在「健康」App 里管更合适。")
                }

                Section {
                    TextField("有没有用？有什么感觉？", text: $draft.outcome, axis: .vertical)
                        .lineLimit(1...4)
                } header: {
                    Text("你自己的评价")
                } footer: {
                    // 这一列是这张表最值钱的东西,footer 要说清它换来的是什么。
                    Text("""
                        这一句只有你知道，也是这张表最有用的一栏——记下来，\
                        Vana 就不会再推荐一次你已经试过没用的东西。
                        """)
                }

                Section {
                    Picker("过多久回头看", selection: $draft.followUpDays) {
                        Text("不用").tag(0)
                        ForEach([7, 14, 30, 60, 90], id: \.self) { days in
                            Text("\(days) 天后").tag(days)
                        }
                    }
                } footer: {
                    Text("到时候 Vana 会在早上那条消息里问你一句有没有用。")
                }

                Section {
                    TextField("一般说明", text: $draft.brief, axis: .vertical)
                        .lineLimit(1...4)
                    TextField("备注", text: $draft.note, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    Text("「一般说明」原本由 Vana 自动写，改过之后就不会再被自动覆盖。")
                }
            }
            .navigationTitle(draft.editing == nil ? "加一条" : "编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.trimmedName.isEmpty)
                }
            }
            .onAppear { isNameFocused = draft.editing == nil }
        }
    }
}
