import SwiftUI

/// TODO(M4):引擎选择(自动/端上/云端)+ API key 输入(存 Keychain)+ provider/模型切换。
struct SettingsView: View {
    #if DEBUG
    @State private var debugStatus: DebugStatus?
    @State private var isSeeding = false
    @State private var isChecking = false
    #endif

    var body: some View {
        Form {
            Section("引擎") {
                LabeledContent("当前", value: "Echo(占位)")
            }
            Section("云端引擎(AIKit)") {
                Text("M4:API key 输入,存 Keychain")
                    .foregroundStyle(.secondary)
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
            DebugSeeder.shared.selfCheck()
            debugStatus = DebugStatus(message: "自检入口已就绪，查询将在后续任务接入", icon: "checkmark.circle", isError: false)
        }
    }
    #endif
}

#if DEBUG
private struct DebugStatus {
    let message: String
    let icon: String
    let isError: Bool
}
#endif
