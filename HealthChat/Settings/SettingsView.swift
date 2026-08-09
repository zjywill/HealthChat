import SwiftUI

struct SettingsView: View {
    let canClearConversation: Bool
    let onClearConversation: () -> Void

    @AppStorage(EngineSettings.providerKey) private var providerId = EngineSettings.defaultProvider
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel
    @AppStorage(EngineSettings.personaKey) private var persona = EngineSettings.defaultPersona
    @AppStorage(EngineSettings.thinkingEnabledKey) private var thinkingEnabled = true
    @AppStorage(EngineSettings.checkInsEnabledKey) private var checkInsEnabled = false
    @AppStorage(EngineSettings.morningCheckInHourKey) private var morningHour = EngineSettings.defaultMorningHour
    @AppStorage(EngineSettings.eveningCheckInHourKey) private var eveningHour = EngineSettings.defaultEveningHour
    @State private var checkInStatus: HealthAuthStatus?

    @State private var apiKey = ""
    @State private var persistedAPIKey = ""
    @State private var hasStoredAPIKey = false
    @State private var hasLoadedAPIKey = false
    @State private var keyStatus = KeyStatus.notSet
    @State private var searchKey = ""
    @State private var persistedSearchKey = ""
    @State private var searchKeyStatus = KeyStatus.notSet
    @State private var isShowingClearConfirmation = false
    @State private var isRequestingHealth = false
    @State private var healthStatus: HealthAuthStatus?
    @FocusState private var focusedField: Field?
    @Environment(\.openURL) private var openURL

