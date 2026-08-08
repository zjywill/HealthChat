import Foundation

/// 一条对话消息。toolNotes 记录这轮回复中 agent 做过的健康查询,气泡上方小字展示。
struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var toolNotes: [String]

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolNotes: [String] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolNotes = toolNotes
    }
}
