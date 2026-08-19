import Foundation

/// 一个家庭成员。界面上叫「成员」,代码里叫 `Tenant`——用户不认识"租户"这个词,而
/// `Profile` 会和 `InterestProfile`、`AssistantPersona` 撞脸。
///
/// **两类,不是一类东西的两个实例**(见 `Kind`)。这个区别撑着整个功能:Apple Health
/// 不是 app 的全局资源,它是**机主那个成员的属性**。
struct Tenant: Identifiable, Codable, Hashable, Sendable {
    /// 机主恰好一个,家人 0…n。
    ///
    /// iOS 的「健康」App 有家人共享,但 HealthKit **没有把它开放给第三方**——`HKHealthStore`
    /// 读到的永远是本机这台设备主人的库。所以家人成员不是"权限不够",是**那不是他的数据**:
    /// 健康工具在他身上一个都不挂,`HealthSituation` / `SpokenBrief` / check-in 一条都不跑。
    ///
    /// 这不是把功能砍了一半。家人要回答的问题本来就在另一处——化验单(OCR)、用药表、
    /// 聊过的内容,那三样今天已经做完了。
    enum Kind: String, Codable, Sendable {
        case owner
        case managed
    }

    /// 年龄段。**只到段,不到生日。**
    ///
    /// 给它是因为它真的会改变答案(儿童的剂量、老人的参考范围和风险判断);不给生日是因为
    /// 那一天几号一次都用不上,而多给的每一个身份字段都是模型可以说漏嘴的东西——同位置那块
    /// 「坐标一个字都不进 prompt」。
    enum AgeBand: String, Codable, CaseIterable, Identifiable, Sendable {
        case child
        case teen
        case adult
        case senior

        var id: String { rawValue }

        var label: String {
            switch self {
            case .child: String(localized: "儿童")
            case .teen: String(localized: "青少年")
            case .adult: String(localized: "成年人")
            case .senior: String(localized: "老年人")
            }
        }
    }

    let id: UUID
    /// 用户自己起的称呼(「妈妈」「爸爸」「小孩」)。中文里称呼本身就是关系,所以不另设
    /// 一个 relation 字段——两个字段说同一件事,迟早对不上。
    var name: String
    let kind: Kind
    var ageBand: AgeBand?
    let createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: Kind,
        ageBand: AgeBand? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.ageBand = ageBand
        self.createdAt = createdAt
    }

    static let ownerDefaultName = String(localized: "我自己")

    static func owner(id: UUID = UUID(), name: String = ownerDefaultName) -> Tenant {
        Tenant(id: id, name: name, kind: .owner)
    }

    var isOwner: Bool { kind == .owner }

    /// 名字空着时列表和导航栏都得有话说。
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return isOwner ? Self.ownerDefaultName : String(localized: "家人")
    }

    static let maxNameLength = 12

    static func normalized(name: String) -> String {
        String(
            name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxNameLength)
        )
    }
}

extension Tenant {
    /// 进 system 段的那一块。**机主返回 nil**——整份提示词本来就是照着"用户本人"写的,
    /// 再说一句「这是用户本人」是白花 token 说一件已经成立的事。
    ///
    /// 三句话各有各的活,都有测试盯着:
    /// 1. **这不是用户本人**。不说这一句,模型会把化验单上的指标当成用户自己的,后面每一句
    ///    人称都是错的。
    /// 2. **读不到他的健康数据,且没有对应工具**。工具确实一个都没挂(见
    ///    `CapabilityRegistry.healthChat(includesHealthTools:)`),但不说清楚的话模型会为了
    ///    有话说而去猜一个数字——而"猜出来的数字"正是这个 app 最不能出的错。
    /// 3. **要数值就让用户拍一张**。只说"读不到"是把用户留在原地;说清下一步该干什么,
    ///    这条路才是通的(OCR 那条管线已经在了)。
    var instructionBlock: String? {
        guard !isOwner else { return nil }
        var block = """
        关于这次对话的对象：
        - 你现在处理的是用户家人「\(displayName)」的健康情况，**不是用户本人的**。说到身体状况时指的都是\(displayName)，不要和用户自己的数据混为一谈。
        - \(displayName)的 Apple 健康和可穿戴数据你**读不到**，也没有查这些数据的工具。他的情况只来自这条对话里说过的话、用药与补剂清单，以及用户拍给你的化验单、报告或说明书。
        - 需要具体数值时，请用户拍一张化验单或报告发给你，不要凭印象猜，也不要说「我看到数据显示……」这种话——你没有他的数据。
        """
        if let ageBand {
            block += "\n- \(displayName)是\(ageBand.label)。参考范围、风险判断和注意事项都按这个年龄段来说；具体用药和剂量仍然交给医生。"
        }
        return block
    }
}
