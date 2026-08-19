import SwiftUI

/// 成员列表:切换、添加、改名、删除。
///
/// 入口在**会话列表页顶部**,不在 toolbar。切成员 = 换一整个会话空间,那正是会话列表在说的
/// 事;而 toolbar leading 已经有会话列表和用药表两颗,第三颗只会让那一排开始需要辨认。
struct TenantListView: View {
    let context: TenantContext
    /// 选中之后要一路收到对话去。留在列表里的话,他刚切完人,屏幕上还是上一位的会话列表。
    var onSelect: () -> Void

    @State private var editing: Tenant?
    @State private var isAdding = false

    var body: some View {
        List {
            Section {
                ForEach(context.tenants) { tenant in
                    Button {
                        context.select(tenant)
                        onSelect()
                    } label: {
                        row(tenant)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        // 机主删不掉:删了之后这台设备的健康数据就没有归属了。
                        if !tenant.isOwner {
                            Button(role: .destructive) {
                                context.remove(tenant)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        Button {
                            editing = tenant
                        } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.gray)
                    }
                }
            } footer: {
                // 这段话是这一屏最要紧的部分:它在用户添加第一位家人**之前**就把边界说清楚。
                // 不说的话,他会拍完化验单等着 Vana 像对自己那样报「昨晚睡了几小时」,而那份
                // 数据根本不存在——期待落空一次,这个功能在他心里就是坏的。
                Text("""
                    每位成员的会话、用药清单、记忆和照片各存一份，互相看不到。\n\
                    Apple 健康数据只有本人有：家人这边读不到步数、睡眠、心率这些，\
                    他的情况来自你记下的用药、拍给 Vana 的化验单，和你们聊过的内容。
                    """)
            }

            if let failure = context.failure {
                Section {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
        }
        .navigationTitle("家庭成员")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isAdding = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("添加成员")
            }
        }
        .sheet(isPresented: $isAdding) {
            TenantEditView(tenant: nil) { name, ageBand in
                context.add(name: name, ageBand: ageBand)
                // 添加即切换(见 `TenantContext.add`),所以这儿也一路收到对话去。
                onSelect()
            }
        }
        .sheet(item: $editing) { tenant in
            TenantEditView(tenant: tenant) { name, ageBand in
                context.update(tenant, name: name, ageBand: ageBand)
            }
        }
    }

    private func row(_ tenant: Tenant) -> some View {
        HStack(spacing: 12) {
            Image(systemName: tenant.isOwner ? "person.crop.circle" : "person.crop.circle.badge.questionmark")
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(tenant.displayName)
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle(tenant))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if tenant.id == context.current.id {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tenant.id == context.current.id ? [.isButton, .isSelected] : .isButton)
    }

    /// 每一行都要说清「这一位有没有健康数据」。那是两类成员唯一的实质区别,而用户从名字上
    /// 看不出来。
    private func subtitle(_ tenant: Tenant) -> String {
        var parts: [String] = []
        if let ageBand = tenant.ageBand { parts.append(ageBand.label) }
        parts.append(tenant.isOwner
            ? String(localized: "本人 · 有 Apple 健康数据")
            : String(localized: "只有你记下的内容"))
        return parts.joined(separator: " · ")
    }
}

/// 添加和编辑用同一张表:两件事要填的东西一模一样,分成两个界面只会让措辞漂。
struct TenantEditView: View {
    let tenant: Tenant?
    var onSave: (String, Tenant.AgeBand?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var ageBand: Tenant.AgeBand?

    private var isOwner: Bool { tenant?.isOwner ?? false }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("称呼，比如：妈妈、爸爸、女儿", text: $name)
                        .textInputAutocapitalization(.never)
                } footer: {
                    Text("只写称呼就行。Vana 不需要真实姓名、生日或证件信息，也不要填进来。")
                }

                Section {
                    Picker("年龄段", selection: $ageBand) {
                        Text("不说").tag(Tenant.AgeBand?.none)
                        ForEach(Tenant.AgeBand.allCases) { band in
                            Text(band.label).tag(Tenant.AgeBand?.some(band))
                        }
                    }
                } footer: {
                    // 给年龄段是因为它真的会改变答案;不给生日是因为那一天几号一次都用不上,
                    // 而多给的每一个身份字段都是模型可以说漏嘴的东西。
                    Text("儿童的用量、老人的参考范围和风险判断都不一样，说一句能让回答准不少。具体用药和剂量仍然要问医生。")
                }
            }
            .navigationTitle(tenant == nil ? "添加成员" : "编辑成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(name, ageBand)
                        dismiss()
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear {
                guard let tenant else { return }
                name = tenant.name
                ageBand = tenant.ageBand
            }
        }
        // 机主那条只能改称呼和年龄段,改不了"他是机主"这件事——那是由这台设备决定的。
        .interactiveDismissDisabled(false)
        .presentationDetents(isOwner ? [.medium] : [.medium, .large])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
