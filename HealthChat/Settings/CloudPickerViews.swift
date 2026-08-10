import SwiftUI
import AIKit

/// 从 AIKit catalog 里挑 provider。
struct ProviderPickerView: View {
    let selectedId: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(matches, id: \.id) { provider in
                    Button {
                        onSelect(provider.id)
                        dismiss()
                    } label: {
                        row(for: provider)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("共 \(CloudCatalog.providers.count) 个 provider，来自 AIKit 内置目录。")
            }
        }
        .searchable(text: $query, prompt: "搜索 provider")
        .navigationTitle("Provider")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var matches: [ProviderInfo] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return CloudCatalog.providers }
        return CloudCatalog.providers.filter {
            CloudCatalog.displayName(of: $0).localizedCaseInsensitiveContains(keyword)
                || $0.id.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func row(for provider: ProviderInfo) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(CloudCatalog.displayName(of: provider))
                    .foregroundStyle(.primary)
                Text(subtitle(for: provider))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if provider.id == selectedId {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(provider.id == selectedId ? [.isButton, .isSelected] : .isButton)
    }

    private func subtitle(for provider: ProviderInfo) -> String {
        let count = CloudCatalog.models(for: provider.id).count
        return count == 0 ? provider.id : "\(provider.id) · \(count) 个模型"
    }
}

/// 从选定 provider 的模型列表里挑模型。目录里没有模型的 provider(Ollama、网关等)可以现拉,或手填 ID。
struct ModelPickerView: View {
    let providerId: String
    let selectedId: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var fetched: [ModelInfo] = []
    @State private var isFetching = false
    @State private var fetchError: String?
    @State private var customId = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if !catalogMatches.isEmpty {
                Section {
                    ForEach(catalogMatches, id: \.id) { model in
                        row(for: model)
                    }
                } header: {
                    Text("内置目录")
                } footer: {
                    Text("只列出支持工具调用的模型——不支持的模型读不到健康数据。")
                }
            }

            if !fetchedMatches.isEmpty {
                Section("服务端返回") {
                    ForEach(fetchedMatches, id: \.id) { model in
                        row(for: model)
                    }
                }
            }

            Section {
                Button {
                    fetchModels()
                } label: {
                    Label(isFetching ? "正在获取…" : "从服务端获取模型列表", systemImage: "arrow.down.circle")
                }
                .disabled(isFetching)

                if let fetchError {
                    Label(fetchError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } footer: {
                Text(catalogMatches.isEmpty && fetched.isEmpty
                    ? "该 provider 没有内置模型列表，请用已保存的 API key 获取，或直接填写模型 ID。"
                    : "获取会用已保存的 API key 向该 provider 查询当前可用模型。")
            }

            Section("自定义模型 ID") {
                HStack {
                    TextField("例如 llama3.1", text: $customId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.asciiCapable)
                        .submitLabel(.done)
                        .onSubmit(useCustomId)
                        .accessibilityLabel("自定义模型 ID")

                    Button("使用", action: useCustomId)
                        .buttonStyle(.borderless)
                        .disabled(customId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .searchable(text: $query, prompt: "搜索模型")
        .navigationTitle(CloudCatalog.providerName(for: providerId))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var catalogMatches: [ModelInfo] {
        filtered(CloudCatalog.models(for: providerId))
    }

    private var fetchedMatches: [ModelInfo] {
        let known = Set(CloudCatalog.models(for: providerId).map(\.id))
        return filtered(fetched.filter { !known.contains($0.id) })
    }

    private func filtered(_ models: [ModelInfo]) -> [ModelInfo] {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return models }
        return models.filter {
            CloudCatalog.displayName(of: $0).localizedCaseInsensitiveContains(keyword)
                || $0.id.localizedCaseInsensitiveContains(keyword)
        }
    }

    private func row(for model: ModelInfo) -> some View {
        Button {
            onSelect(model.id)
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(CloudCatalog.displayName(of: model))
                        .foregroundStyle(.primary)
                    Text(subtitle(for: model))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    // 挑模型的那一刻是他唯一会比较这几项的时候。挑完再去别处发现「这个看不了图」,
                    // 中间隔着一次白跑。
                    ModelCapabilityTags(model: model)
                }

                Spacer(minLength: 12)

                if model.id == selectedId {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(model.id == selectedId ? [.isButton, .isSelected] : .isButton)
    }

    private func subtitle(for model: ModelInfo) -> String {
        guard let limits = CloudCatalog.limitSummary(of: model) else { return model.id }
        return "\(model.id) · \(limits)"
    }

    private func useCustomId() {
        let value = customId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        onSelect(value)
        dismiss()
    }

    private func fetchModels() {
        guard !isFetching else { return }
        isFetching = true
        fetchError = nil

        Task {
            defer { isFetching = false }
            do {
                let key = try KeychainStore.get(account: KeychainStore.apiKeyAccount) ?? ""
                fetched = try await CloudCatalog.fetchModels(providerId: providerId, apiKey: key)
                if fetched.isEmpty {
                    fetchError = "服务端没有返回模型"
                }
            } catch {
                fetchError = "获取失败：\(error.localizedDescription)"
            }
        }
    }
}
