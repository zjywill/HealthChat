import Foundation

/// 用户和某一样药或补剂的关系。
///
/// **这不是一条排程,是一次判断的结果。** Apple Health 从 iOS 26 起有完整的用药追踪(排程、
/// 提醒、打卡、依从性),那套回答的是「我今天该吃什么、吃了没」;这张表回答的是「我和这个
/// 东西是什么关系」——为什么开始吃的、什么情况下吃、**有没有用**。
///
/// 最后那一样是这张表存在的理由:`HKMedicationDoseEvent` 里没有一个字段叫「吃了没感觉」,
/// 而这个功能的产生场景本来就是一次问答("我头疼吃什么""冬天要不要补点什么"),要记下来的
/// 是那次判断和后来的结果。
struct MedicationItem: Identifiable, Equatable, Codable, Sendable {
    /// 这条是怎么来的。三态和 `MemoryItem.Origin` 一致,理由也一致:界面上每条都要能回答
    /// 「这句哪来的」,分不清是自己写的还是模型记的,用户就没法判断该不该信它。
    enum Origin: String, Codable, Sendable {
        /// 在用药页里手写或改过的。
        case manual
        /// 对话里让 Vana 记的(`log_medication`)。
        case asked
        /// 从 Apple Health 的用药清单来的。**第一版不产生这一类**,留着是为了将来接上时
        /// 不用改文件格式(见 `MEDICATIONS.md` 第八节)。
        case health
    }

    let id: UUID
    var name: String
    var status: MedicationStatus
    /// 什么情况下吃。「头疼时」「冬天」「每天早上」——`asNeeded` 主要用。
    var when: String
    /// 为什么吃 / 谁让吃的。
    var reason: String
    /// **他自己的效果评价。这张表最值钱的一列。**
    ///
    /// 一般功效说明(`brief`)网上到处都是,模型也随时能重写一遍;「我试了两周没感觉」只有
    /// 他知道,而且正是它决定了下次该不该再推荐这个东西。
    var outcome: String
    /// 一般功效说明。模型生成的(`MedicationBriefer`),不是给他的建议。
    var brief: String
    /// 用户改过 `brief`。改过的不许被重新生成悄悄盖掉——同 `MemoryItem.pinned` 那条:
    /// 他改成那样就是不认同模型的说法,后台跑一遍又改回去,等于这个编辑页是假的。
    var briefIsUserWritten: Bool
    var note: String
    var origin: Origin
    /// 说好过一阵子回来看有没有用。
    ///
    /// **这是这个功能的闭环。** 没有它 `outcome` 那一列永远是空的,这张表就只增不减,
    /// 三个月后是一份三十条的死清单。到期进早上那条 check-in,和 `MemoryItem.dueAt` 同一条路。
    var followUpAt: Date?
    var startedAt: Date?
    var createdAt: Date
    var updatedAt: Date
    /// 预留:将来接 Apple Health 时用 `HKHealthConceptIdentifier` 对上号。
    var healthConceptId: String?

    init(
        id: UUID = UUID(),
        name: String,
        status: MedicationStatus = .asNeeded,
        when: String = "",
        reason: String = "",
        outcome: String = "",
        brief: String = "",
        briefIsUserWritten: Bool = false,
        note: String = "",
        origin: Origin = .manual,
        followUpAt: Date? = nil,
        startedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        healthConceptId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.when = when
        self.reason = reason
        self.outcome = outcome
        self.brief = brief
        self.briefIsUserWritten = briefIsUserWritten
        self.note = note
        self.origin = origin
        self.followUpAt = followUpAt
        self.startedAt = startedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.healthConceptId = healthConceptId
    }

    /// 说好回头看的那天到了。
    func isFollowUpDue(at now: Date) -> Bool {
        guard let followUpAt else { return false }
        return followUpAt <= now
    }

    /// 进 system 段那一行里跟在名字后面的那半句。
    ///
    /// 按状态取不同的字段:在吃的要知道**为什么**吃(那是它和健康数据的接口),需要时吃的要
    /// 知道**什么时候**吃,试过的要知道**结果**——那正是"别再推荐一次"的依据。
    var snapshotDetail: String {
        let parts: [String]
        switch status {
        case .cannotTake:
            parts = [reason, note]
        case .ongoing:
            parts = [reason, when]
        case .asNeeded:
            parts = [when, outcome]
        case .tried:
            parts = [outcome, reason]
        }
        return parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }

