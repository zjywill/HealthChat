import SwiftUI

/// TODO(M4):引擎选择(自动/端上/云端)+ API key 输入(存 Keychain)+ provider/模型切换。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("引擎") {
                LabeledContent("当前", value: "Echo(占位)")
            }
            Section("云端引擎(AIKit)") {
                Text("M4:API key 输入,存 Keychain")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}
