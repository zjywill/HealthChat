import SwiftUI
import FoundationModels

struct SettingsView: View {
    @AppStorage(EngineSettings.choiceKey) private var engineChoice = EngineSettings.defaultChoice
    @AppStorage(EngineSettings.providerKey) private var providerId = EngineSettings.defaultProvider
    @AppStorage(EngineSettings.modelKey) private var model = EngineSettings.defaultModel

    @State private var apiKey = ""
    @State private var persistedAPIKey = ""
    @State private var hasStoredAPIKey = false
    @State private var hasLoadedAPIKey = false
    @State private var keyStatus = KeyStatus.notSet
    @FocusState private var focusedField: Field?

    #if DEBUG
    @State private var debugStatus: DebugStatus?
    @State private var isSeeding = false
    @State private var isChecking = false
    #endif

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("使用引擎")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Picker("使用引擎", selection: $engineChoice) {
                        ForEach(EngineChoice.allCases) { choice in
                            Text(choice.title).tag(choice.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("当前生效") {
                    Label(effectiveEngine.text, systemImage: effectiveEngine.icon)
                        .foregroundStyle(effectiveEngine.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                }
            } header: {
                Text("引擎")
            } footer: {
                Text("自动模式优先使用端上模型，健康数据留在设备；端上不可用且已保存 API key 时，才会使用云端模型。")
            }

            Section {
                LabeledContent("API key") {
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
                }

                Label(keyStatus.message, systemImage: keyStatus.icon)
                    .font(.footnote)
                    .foregroundStyle(keyStatus.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .accessibilityElement(children: .combine)

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
                Text("Provider ID 使用 AIKit catalog 中的标识，例如 anthropic。API key 只保存在本机钥匙串。")
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
    }

    private var effectiveEngine: EngineStatus {
        let choice = EngineChoice(rawValue: engineChoice) ?? .automatic
        switch choice {
        case .automatic:
            if onDeviceModelAvailable {
                return EngineStatus(text: "端上模型", icon: "cpu", isWarning: false)
            }
            if hasStoredAPIKey {
                return EngineStatus(text: "云端模型", icon: "cloud", isWarning: false)
            }
            return EngineStatus(text: "尚未配置", icon: "exclamationmark.triangle", isWarning: true)
        case .onDevice:
            return onDeviceModelAvailable
                ? EngineStatus(text: "端上模型", icon: "cpu", isWarning: false)
                : EngineStatus(text: "端上模型不可用", icon: "exclamationmark.triangle", isWarning: true)
        case .cloud:
            return hasStoredAPIKey
                ? EngineStatus(text: "云端模型", icon: "cloud", isWarning: false)
                : EngineStatus(text: "云端模型缺少 API key", icon: "exclamationmark.triangle", isWarning: true)
        }
    }

    private var onDeviceModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
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
                try await DebugSeeder.shared.seed()
                debugStatus = DebugStatus(message: "已写入最近 30 天的种子数据", icon: "checkmark.circle.fill", isError: false)
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

private struct EngineStatus {
    let text: String
    let icon: String
    let isWarning: Bool
}

#if DEBUG
private struct DebugStatus {
    let message: String
    let icon: String
    let isError: Bool
}
#endif
