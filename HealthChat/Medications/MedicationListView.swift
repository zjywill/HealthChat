import SwiftUI

/// 「用药与补剂」。
///
/// 这张表回答的是「我和这些东西是什么关系」,不是「我今天该吃什么」——后者 Apple Health 已经
/// 做完了(排程、提醒、打卡),Vana 做第二套只会两边对不上。空态那句话必须把这件事说清,
/// 否则用户会按提醒器来期待它,然后失望地发现它不提醒。
///
/// 以 sheet 呈现,不是 push:详情页里那颗「问问 Vana」要回到聊天界面,而从 push 出来的两层
/// 里退回根视图没有干净的写法。它本来也是一次离开对话的detour,模态是对的形状。
struct MedicationListView: View {
    let model: ChatViewModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage(EngineSettings.medicationsEnabledKey) private var medicationsEnabled = true

    @State private var items: [MedicationItem] = []
    @State private var hasLoaded = false
    @State private var draft: MedicationDraft?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("让 Vana 看到这份清单", isOn: $medicationsEnabled)
                } footer: {
                    Text("开着时，这份清单会随每次提问一起发给你选的模型 provider，"
                        + "Vana 给建议之前会先看你不能吃什么、试过什么没用。"
                        + "关掉只是先不用，下面的内容还在。")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .accessibilityElement(children: .combine)
                    }
                }

                if items.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("还没记下什么", systemImage: "pills")
                        } description: {
                            Text("你吃过、在吃、不能吃的东西。Vana 每次给建议之前都会先看这里。\n\n"
                                + "这里不做用药提醒和打卡——那些在「健康」App 里管更合适。")
                        }
                        .listRowBackground(Color.clear)
                    }
                }

                ForEach(MedicationStatus.allCases) { status in
                    let matching = items.filter { $0.status == status }
                    if !matching.isEmpty {
                        Section {
                            ForEach(matching) { item in
                                NavigationLink {
                                    MedicationDetailView(
                                        item: item,
                                        onEdit: { draft = MedicationDraft($0) },
                                        onDelete: { delete($0.id) },
                                        onAsk: ask
                                    )
                                } label: {
                                    row(item)
                                }
                            }
                            .onDelete { offsets in
                                offsets.forEach { delete(matching[$0].id) }
                            }
                        } header: {
                            Label(status.title, systemImage: status.icon)
                                // 「不能吃」那一组和别的不是同一种东西,它得一眼看出来。
                                .foregroundStyle(status == .cannotTake ? Color.red : Color.secondary)
                        } footer: {
                            Text(status.hint)
                        }
                    }
                }
            }
            .navigationTitle("用药与补剂")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        draft = MedicationDraft()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("加一条")
                }
            }
            .sheet(item: $draft) { editing in
                MedicationEditView(draft: editing, onSave: save)
            }
            .task {
                guard !hasLoaded else { return }
                hasLoaded = true
                items = await MedicationStore.shared.items()
            }
        }
    }

    private func row(_ item: MedicationItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
                .foregroundStyle(item.status == .cannotTake ? Color.red : Color.primary)
            if let subtitle = subtitle(item) {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 一行里显示哪一句:**他自己的评价优先**,没有才退到触发条件、原因,最后才是自动生成的
    /// 那句一般说明。一般说明放前面的话,整张表看起来像一份药品说明书摘抄,而这张表的价值
    /// 恰恰在于它是他自己的。
    private func subtitle(_ item: MedicationItem) -> String? {
        let candidates = [item.outcome, item.when, item.reason, item.brief]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func ask(_ item: MedicationItem) {
        model.openMedication(item)
        dismiss()
    }

    private func save(_ draft: MedicationDraft) {
        let item = draft.applied()
        let isNew = draft.editing == nil
        perform {
            let latest = isNew
                ? try await MedicationStore.shared.add(item)
                : try await MedicationStore.shared.update(item)
            // 加完立刻去写那句一般说明。失败就空着——列表照常用。
            if item.brief.isEmpty {
                Task {
                    let target = await MedicationStore.shared.item(named: item.name) ?? item
                    await MedicationBriefer.fill(target)
                    items = await MedicationStore.shared.items()
                }
            }
            return latest
        }
    }

    private func delete(_ id: UUID) {
        perform { try await MedicationStore.shared.delete(id: id) }
    }

    private func perform(_ work: @escaping () async throws -> [MedicationItem]) {
        Task {
            do {
                items = try await work()
                errorMessage = nil
            } catch {
                errorMessage = "保存失败：\(error.localizedDescription)"
            }
        }
    }
}
