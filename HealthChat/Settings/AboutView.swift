import SwiftUI

/// 设置页最后那一格。三样东西:免责声明、隐私说明、版本。
///
/// **免责声明排第一。** 在这一页出现之前,全 app 只有首屏欢迎卡底下那一行小字
/// (「健康分析仅供参考,不能替代专业医疗建议」),而它在发出第一条消息之后就再也找不到了。
/// 一个会解读化验单的 app,这句话必须有一个用户想找的时候找得到的固定位置。
struct AboutView: View {
    var body: some View {
        Form {
            Section {
                Text(DataUseNotice.medicalDisclaimer)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } header: {
                Text("免责声明")
            }

            Section {
                NavigationLink {
                    ScrollView {
                        DataUseNoticeContent()
                            .padding(20)
                    }
                    .background(Color(.systemGroupedBackground))
                    .navigationTitle("数据去哪儿")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("数据会发送到哪里", systemImage: "arrow.up.forward.app")
                }

                NavigationLink {
                    PrivacyPolicyView()
                } label: {
                    Label("隐私说明", systemImage: "hand.raised")
                }
            } footer: {
                Text("和你第一次打开 Vana 时看到的是同一份。")
            }

            Section {
                LabeledContent("版本", value: AppInfo.version)
                Link(destination: AppInfo.repository) {
                    Label("项目地址", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum AppInfo {
    static let repository = URL(string: "https://github.com/zjywill/HealthChat")!

    /// "1.0 (1)"。build 号要带上——TestFlight 那几轮里用户报问题时,只有版本号是分不清的。
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return short
        }
        return "\(short) (\(build))"
    }
}

#Preview {
    NavigationStack {
        AboutView()
    }
}
