#if DEBUG
import SwiftUI

/// 只在 Debug 构建里存在的开发工具页。放进二级菜单是因为这些按钮对用户毫无意义,
/// 而它们平铺在设置页底部时,和上面那些真的设置长得一模一样。
struct DeveloperView: View {
    @State private var status: DeveloperStatus?
    @State private var isSeeding = false
    @State private var isChecking = false

    var body: some View {
        Form {
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
            } header: {
                Text("健康数据")
            } footer: {
                Text("""
                    种子数据会写入最近 30 天的模拟健康记录，可重复执行。\
                    \n自检把每个查询工具都跑一遍，结果输出到控制台。
                    """)
            }

            Section {
                Button {
                    // 走的是和真 check-in 完全相同的那条路,只是触发器换成 5 秒后。
                    Task {
                        status = DeveloperStatus(
                            message: await CheckInScheduler.sendTest(),
                            icon: "bell",
                            isError: false
                        )
                    }
                } label: {
                    Label("发一条测试 check-in", systemImage: "bell.badge")
                }
            } header: {
                Text("通知")
            }

            if let status {
                Section {
                    Label(status.message, systemImage: status.icon)
                        .font(.footnote)
                        .foregroundStyle(status.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .navigationTitle("开发")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func seedHealthData() {
        guard !isSeeding else { return }
        isSeeding = true
        status = DeveloperStatus(message: "正在写入健康数据…", icon: "hourglass", isError: false)

        Task {
            defer { isSeeding = false }
            do {
                let skipped = try await DebugSeeder.shared.seed()
                status = DeveloperStatus(
                    message: skipped.isEmpty
                        ? "已写入最近 30 天的种子数据"
                        : "已写入种子数据，跳过未授权：\(skipped.joined(separator: "、"))",
                    icon: skipped.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                    isError: false
                )
            } catch {
                status = DeveloperStatus(
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
        status = DeveloperStatus(message: "正在运行自检…", icon: "hourglass", isError: false)

        Task {
            defer { isChecking = false }
            do {
                try await DebugSeeder.shared.selfCheck()
                status = DeveloperStatus(message: "自检完成，结果已输出到控制台", icon: "checkmark.circle.fill", isError: false)
            } catch {
                status = DeveloperStatus(
                    message: "自检失败：\(error.localizedDescription)",
                    icon: "exclamationmark.triangle.fill",
                    isError: true
                )
            }
        }
    }
}

private struct DeveloperStatus {
    let message: String
    let icon: String
    let isError: Bool
}

#Preview {
    NavigationStack {
        DeveloperView()
    }
}
#endif
