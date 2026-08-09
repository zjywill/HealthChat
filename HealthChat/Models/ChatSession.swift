import Foundation

/// 一条独立会话。每条存成一个文件,互不影响。
struct ChatSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var messages: [ChatMessage]
    /// 只存 id,话题本身(文案、提示词)随版本改,存全量会把旧文案锁死在文件里。
    var topicId: String?
    /// 这条会话属于哪条延续线(每日 check-in、某条待跟进、用户自己开的目标)。普通对话没有。
    ///
    /// 只存 id,同 `topicId`。
    var threadId: String?
    /// 这一段是 app 替他问的,不是他自己开口的(到期的待跟进、目标的周进展)。
    ///
    /// 有这个标记才分得清"他问过什么"和"我们替他问过什么"。最要紧的一处是兴趣统计:
    /// 后台替他查了三次睡眠,不代表他关心睡眠——`InterestProfile` 数的是**他点过的东西**,
    /// 混进机器自己点的,那份统计就开始自己喂自己。
    var isDerived = false
    /// 用户给这条线起的名字。只有目标线有——check-in 和待跟进的名字是内置的。
    ///
    /// 每一段都存一份,不另开一张"目标表"。一段一段往下传看着冗余,换来的是这条线的名字和它的
    /// 内容永远在同一个文件里:删掉最后一段,这条线就干净地不存在了,不会剩下一条指着空处的定义。
    var threadTitle: String?
    /// 隐私会话:这一段不留任何本机痕迹。不落盘、不进会话列表、不写记忆、不进兴趣统计。
    ///
    /// 承诺的边界只到本机为止——问题照样要发给用户配置的云端模型才能回答,这一点界面上
    /// 明说(`ChatView.privacyNote`)。含糊其辞地暗示"端到端隐私"才是真的逗人玩;写清楚
    /// 它挡住的是什么,这个开关反而是可信的。
    ///
    /// 不参与编解码——会话文件里出现一条"不落盘"的会话本身就是矛盾的。
    var isPrivate = false
    /// 已经抽过记忆的水位:抽取时这条会话有多少条消息。
    ///
    /// 存在会话文件里而不是内存里——不然每次打开一条老会话再关掉,都会为同一段对话
    /// 重跑一次抽取。
    var memoryHarvestedMessageCount = 0
    var createdAt: Date
    var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, messages, topicId, threadId, threadTitle, isDerived, memoryHarvestedMessageCount, createdAt, updatedAt
    }

    init(
        id: UUID = UUID(),
        messages: [ChatMessage] = [],
        topicId: String? = nil,
        threadId: String? = nil,
        threadTitle: String? = nil,
        isDerived: Bool = false,
        isPrivate: Bool = false,
        memoryHarvestedMessageCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.messages = messages
        self.topicId = topicId
        self.threadId = threadId
        self.threadTitle = threadTitle
        self.isDerived = isDerived
        self.isPrivate = isPrivate
        self.memoryHarvestedMessageCount = memoryHarvestedMessageCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        messages = try container.decode([ChatMessage].self, forKey: .messages)
        topicId = try container.decodeIfPresent(String.self, forKey: .topicId)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        threadTitle = try container.decodeIfPresent(String.self, forKey: .threadTitle)
        isDerived = try container.decodeIfPresent(Bool.self, forKey: .isDerived) ?? false
        // 后加的字段,旧会话文件里没有。当成"一次都没抽过"——顶多多抽一次,不会丢东西。
        memoryHarvestedMessageCount = try container.decodeIfPresent(
            Int.self,
            forKey: .memoryHarvestedMessageCount
        ) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var topic: ChatTopic? { ChatTopics.topic(id: topicId) }
    var thread: SessionThread? { threadId.flatMap(SessionThread.init(id:)) }

    /// 界面上这条会话叫什么。算法和索引那份共用一份(`SessionTitle`)——各写一遍迟早会漂,
    /// 而漂的结果是列表上一个名字、召回结果里另一个名字。
    var title: String {
        SessionTitle.make(
            threadId: threadId,
            threadTitle: threadTitle,
            topicId: topicId,
            firstUserText: messages.first { $0.role == .user }?.text,
            createdAt: createdAt
        )
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// 会话列表要展示的信息。
///
/// 从索引来,不从整份会话来:列表只要一个标题和一个条数,为它把一年的对话解成对象图
/// 是这个 app 里最贵的一次白干。
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int
    /// 属于哪条延续线。列表把这几条挑出来单独放一组。
    let threadId: String?

    init(
        id: UUID = UUID(),
        title: String,
        updatedAt: Date,
        messageCount: Int = 0,
        threadId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
        self.messageCount = messageCount
        self.threadId = threadId
    }

    init(_ entry: SessionIndexEntry) {
        id = entry.id
        title = entry.title
        updatedAt = entry.updatedAt
        messageCount = entry.messageCount
        threadId = entry.threadId
    }

    var thread: SessionThread? { threadId.flatMap(SessionThread.init(id:)) }
}