    /// 以这一条为话题时写进 system 段的那一段。
    ///
    /// 不给话题(同延续线那条):今天问副作用、明天问要不要继续,话题写死在提示里第三天就和
    /// 正在问的事对不上了。这里只交代「围绕哪一条、他记的是什么」。
    var focusInstruction: String {
        var text = "这条对话围绕他记下的「\(name)」。状态：\(status.title)。"
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { text += "他记的原因是「\(reason)」。" }
        let when = when.trimmingCharacters(in: .whitespacesAndNewlines)
        if !when.isEmpty { text += "他记的服用情况是「\(when)」。" }
        let outcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outcome.isEmpty { text += "他自己的评价是「\(outcome)」。" }
        text += """
            照常查健康数据回答，把变化和这件事挂上钩，\
            但不要建议他调整剂量、停药或换药——那要问开药的医生或药师。
            """
        return text
    }

    /// 空会话时那三条开场建议。
    ///
    /// 本地拼,不花模型调用(同 `ChatTopic.questions`)。按状态给不同的三条:「试过了」那一类
    /// 该问的是要不要换一个,「长期在吃」该问的是和数据有没有关系——用同一组问题就等于
    /// 没分状态。
    var openingQuestions: [String] {
        switch status {
        case .cannotTake:
            [
                String(localized: "为什么我会对它有反应？"),
                String(localized: "有什么要避开的？"),
                String(localized: "有别的选择吗？")
            ]
        case .ongoing:
            [
                String(localized: "它和我最近的数据有关系吗？"),
                String(localized: "吃了这么久有变化吗？"),
                String(localized: "有什么要注意的？")
            ]
        case .asNeeded:
            [
                String(localized: "什么情况下该吃它？"),
                String(localized: "吃得太频繁了吗？"),
                String(localized: "有别的办法吗？")
            ]
        case .tried:
            [
                String(localized: "为什么对我没用？"),
                String(localized: "要不要换一个试试？"),
                String(localized: "是不是时间不够？")
            ]
        }
    }
}

/// 四种关系,**按对模型的要紧程度排**。
///
/// `allCases` 的顺序就是 system 段和界面上的顺序,别随手改:`cannotTake` 排第一是安全相关的,
/// 它必须在模型开口建议任何东西之前就已经在视野里。
enum MedicationStatus: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 过敏、不耐受、医生禁的。**永远排第一,永远不被裁掉。**
    case cannotTake
    /// 长期在吃:他汀、降压药、每天的维生素 D。是所有健康分析的前提。
    case ongoing
    /// 需要时吃:头疼吃布洛芬、睡不着吃褪黑素。带触发条件。
    case asNeeded
    /// 试过了(有用 / 没用 / 有反应)。
    ///
    /// 这一类是这个功能的隐藏价值:用户问「睡不好怎么办」,Vana 第二次又建议褪黑素,而他
    /// 三个月前试过没用还专门记了下来——那一刻这个 app 就显得没在听。
    case tried

    var id: String { rawValue }

    /// 界面上的名字,也是 system 段里的标签。两处叫法不一致,用户在列表里看到的东西就和
    /// 模型看到的对不上了(同 `MemoryKind.title`)。
    var title: String {
        switch self {
        case .cannotTake: String(localized: "不能吃")
        case .ongoing: String(localized: "长期在吃")
        case .asNeeded: String(localized: "需要时吃")
        case .tried: String(localized: "试过了")
        }
    }

    var hint: String {
        switch self {
        case .cannotTake: String(localized: "过敏、不耐受、医生说不能用的。Vana 给建议之前一定会先看这一组。")
        case .ongoing: String(localized: "每天或按疗程在吃的。它会成为解读你健康数据时的前提。")
        case .asNeeded: String(localized: "有需要才吃的。记下什么情况下吃，下次问起来 Vana 才接得上。")
        case .tried: String(localized: "试过之后的结论。记下来，Vana 就不会再推荐一次你已经试过的东西。")
        }
    }

    var icon: String {
        switch self {
        case .cannotTake: "hand.raised.slash"
        case .ongoing: "pills"
        case .asNeeded: "cross.case"
        case .tried: "checkmark.circle"
        }
    }
}

