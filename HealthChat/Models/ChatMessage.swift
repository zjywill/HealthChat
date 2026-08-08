import Foundation

/// 一次工具调用的完整记录:调用本身和它的结果。
///
/// 存进消息里而不是只留一句"查询了最近 7 天睡眠",是因为下一轮要把它原样回放给
/// 模型——只回放文本的话,模型看不到自己上轮查到过什么,只能重查或者顺着总结瞎编。
struct ToolCallRecord: Identifiable, Equatable, Codable, Sendable {
    /// provider 给的 toolCallId,回放时要原样带回去。
    let id: String
    let name: String
    /// 参数的 JSON 字符串,保留原样(重新编码一遍不会得到相同的字节)。
    let input: String
    /// nil 表示还在跑。
    var output: String?
    var isError: Bool

    init(
        id: String,
        name: String,
        input: String,
        output: String? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.isError = isError
    }
}

struct ChatMessage: Identifiable, Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
    }

    let id: UUID
    let role: Role
    var text: String
    var toolCalls: [ToolCallRecord]
    var errorDescription: String?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolCalls: [ToolCallRecord] = [],
        errorDescription: String? = nil
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.errorDescription = errorDescription
    }
}
