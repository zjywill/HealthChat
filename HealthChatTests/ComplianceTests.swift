import Foundation
import Testing

@testable import HealthChat

/// 上架合规的那几条。盯的全是**静默失灵**:权限面板上那句话和 app 实际做的事对不上、
/// 隐私说明的资源没打进包(界面上只表现为一页空白)、告知里少了一条会发出去的东西。
///
/// 这几样共同的特点是没人会在日常使用里发现——用户读不到 plist,而那一页空白只有真的
/// 点进去才看得见。
@Suite("Compliance")
struct ComplianceTests {

    // MARK: - 权限用途字符串

    /// 端上模型 2026-08-08 撤掉之后,这句话在健康授权面板上一度还写着「端上模型模式下数据
    /// 不离开设备」——在用户做决定的那一刻许一个 app 已经做不到的诺。
    @Test("健康授权面板上不许再出现「数据不离开设备」那类话")
    func healthPurposeStringDoesNotPromiseOnDevice() throws {
        let text = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") as? String
        )
        // 盯的是「数据留在本机」这个**结论**,不是「不离开」这三个字:这句话里
        // 「原始样本不会离开这台设备」是真的,也该留着。
        #expect(!text.contains("端上"))
        #expect(!text.contains("本地模型"))
        #expect(!text.contains("数据不离开"))
        #expect(!text.contains("不会离开这台设备。"), "别把限定语丢了写成一句无条件的承诺")
    }

    @Test("两句健康用途都写明了聚合数值会发给云端模型")
    func healthPurposeStringsDisclose() throws {
        for key in [
            "NSHealthShareUsageDescription",
            "NSHealthClinicalHealthRecordsShareUsageDescription"
        ] {
            let text = try #require(Bundle.main.object(forInfoDictionaryKey: key) as? String)
            #expect(text.contains("发送"), "\(key) 没说数据会发出去")
            #expect(text.contains("模型"), "\(key) 没说发给谁")
            #expect(text.contains("不会修改"), "\(key) 没说只读")
        }
    }

    /// 麦克风那句同样要和实际做的事逐字对上:识别在本机、录音不保存、松开不自动发送。
    /// 这三件里任何一件写错,都是在用户按「允许」的那一刻许一个做不到的诺。
    ///
    /// 顺带盯住**没有**声明语音识别权限:新的 `SpeechAnalyzer` 是本机识别,不走
    /// `SFSpeechRecognizer` 那条 TCC。声明一个从不申请的权限是白送审核一个问号。
    @Test("麦克风用途写清了本机识别、不保存录音")
    func microphonePurposeStringIsAccurate() throws {
        let text = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
        )
        #expect(text.contains("本机"))
        #expect(text.contains("不会保存") || text.contains("不保存"))
        #expect(text.contains("发送"), "没说清文字要等他按发送才发出去")

        let speech = Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription")
        #expect(speech == nil, "本机识别不申请这条权限，声明了就是白送审核一个问号")
    }

    /// `GENERATE_INFOPLIST_FILE` 开着时这两项由构建设置(`MARKETING_VERSION` /
    /// `CURRENT_PROJECT_VERSION`)生成,写在基础 plist 里的那两行会被盖掉。少了它们,build
    /// 传不上 App Store Connect,而本地跑起来一切正常——「关于」那行版本显示成一个破折号
    /// 是唯一的迹象。
    @Test("版本号两项都在")
    func declaresVersion() throws {
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
            #expect(value?.isEmpty == false, "\(key) 缺失")
        }
        #expect(!AppInfo.version.contains("—"))
    }

    /// 不写这个键的话,每次往 App Store Connect 传 build 都会被拦下来问一遍。
    @Test("出口合规那个键在,而且是 false")
    func declaresExportCompliance() throws {
        let value = Bundle.main.object(forInfoDictionaryKey: "ITSAppUsesNonExemptEncryption")
        #expect(value as? Bool == false)
    }

    // MARK: - 隐私说明

    /// app 内那一页和要发布的那份是同一个文件。掉了资源的话界面上只是一页空白——
    /// 而这一页是有硬性要求的那种页面。
    @Test("隐私说明打进了 app 包")
    func privacyPolicyIsBundled() throws {
        let url = try #require(PrivacyPolicy.fileURL, "PrivacyPolicy.html 没进 app 包")
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("Vana 隐私说明"))
        #expect(html.count > 2000, "内容像是被截断了")
    }

    /// 一份隐私政策里少了任何一条,都是一次没做到的告知。这里只盯最容易在改写中被丢掉的几条。
    @Test("隐私说明覆盖了必须说的几件事")
    func privacyPolicyCoversRequiredTopics() throws {
        let url = try #require(PrivacyPolicy.fileURL)
        let html = try String(contentsOf: url, encoding: .utf8)

        // 生效日期、联系方式:App Store 审核会核对的两项。
        #expect(html.contains("生效日期"))
        #expect(html.contains("mailto:"))
        // HealthKit 的硬性要求:只读、不用于广告或数据挖掘、不进 iCloud。
        #expect(html.contains("只读"))
        #expect(html.contains("数据挖掘"))
        #expect(html.contains("iCloud"))
        // 删除路径和儿童条款。
        #expect(html.contains("删除"))
        #expect(html.contains("儿童"))
        // 最后那段医疗免责。
        #expect(html.contains("急救"))
    }

    // MARK: - 首次使用那一屏

    @Test("正反两组都在，而且各自说了具体的东西")
    func noticeStatesBothDirections() {
        let leaving = DataUseNotice.leaves.points.joined()
        #expect(leaving.contains("聚合"), "没说清发出去的是聚合值不是原始样本")
        #expect(leaving.contains("城市"))
        #expect(leaving.contains("识别出来的文字"))

        let staying = DataUseNotice.stays.points.joined()
        #expect(staying.contains("照片和文件原件"))
        #expect(staying.contains("坐标"))
        #expect(staying.contains("API key"))
        // 麦克风是这份告知里最新的一条,也是最容易在改写中掉队的:它和照片同类
        // (原件留在本机,只发识别出来的文字),但走的是另一条写入路径。
        #expect(staying.contains("录音"))
    }

    /// 「保护你的隐私」这类话不可验证,写了等于没写。这条盯的是那一屏没有退化成一句套话。
    @Test("三组内容都不为空")
    func noticeGroupsAreComplete() {
        #expect(DataUseNotice.groups.count == 3)
        for group in DataUseNotice.groups {
            #expect(!group.points.isEmpty, "\(group.title) 是空的")
            #expect(!group.title.isEmpty)
        }
    }

    /// 免责声明的三段各有各的活:不是医生、模型会出错、急症怎么办。最后一段最容易在精简时
    /// 被合并掉,而它是唯一一句要在几秒钟内被想起来的。
    @Test("免责声明里有急症那一段")
    func disclaimerCoversEmergencies() {
        let text = DataUseNotice.medicalDisclaimer
        #expect(text.contains("不是医疗器械"))
        #expect(text.contains("剂量"))
        #expect(text.contains("急救电话"))
        #expect(text.contains("立即就医"))
    }

    // MARK: - 急症规则

    /// 这三条是 system 段里唯一「先别答」的规则,而且**对家人成员一样发**——他那边健康工具
    /// 整组不挂,但描述胸痛的可能正是他。
    @Test("急症规则两种成员都发", arguments: [true, false])
    func emergencyRuleIsAlwaysSent(hasHealthData: Bool) {
        let text = HealthAssistantInstructions.text(hasHealthData: hasHealthData)
        #expect(text.contains("急症优先于一切"))
        #expect(text.contains("急救电话"))
        #expect(text.contains("胸痛"))
        // 自伤那条单独一句:它和急症的处理方式不一样(不是打 120,是危机热线和身边的人)。
        #expect(text.contains("伤害自己"))
        #expect(text.contains("危机热线"))
        #expect(text.contains("方法性"))
    }

    /// 少了这一条,助手会把每一次疲劳都升级成急诊建议——那等于没有前面两条。
    @Test("急症规则自带一条别滥用")
    func emergencyRuleIsBounded() {
        let text = HealthAssistantInstructions.text()
        #expect(text.contains("不要滥用"))
        #expect(text.contains("疲劳"))
    }

    /// 排在所有规则最前面。排到第十条和没写没有区别。
    @Test("急症规则排在第一条")
    func emergencyRuleComesFirst() throws {
        let text = HealthAssistantInstructions.text()
        let emergency = try #require(text.range(of: "急症优先于一切"))
        for later in ["先调用合适的健康工具", "只引用工具实际返回的数字", "不要做医疗诊断"] {
            let range = try #require(text.range(of: later), "\(later) 不在提示词里了")
            #expect(emergency.lowerBound < range.lowerBound, "急症那条掉到「\(later)」后面去了")
        }
    }

    // MARK: - 「AI 生成」标在哪条上

    /// 报错和占位那两种气泡也是 assistant,但字是 app 写的。在它们下面标一句「以上由 AI 生成」,
    /// 是拿一句诚实的话去说一件不实的事——第一版就标在了「无法回复：需要先在设置里填写云端
    /// API key」下面。
    @Test("app 自己写的那几种气泡不算模型输出")
    func appWrittenBubblesAreNotLabelled() {
        var reply = ChatMessage(role: .assistant, text: "昨晚睡了 6.2 小时，比常态少 100 分钟。")
        #expect(reply.isModelWritten)

        reply.errorDescription = "需要先在设置里填写云端 API key"
        #expect(!reply.isModelWritten, "报错气泡被当成了模型输出")

        let placeholder = ChatMessage(role: .assistant, text: "已停止回复", textIsPlaceholder: true)
        #expect(!placeholder.isModelWritten)

        let empty = ChatMessage(role: .assistant, text: "")
        #expect(!empty.isModelWritten)

        let asked = ChatMessage(role: .user, text: "我昨晚睡得怎么样")
        #expect(!asked.isModelWritten)
    }

    // MARK: - 不进备份

    /// HealthKit 的规矩是健康数据不许进 iCloud,而 `Documents/` 默认要进设备备份。
    /// 这条盯的是标记真的落到了盘上——漏了不会有任何迹象,直到用户的化验单出现在一份备份里。
    @Test("成员数据整个排除出备份")
    func tenantDataIsExcludedFromBackup() throws {
        let parent = URL.temporaryDirectory.appending(path: "backup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        // 迁移失败退回单人模式的那份布局:数据直接躺在 parent 下。
        let legacy = parent.appending(path: "memory.json", directoryHint: .notDirectory)
        try Data("{}".utf8).write(to: legacy)

        TenantPaths.excludeFromBackup(parent: parent)

        let root = parent.appending(path: TenantPaths.rootName, directoryHint: .isDirectory)
        for url in [root, legacy] {
            let values = try url.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true, "\(url.lastPathComponent) 还会进备份")
        }
    }

    /// 盘上的行为和隐私说明必须逐字对上。上一版这两处正好相反——文件里写着"会包含在你自己的
    /// 备份里",而代码已经把它排除了。
    @Test("隐私说明里写了不进备份，也写了代价")
    func privacyPolicyMatchesBackupBehavior() throws {
        let url = try #require(PrivacyPolicy.fileURL)
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(html.contains("不进备份"))
        #expect(html.contains("换新手机"))
        #expect(!html.contains("会包含在<strong>你自己的</strong>设备备份里"))
    }
}
