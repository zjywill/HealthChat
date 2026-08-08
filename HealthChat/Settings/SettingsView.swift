import SwiftUI

struct SettingsView: View {
    let canClearConversation: Bool
    let onClearConversation: () -> Void

    @AppStorage(EngineSettings.providerKey) private var providerId = EngineSettings.defaultProvider
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel
    @AppStorage(EngineSettings.personaKey) private var persona = EngineSettings.defaultPersona
    @AppStorage(EngineSettings.checkInsEnabledKey) private var checkInsEnabled = false
    @AppStorage(EngineSettings.morningCheckInHourKey) private var morningHour = EngineSettings.defaultMorningHour
    @AppStorage(EngineSettings.eveningCheckInHourKey) private var eveningHour = EngineSettings.defaultEveningHour
    @State private var checkInStatus: HealthAuthStatus?

    @State private var apiKey = ""
    @State private var persistedAPIKey = ""
    @State private var hasStoredAPIKey = false
    @State private var hasLoadedAPIKey = false
    @State private var keyStatus = KeyStatus.notSet
    @State private var isShowingClearConfirmation = false
    @State private var isRequestingHealth = false
    @State private var healthStatus: HealthAuthStatus?
    @FocusState private var focusedField: Field?
    @Environment(\.openURL) private var openURL

    #if DEBUG
    @State private var debugStatus: DebugStatus?
    @State private var isSeeding = false
    @State private var isChecking = false
    #endif

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
                        Label("移除 API key", systemImage: "trash")
                    }
                }
            } header: {
                Text("云端模型")
            } footer: {
                Text("Provider 和模型都从 AIKit 内置目录里选。API key 只保存在本机钥匙串。")
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
            } header: {
                Text("助手")
            } footer: {
                Text("只改语气和详略，不改数据口径——同样只引用工具返回的数字，同样不做诊断。")
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
                    + "已经做过选择的项 iOS 不会再问，要打开或关闭请到“健康”App > 共享 > App > HealthChat。")
            }

            Section {
                Button(role: .destructive) {
                    isShowingClearConfirmation = true
                } label: {
                    Label("清空对话", systemImage: "trash")
                }
                .disabled(!canClearConversation)
            } header: {
                Text("对话")
            } footer: {
                Text("清空会删除本机保存的所有消息，无法撤销。")
            }

            #if DEBUG
            Section {
                Button {
                    seedHealthData()
                } label: {
                    Label("写入种子数据", systemImage: "square.and.arrow.down")
                }
                .disabled(isSeeding || isChecking)

                Button {
                    runSelfCheck()
                } label: {
                    Label("自检查询", systemImage: "checkmark.circle")
                }
                .disabled(isSeeding || isChecking)

                if let debugStatus {
                    Label(debugStatus.message, systemImage: debugStatus.icon)
                        .font(.footnote)
                        .foregroundStyle(debugStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                }
            } header: {
                Text("开发")
            } footer: {
                Text("种子数据会写入最近 30 天的模拟健康记录，可重复执行。")
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
        .onChange(of: focusedField) { oldField, newField in
            if oldField == .apiKey, newField != .apiKey {
                saveAPIKey()
            }
        }
        .onDisappear {
            if apiKey != persistedAPIKey {
                saveAPIKey()
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
                message: "系统通知权限没有打开，请到「设置 > HealthChat > 通知」里允许。",
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
                let didAsk = try await HealthStore.shared.requestAuthorizationIfNeeded()
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
        hasLoadedAPIKey = true
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

    #if DEBUG
    private func seedHealthData() {
        guard !isSeeding else { return }
        isSeeding = true
        debugStatus = DebugStatus(message: "正在写入健康数据…", icon: "hourglass", isError: false)

        Task {
            defer { isSeeding = false }
            do {
                let skipped = try await DebugSeeder.shared.seed()
                debugStatus = DebugStatus(
                    message: skipped.isEmpty
                        ? "已写入最近 30 天的种子数据"
                        : "已写入种子数据，跳过未授权：\(skipped.joined(separator: "、"))",
                    icon: skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    isError: false
                )
            } catch {
                debugStatus = DebugStatus(
                    message: "写入失败：\(error.localizedDescription)",
                    icon: "exclamationmark.triangle.fill",
                    isError: true
                )
            }
        }
    }

    private func runSelfCheck() {
        guard !isChecking else { return }
        isChecking = true
        debugStatus = DebugStatus(message: "正在运行自检…", icon: "hourglass", isError: false)

        Task {
            defer { isChecking = false }
            do {
                try await DebugSeeder.shared.selfCheck()
                debugStatus = DebugStatus(message: "自检完成，结果已输出到控制台", icon: "checkmark.circle.fill", isError: false)
            } catch {
                debugStatus = DebugStatus(
                    message: "自检失败：\(error.localizedDescription)",
                    icon: "exclamationmark.triangle.fill",
                    isError: true
                )
            }
        }
    }
    #endif
}

private enum Field: Hashable {
    case apiKey
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

#if DEBUG
private struct DebugStatus {
    let message: String
    let icon: String
    let isError: Bool
}
#endif