    init(
        canClearConversation: Bool = false,
        onClearConversation: @escaping () -> Void = {}
    ) {
        self.canClearConversation = canClearConversation
        self.onClearConversation = onClearConversation
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("API key") {
                    HStack(spacing: 8) {
                        SecureField("必填", text: $apiKey)
                            .focused($focusedField, equals: .apiKey)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .privacySensitive()
                            .onSubmit(saveAPIKey)
                            .accessibilityLabel("云端 API key")

                        if !apiKey.isEmpty {
                            Button {
                                apiKey = ""
                                focusedField = .apiKey
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除 API key")
                        }
                    }
                }

                Label {
                    // key 全遮住就没法核对填的是哪一把,露头尾足够认人。
                    if keyStatus == .saved, let hint = maskedKey(persistedAPIKey) {
                        Text("\(keyStatus.message) · \(Text(hint).monospaced())")
                    } else {
                        Text(keyStatus.message)
                    }
                } icon: {
                    Image(systemName: keyStatus.icon)
                }
                .font(.footnote)
                .foregroundStyle(keyStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .privacySensitive()
                .accessibilityElement(children: .combine)

                if CloudCatalog.isLoaded {
                    NavigationLink {
                        ProviderPickerView(selectedId: providerId, onSelect: selectProvider)
                    } label: {
                        LabeledContent("Provider", value: CloudCatalog.providerName(for: providerId))
                    }

                    NavigationLink {
                        ModelPickerView(
                            providerId: providerId,
                            selectedId: model,
                            onSelect: { model = $0 }
                        )
                    } label: {
                        LabeledContent(
                            "模型",
                            value: model.isEmpty ? "未选择" : CloudCatalog.modelName(for: model, in: providerId)
                        )
                    }

                    if model.isEmpty {
                        Label("请先选择模型", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                            .accessibilityElement(children: .combine)
                    }
                } else {
                    // catalog 资源没打进 app,退回手输,别把人卡死
                    LabeledContent("Provider ID") {
                        TextField(EngineSettings.defaultProvider, text: $providerId)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("Provider ID")
                    }

                    LabeledContent("模型") {
                        TextField(EngineSettings.defaultModel, text: $model)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.asciiCapable)
                            .accessibilityLabel("模型")
                    }

                    Label("未能载入 AIKit provider 目录，暂时只能手动填写。", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .accessibilityElement(children: .combine)
                }

                if hasStoredAPIKey {
                    Button(role: .destructive) {
                        apiKey = ""
                        saveAPIKey()
                    } label: {
                        // `role: .destructive` 只染文字,Form 里的图标照样跟着 accent
                        // 走——一行里红字配蓝图标。`.tint(.red)` 在这儿也管不着,得直接
                        // 给图标上色。
                        Label {
                            Text("移除 API key")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("云端模型")
            } footer: {
                Text("Provider 和模型都从 AIKit 内置目录里选。API key 只保存在本机钥匙串。")
            }

            Section {
                LabeledContent("Serper key") {
                    HStack(spacing: 8) {
                        SecureField("选填", text: $searchKey)
                            .focused($focusedField, equals: .searchKey)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .privacySensitive()
                            .onSubmit(saveSearchKey)
                            .accessibilityLabel("网页搜索 key")

                        if !searchKey.isEmpty {
                            Button {
                                searchKey = ""
                                focusedField = .searchKey
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("清除网页搜索 key")
                        }
                    }
                }

                Label {
                    if searchKeyStatus == .saved, let hint = maskedKey(persistedSearchKey) {
                        Text("已保存 · \(Text(hint).monospaced())")
                    } else {
                        Text(searchKeyStatus.searchMessage)
                    }
                } icon: {
                    Image(systemName: searchKeyStatus.icon)
                }
                .font(.footnote)
                .foregroundStyle(searchKeyStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .privacySensitive()
                .accessibilityElement(children: .combine)

                if !persistedSearchKey.isEmpty {
                    Button(role: .destructive) {
                        searchKey = ""
                        saveSearchKey()
                    } label: {
                        Label {
                            Text("移除搜索 key")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                    }
                }
            } header: {
                Text("网页搜索")
            } footer: {
                // key 的有无就是开关,所以这句话要说清「填了会怎样、不填会怎样」,
                // 不然用户会去找一个并不存在的开关。
                Text("填了 serper.dev 的 key，Vana 遇到自己不知道的事就能上网查一下，并给出出处。"
                    + "不填就只用它已有的知识回答。搜索词不会带上你的健康数据。key 只保存在本机钥匙串。")
            }

            Section {
                Picker("说话方式", selection: $persona) {
                    ForEach(AssistantPersona.allCases) { option in
                        Text(option.name).tag(option.rawValue)
                    }
                }

                Text(AssistantPersona(rawValue: persona)?.summary ?? "")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("回答前先思考", isOn: $thinkingEnabled)

                NavigationLink {
                    MemoryView()
                } label: {
                    Label("Vana 记住的事", systemImage: "brain")
                }
            } header: {
                Text("助手")
            } footer: {
                Text("只改语气和详略，不改数据口径——同样只引用工具返回的数字，同样不做诊断。"
                    + "\n思考让多步分析更准，但更慢也更贵；有些模型不支持关闭，那就还是会思考。")
            }

            Section {
                Toggle("每日 check-in", isOn: $checkInsEnabled)

                if checkInsEnabled {
                    Picker("早上", selection: $morningHour) {
                        ForEach(5...11, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                    Picker("晚上", selection: $eveningHour) {
                        ForEach(18...23, id: \.self) { hour in
                            Text("\(hour):00").tag(hour)
                        }
                    }
                }

                if let checkInStatus {
                    Label(checkInStatus.message, systemImage: checkInStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(checkInStatus.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)
                }
            } header: {
                Text("提醒")
            } footer: {
                Text("早上说昨晚的睡眠，晚上说今天的活动量，都基于本机算出来的数据；"
                    + "点开通知会直接带着对应话题开一条新对话。文案在每次打开 app 时刷新。")
            }

            Section {
                Button {
                    requestHealthAuthorization()
                } label: {
                    Label(
                        isRequestingHealth ? "正在请求…" : "请求健康数据授权",
                        systemImage: "heart.text.square"
                    )
                }
                .disabled(isRequestingHealth)

                if let healthStatus {
                    Label(healthStatus.message, systemImage: healthStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(healthStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)
                }

                Button {
                    openURL(URL(string: "x-apple-health://")!)
                } label: {
                    Label("在“健康”App 中管理", systemImage: "arrow.up.forward.app")
                }
            } header: {
                Text("健康数据")
            } footer: {
                // iOS 从不告诉 app 读取权限被拒了(拒绝和"没数据"长得一样),所以这里
                // 不假装能显示授权状态,只说清楚该去哪儿改。
                Text("新增的数据类型（血压、血氧、呼吸频率、体温）需要重新请求才能读取。"
                    + "已经做过选择的项 iOS 不会再问，要打开或关闭请到“健康”App > 共享 > App > Vana。")
            }

            Section {
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label {
                        Text("清空对话")
                    } icon: {
                        Image(systemName: "trash").foregroundStyle(.red)
                    }
                }
                .disabled(!canClearConversation)
            } header: {
                Text("对话")
            } footer: {
                Text("清空会删除本机保存的所有消息，无法撤销。")
            }

            #if DEBUG
            Section {
                NavigationLink {
                    DeveloperView()
                } label: {
                    Label("开发", systemImage: "hammer")
                }
            } footer: {
                Text("只在 Debug 构建里出现。")
            }
            #endif
        }
        .navigationTitle("设置")
        .task(loadAPIKey)
        .onChange(of: apiKey) { _, newValue in
            guard hasLoadedAPIKey else { return }
            if newValue == persistedAPIKey {
                keyStatus = newValue.isEmpty ? .notSet : .saved
            } else {
                keyStatus = .pending
            }
        }
        .onChange(of: searchKey) { _, newValue in
            guard hasLoadedAPIKey else { return }
            if newValue == persistedSearchKey {
                searchKeyStatus = newValue.isEmpty ? .notSet : .saved
            } else {
                searchKeyStatus = .pending
            }
        }
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .apiKey, newField != .apiKey {
                saveAPIKey()
            }
            if oldField == .searchKey, newField != .searchKey {
                saveSearchKey()
            }
        }
        .onDisappear {
            if apiKey != persistedAPIKey {
                saveAPIKey()
            }
            if searchKey != persistedSearchKey {
                saveSearchKey()
            }
        }
        .onChange(of: checkInsEnabled) { _, enabled in
            Task { await applyCheckInSettings(enabled: enabled) }
        }
        .onChange(of: morningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
        .onChange(of: eveningHour) { _, _ in
            Task { await CheckInScheduler.reschedule() }
        }
        .confirmationDialog(
            "清空当前对话？",
            isPresented: $isShowingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("清空对话", role: .destructive) {
                onClearConversation()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作会删除本机保存的所有消息，无法撤销。")
        }
    }

    /// 换 provider 时,旧模型多半不属于新 provider,直接换成新 provider 的第一个可用模型。
    private func selectProvider(_ id: String) {
        guard id != providerId else { return }
        providerId = id
        if CloudCatalog.model(model, in: id) == nil {
            model = CloudCatalog.defaultModel(for: id) ?? ""
        }
    }

    /// 打开开关时先要通知权限;用户拒了就把开关拨回去,而不是留着一个不会响的开关。
    private func applyCheckInSettings(enabled: Bool) async {
        guard enabled else {
            await CheckInScheduler.reschedule()
            checkInStatus = nil
            return
        }

        guard await CheckInScheduler.requestAuthorization() else {
            checkInsEnabled = false
            checkInStatus = HealthAuthStatus(
                message: "系统通知权限没有打开，请到「设置 > Vana > 通知」里允许。",
                icon: "exclamationmark.triangle.fill",
                isError: true
            )
            return
        }

        await CheckInScheduler.reschedule()
        checkInStatus = HealthAuthStatus(
            message: "已排程，每天 \(morningHour):00 和 \(eveningHour):00 各一条。",
            icon: "checkmark.circle.fill",
            isError: false
        )
    }

    /// 再请求一次授权。iOS 只会为"还没问过"的类型弹窗——新增数据类型后靠这个补上,
    /// 已经拒过的项它不会再问,那种情况只能去「健康」App 改。
    private func requestHealthAuthorization() {
        guard !isRequestingHealth else { return }
        isRequestingHealth = true
        healthStatus = nil

        Task {
            defer { isRequestingHealth = false }
            do {
                let didAsk = try await HealthStore.shared.requestAuthorizationIfNeeded(force: true)
                healthStatus = HealthAuthStatus(
                    message: didAsk
                        ? "已弹出授权面板，你的选择已保存。"
                        : "这些数据类型都已经问过了。要打开或关闭，请到“健康”App 里改。",
                    icon: didAsk ? "checkmark.circle.fill" : "info.circle",
                    isError: false
                )
            } catch {
                healthStatus = HealthAuthStatus(
                    message: "请求失败：\(error.localizedDescription)",
                    icon: "exclamationmark.triangle.fill",
                    isError: true
                )
            }
        }
    }

    /// "sk-ant…7f2a":露头尾够认出是哪一把 key,又不至于把整串摆在屏幕上。太短的不露。
    private func maskedKey(_ key: String) -> String? {
        guard key.count >= 12 else { return nil }
        return "\(key.prefix(6))…\(key.suffix(4))"
    }

    private func loadAPIKey() {
        guard !hasLoadedAPIKey else { return }
        do {
            let stored = try KeychainStore.get(account: KeychainStore.apiKeyAccount) ?? ""
            apiKey = stored
            persistedAPIKey = stored
            hasStoredAPIKey = !stored.isEmpty
            keyStatus = stored.isEmpty ? .notSet : .saved
        } catch {
            keyStatus = .error(error.localizedDescription)
        }
        // 搜索那把单独读,单独报错。它读失败不该让上面那把也显示成出错——两把 key 是
        // 两回事,一起报会让用户去改本来没问题的那一把。
        do {
            let stored = try KeychainStore.get(account: KeychainStore.searchAPIKeyAccount) ?? ""
            searchKey = stored
            persistedSearchKey = stored
            searchKeyStatus = stored.isEmpty ? .notSet : .saved
        } catch {
            searchKeyStatus = .error(error.localizedDescription)
        }
        hasLoadedAPIKey = true
    }

    private func saveSearchKey() {
        guard hasLoadedAPIKey else { return }
        let value = searchKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if value.isEmpty {
                try KeychainStore.delete(account: KeychainStore.searchAPIKeyAccount)
                searchKey = ""
                persistedSearchKey = ""
                searchKeyStatus = .notSet
            } else {
                try KeychainStore.set(value, account: KeychainStore.searchAPIKeyAccount)
                searchKey = value
                persistedSearchKey = value
                searchKeyStatus = .saved
            }
        } catch {
            searchKeyStatus = .error(error.localizedDescription)
        }
    }

    private func saveAPIKey() {
        guard hasLoadedAPIKey else { return }
        let value = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            if value.isEmpty {
                try KeychainStore.delete(account: KeychainStore.apiKeyAccount)
                apiKey = ""
                persistedAPIKey = ""
                hasStoredAPIKey = false
                keyStatus = .notSet
            } else {
                try KeychainStore.set(value, account: KeychainStore.apiKeyAccount)
                apiKey = value
                persistedAPIKey = value
                hasStoredAPIKey = true
                keyStatus = .saved
            }
        } catch {
            keyStatus = .error(error.localizedDescription)
        }
    }

}

private enum Field: Hashable {
    case apiKey
    case searchKey
}

private struct HealthAuthStatus {
    let message: String
    let icon: String
    let isError: Bool
}

private enum KeyStatus: Equatable {
    case notSet
    case pending
    case saved
    case error(String)

    var message: String {
        switch self {
        case .notSet:
            return "尚未保存 API key"
        case .pending:
            return "更改尚未保存"
        case .saved:
            return "API key 已保存"
        case .error(let message):
            return "无法保存：\(message)"
        }
    }

    /// 搜索那把是选填的,「尚未保存」听起来像少配了什么。说清不填会怎样。
    var searchMessage: String {
        switch self {
        case .notSet:
            return "没填，Vana 不会上网搜"
        case .pending:
            return "更改尚未保存"
        case .saved:
            return "已保存"
        case .error(let message):
            return "无法保存：\(message)"
        }
    }

    var icon: String {
        switch self {
        case .notSet:
            return "key"
        case .pending:
            return "pencil"
        case .saved:
            return "checkmark.circle.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        }
    }

    var isError: Bool {
        if case .error = self {
            return true
        }
        return false
    }
}
