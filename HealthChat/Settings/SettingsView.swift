import SwiftUI

/// TODO(M4):引擎选择(自动/端上/Claude)+ API key 输入(存 Keychain)+ 模型切换。
struct SettingsView: View {
    var body: some View {
        Form {
            Section("引擎") {
                LabeledContent("当前", value: "Echo(占位)")
            }
            Section("Claude API") {
                Text("M4:API key 输入,存 Keychain")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("设置")
    }
}
