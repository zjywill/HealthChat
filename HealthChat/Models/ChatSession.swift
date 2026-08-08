import Foundation

/// 一条独立会话。每条存成一个文件,互不影响。
struct ChatSession: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var messages: [ChatMessage]
    /// 只存 id,话题本身(文案、提示词)随版本改,存全量会把旧文案锁死在文件里。
    var topicId: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        messages: [ChatMessage] = [],
        topicId: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.messages = messages
        self.topicId = topicId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var topic: ChatTopic? { ChatTopics.topic(id: topicId) }

    /// 标题取第一条用户消息,截断到一行能放下的长度;没有就用话题名,再没有才是"新对话"。
    var title: String {
        guard let first = messages.first(where: { $0.role == .user })?.text
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !first.isEmpty
        else {
            return topic?.name ?? "新对话"
        }

        let firstLine = first.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? first
        return firstLine.count <= 24 ? firstLine : "\(firstLine.prefix(24))…"
    }

    var isEmpty: Bool { messages.isEmpty }
}

/// 会话列表要展示的信息。整份会话文件都会被解码,但列表只拿这几项。
struct SessionSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let updatedAt: Date
    let messageCount: Int

    init(_ session: ChatSession) {
        id = session.id
        title = session.title
        updatedAt = session.updatedAt
        messageCount = session.messages.count
    }
}
