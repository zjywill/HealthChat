import SwiftUI

/// 第一次打开时说清楚:**你的健康数据会去哪儿**。
///
/// 在这之前 app 里唯一提到「问题要发给云端模型」的地方是隐私会话那张卡
/// (`ChatView.privacyNote`),而它只在用户主动开了隐私对话时才显示——也就是说,绝大多数人
/// 从头到尾没被告知过。首屏欢迎卡说的是「Vana 只读取你授权的数据,不会修改健康记录」,
/// 只讲了不写回,没讲会发出去。
///
/// 几条边界:
///
/// - **一屏说完,只讲三件事**:什么会发出去、什么不会、发给谁。写成一份条款就没人读,而这一屏
///   的全部价值就是它真的被读到了一次。真要看细节的走底下那行「隐私说明」。
/// - **正反两组都要有,不能只写「我们保护你的隐私」**。可信来自具体:「照片原件不会离开这台
///   设备,只发识别出来的文字」是可以被验证的一句话,「我们重视你的隐私」不是。
/// - **不做成一次同意书**。没有勾选框、没有「同意并继续」——那个形状暗示这里在签一份协议,
///   而实际发生的事只是告知。按钮就写「开始使用」。
/// - **这是设备级的,不跟着成员走**(同 provider、model、API key)。它说的是「这台手机怎么
///   工作」,不是「我和谁在聊」,所以不在 `TenantPaths.perTenantItems` 里。
enum DataUseNotice {
    /// 见过这一屏没有。老用户升级上来也会看到一次——这段告知本来就是新的。
    static let acceptedKey = "hasAcceptedDataUseNotice"

    struct Group: Identifiable {
        let icon: String
        let title: String
        let tint: Color
        let points: [String]

        var id: String { title }
    }

    /// 会离开这台设备的。**逐条对着代码写**,多写一条是许一个空诺,少写一条是漏一次告知。
    static let leaves = Group(
        icon: "arrow.up.forward.app",
        title: "会发给你配置的模型服务",
        tint: .orange,
        points: [
            "你打的字，以及这条对话里的往来",
            "从 Apple 健康读到的聚合数值，例如「8 月 6 日睡眠 6.2 小时」",
            "化验单、报告、药盒在本机识别出来的文字",
            "本机认不出文字的那种照片——只有你自己点了「让 Vana 直接看图」的那几张",
            "你所在的城市（授权了位置的话）",
            "长期记忆和用药表里的内容（没关掉的话）"
        ]
    )

    static let stays = Group(
        icon: "iphone",
        title: "不会离开这台设备",
        tint: .green,
        points: [
            "照片和文件原件——识别在本机做，默认只发识别出来的文字；认出了字的（化验单、药盒）连问都不会问你",
            "按住说话的录音——识别在本机做，录音不保存，只留识别出来的文字",
            "经纬度坐标——只发城市名，坐标一个字都不发",
            "你的 API key——只在系统钥匙串里",
            "对话记录、记忆、用药表——存在本机，没有云端副本，也不进 iCloud 备份"
        ]
    )

    static let noServer = Group(
        icon: "network.slash",
        title: "Vana 自己没有服务器",
        tint: .secondary,
        points: [
            "没有账号，没有后台，没有任何统计埋点",
            "开发者看不到你的数据——它不经过我们的任何一台机器",
            "发给哪家模型服务由你决定，对方如何处理适用它自己的隐私政策"
        ]
    )

    static let groups: [Group] = [leaves, stays, noServer]

    /// 免责。分三段,最后一段是急症——把它放在最后一段而不是塞进第一段的从句里,是因为
    /// 那是这三段里唯一一句要在几秒钟内被想起来的话。
    static let medicalDisclaimer = """
        Vana 不是医疗器械，也不是医生。它给出的分析基于你的健康数据和一个通用语言模型，仅供参考，\
        不构成医疗诊断、治疗方案或用药建议，也不会给出任何剂量建议，不能替代医生、药师或其他专业医疗人员的判断。

        模型会出错——它可能读错化验单上的一个小数点，也可能把一段过去的数据当成最近的。\
        据此做出的任何健康决定，请先和专业人员确认。

        身体出现急症（例如胸痛、呼吸困难、意识改变、严重出血），或者有伤害自己的念头时，\
        请立即就医或拨打当地急救电话，不要等 Vana 回答。
        """
}

// MARK: - 首次使用的那一屏

struct DataUseNoticeSheet: View {
    let onAccept: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.pink)
                            .accessibilityHidden(true)

                        Text("Vana 要靠一个模型来回答你的问题，而那个模型跑在你自己选的那家服务上。所以有些东西必须发出去，有些不用——这一屏说清是哪些。")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DataUseNoticeContent()

                    Text(DataUseNotice.medicalDisclaimer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .padding(.bottom, 8)
            }
            .background(Color(.systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 12) {
                    NavigationLink {
                        PrivacyPolicyView()
                    } label: {
                        Text("完整的隐私说明")
                            .font(.subheadline)
                    }

                    Button(action: onAccept) {
                        Text("开始使用")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 14))
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.bar)
            }
            // 标题交给导航栏,不自己画一个。这一屏没有返回键,看着像"没有导航栏",但那条栏
            // 是滚动时把文字和状态栏隔开的那层材质——自己画标题的话,滚两行就有一句话压在
            // 时间上面。
            .navigationTitle("在开始之前")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

/// 三组内容本身。首次那一屏和「设置 > 关于 > 数据会发送到哪里」是同一份——
/// 用户过两个月想再看一眼时,读到的必须是同样的承诺。
struct DataUseNoticeContent: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(DataUseNotice.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Label {
                        Text(group.title)
                            .font(.headline)
                    } icon: {
                        Image(systemName: group.icon)
                            .foregroundStyle(group.tint)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.points, id: \.self) { point in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)

                                Text(point)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    Color(.secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .accessibilityElement(children: .contain)
            }
        }
    }
}

#Preview("首次使用") {
    DataUseNoticeSheet(onAccept: {})
}
