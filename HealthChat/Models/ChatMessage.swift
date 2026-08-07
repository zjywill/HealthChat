import Foundation

/// 一条对话消息。toolNotes 记录这轮回复中 agent 做过的健康查询,气泡上方小字展示。
struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable {
        case user
        case assistant
    }

    let id = UUID()
    let role: Role
    var text: String
    var toolNotes: [String] = []
}
