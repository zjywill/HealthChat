import Foundation

/// 会话文件里**列表和检索要用的那一小部分**。
///
/// 会话文件是这个 app 里最大的一类数据:一轮里两次健康查询的原始输出就有一万多字符,而
/// `storedTurn.exactTranscript` 会把同样的文本再存一份给模型回放用。整份解出来是一张很大的
/// 对象图,而列表只想要一个标题、召回只想要用户说过的话。
///
/// 所以这里**只声明用得上的键**。`JSONDecoder` 不会去实例化没声明的那些——省掉的正是最大的
/// 那半边(每条工具结果、每份 `HealthReport` 的逐小时序列)。
///
/// 真要读某一条会话的全文,走 `SessionStore.load(id:)`,那是一次一条。
struct SessionIndexEntry: Decodable, Sendable, Identifiable {
    let id: UUID
    let topicId: String?
    let threadId: String?
    let threadTitle: String?
    /// 这一段是 app 替他问的。见 `ChatSession.isDerived`。
    let isDerived: Bool
    let createdAt: Date
    let updatedAt: Date
    let messageCount: Int
    let title: String
    /// 用户说过的话拼在一起,小写,给检索打分用。
    ///
    /// **不含助手的回复**:那几段什么都提一句(「睡眠、心率、活动量都还行」),放进来的话每条
    /// 会话都能匹配上任何查询,检索就退化成按时间倒序。顺带也让这份常驻索引小了一个数量级。
    let userText: String
    /// 这条会话里查过哪几个工具,去重且保序。
    let toolNames: [String]

    var isEmpty: Bool { messageCount == 0 }
    var thread: SessionThread? { threadId.flatMap(SessionThread.init(id:)) }

    /// 常驻内存的上限。有人把一整段体检报告贴进对话里,不该让它一个人把索引撑大。
    static let maxUserTextCharacters = 1_200

    private enum CodingKeys: String, CodingKey {
        case id, topicId, threadId, threadTitle, isDerived, messages, createdAt, updatedAt
    }

    /// 一条消息里索引用得上的部分。`storedTurn`、`reasoning`、工具的输入输出一概不声明。
    private struct SlimMessage: Decodable {
        let role: ChatMessage.Role
        let text: String
        let toolNames: [String]
        /// 只问「有没有」,不解出来。照片识别出来的文本可能有几千字,而索引常驻内存——
        /// 把它们留在这儿,就是为一个只用来定标题的判断付一整年的内存。
        let hasAttachments: Bool

        private enum CodingKeys: String, CodingKey {
            case role, text, toolCalls, attachments
        }

        private struct SlimToolCall: Decodable {
            let name: String
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decode(ChatMessage.Role.self, forKey: .role)
            text = (try? container.decode(String.self, forKey: .text)) ?? ""
            toolNames = ((try? container.decodeIfPresent([SlimToolCall].self, forKey: .toolCalls)) ?? [])?
                .map(\.name) ?? []
            hasAttachments = container.contains(.attachments)
        }
    }

    /// 从手里已经有的整份会话直接折出索引项。
    ///
    /// 存在的意义是让"文件解出来的"和"内存里现成的"永远经过同一套推导——两条路各写一遍,
    /// 迟早出现列表上一个标题、召回结果里另一个标题。
    init(_ session: ChatSession) {
        id = session.id
        topicId = session.topicId
        threadId = session.threadId
        threadTitle = session.threadTitle
        isDerived = session.isDerived
        createdAt = session.createdAt
        updatedAt = session.updatedAt
        messageCount = session.messages.count
        title = session.title

        var seen = Set<String>()
        toolNames = session.messages
            .flatMap { $0.toolCalls.map(\.name) }
            .filter { seen.insert($0).inserted }

        let spoken = session.messages
            .filter { $0.role == .user }
            .map(\.text)
            .joined(separator: "\n")
            .lowercased()
        userText = String(spoken.prefix(Self.maxUserTextCharacters))
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        topicId = try container.decodeIfPresent(String.self, forKey: .topicId)
        threadId = try container.decodeIfPresent(String.self, forKey: .threadId)
        threadTitle = try container.decodeIfPresent(String.self, forKey: .threadTitle)
        isDerived = try container.decodeIfPresent(Bool.self, forKey: .isDerived) ?? false
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        let messages = try container.decode([SlimMessage].self, forKey: .messages)
        messageCount = messages.count
        let firstSpoken = messages.first { $0.role == .user }
        title = SessionTitle.make(
            threadId: threadId,
            threadTitle: threadTitle,
            topicId: topicId,
            firstUserText: firstSpoken?.text,
            firstUserHasAttachments: firstSpoken?.hasAttachments ?? false,
            createdAt: createdAt
        )

        var seen = Set<String>()
        toolNames = messages
            .flatMap(\.toolNames)
            .filter { seen.insert($0).inserted }

        let spoken = messages
            .filter { $0.role == .user }
            .map(\.text)
            .joined(separator: "\n")
            .lowercased()
        userText = spoken.count <= Self.maxUserTextCharacters
            ? spoken
            : String(spoken.prefix(Self.maxUserTextCharacters))
    }
}

/// 会话在列表上叫什么。
///
/// 两个读者算的必须是同一个:界面走 `ChatSession.title`(手里是整份会话),索引走
/// `SessionIndexEntry`(手里只有解出来的那几个键)。各写一遍迟早会漂,而漂的结果是
/// 列表上一个名字、召回结果里另一个名字。
enum SessionTitle {
    static func make(
        threadId: String?,
        threadTitle: String?,
        topicId: String?,
        firstUserText: String?,
        /// 第一句话是一张照片,一个字都没打。不认这一条的话,列表上那行会一直叫「新对话」。
        firstUserHasAttachments: Bool = false,
        createdAt: Date
    ) -> String {
        // 延续线用线程名。一条攒了四天 check-in 的会话首条消息是「昨晚睡得怎么样？」——
        // 拿它当标题,列表里就会出现好几条一模一样的名字,而它们本该是一件事的几段。
        if let thread = threadId.flatMap(SessionThread.init(id:)) {
            let name = threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(localized: "\(name?.isEmpty == false ? name! : thread.title) · \(SessionRecall.dateLabel(createdAt))起")
        }

        let first = firstUserText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !first.isEmpty else {
            if firstUserHasAttachments { return "照片" }
            return ChatTopics.topic(id: topicId)?.name ?? "新对话"
        }
        let firstLine = first.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? first
        return firstLine.count <= 24 ? firstLine : "\(firstLine.prefix(24))…"
    }
}