/// 一条会话开始时拿到的用药表,**这条会话之内不再变**。
///
/// 理由和 `MemorySnapshot` 一模一样:system 段中途变化打掉 prompt 缓存,也让模型对用户的
/// 认知在一条对话里跳变。所以引擎不许自己去读盘,由 `ChatViewModel` 在会话开始时读好传进去。
struct MedicationSnapshot: Equatable, Sendable {
    static let empty = MedicationSnapshot(items: [])

    /// 进 system 段的行数上限。
    ///
    /// 超了先裁「试过了」那一组(最久没动的先走),**`cannotTake` 一条都不裁**。裁掉的在
    /// `list_medications` 里查得到——那正是那个工具存在的理由。
    static let maxLines = 24
    static let maxCharacters = 800

    let items: [MedicationItem]

    var isEmpty: Bool { items.isEmpty }

    /// 拼进 system 段的那一块。空表返回 nil——不要塞一句「（暂无）」,那只会让模型去解释
    /// 为什么没有。
    var instructionBlock: String? {
        guard !items.isEmpty else { return nil }

        var lines = ["关于他和药/补剂（他自己记的，不是健康数据）："]
        let kept = Self.trimmed(items)
        // 按状态分组重排一遍,不指望传进来的顺序。`MedicationStore` 确实排好了序,但快照是个
        // 值类型,谁都能造一个——而这里排错的后果是「不能吃」掉到第三行去(同 `MemorySnapshot`
        // 按 kind 分组的写法)。
        for status in MedicationStatus.allCases {
            for item in kept where item.status == status {
                let detail = item.snapshotDetail
                lines.append("- 【\(status.title)】\(item.name)\(detail.isEmpty ? "" : " — \(detail)")")
            }
        }
        // 这三句是这个功能真正的产出,不是免责声明:前两句决定了这张表有没有用,第三句是
        // 安全线。少一句就有测试挂。
        lines.append(
            """
                要提到吃什么之前先看这份表：他明确不能吃的绝对不要提；\
                他试过没用的不要再推荐一次，要提也得先说一句「你之前试过」。
                """
        )
        lines.append("剂量一律不给建议，也不要建议他停药或换药——那要问开药的医生或药师。")
        lines.append("""
            这份表只是他自己记下的，不是完整病历；\
            更全的内容（含没列在上面的）用 list_medications 查。
            """)
        return lines.joined(separator: "\n")
    }

    /// 按上限裁一遍。
    ///
    /// 顺序是 `MedicationStatus.allCases`(不能吃在最前),裁的顺序正好相反——从最后一组
    /// 往回裁,而且**永远不动 `cannotTake`**。
    static func trimmed(_ items: [MedicationItem]) -> [MedicationItem] {
        var kept = items
        func isOver() -> Bool {
            kept.count > maxLines
                || kept.reduce(0) { $0 + $1.name.count + $1.snapshotDetail.count } > maxCharacters
        }
        while isOver() {
            let removable = kept.enumerated()
                .filter { $0.element.status != .cannotTake }
                .min { $0.element.updatedAt < $1.element.updatedAt }
            guard let removable else { break }
            kept.remove(at: removable.offset)
        }
        return kept
    }

    /// 说好该回头看的那几条。check-in 用它挑今天早上说什么。
    func due(at now: Date) -> [MedicationItem] {
        items.filter { $0.isFollowUpDue(at: now) }
    }

    /// 按名字找一条。模型引用的是名字,不是短编号——药名本来就短且唯一,用户也是直接说
    /// 名字的;发一串 `M1`/`M2` 只会让 system 段多一列噪声,还多一处能抄错的地方。
    func item(named name: String) -> MedicationItem? {
        let target = MedicationItem.normalize(name)
        guard !target.isEmpty else { return nil }
        return items.first { MedicationItem.normalize($0.name) == target }
    }
}

extension MedicationItem {
    /// 名字匹配用的规范化形式:去空白、忽略大小写。
    static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
