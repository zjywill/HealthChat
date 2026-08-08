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
    /// nil 表示还在跑。回放给模型的就是这段文本。
    var output: String?
    /// 同一次查询的结构化形式,面板拿它画表格。查询失败、或者是旧版本存下来的
    /// 会话,这里是 nil——面板那时退回显示 `output`。
    var report: HealthReport?
    var isError: Bool

    init(
        id: String,
        name: String,
        input: String,
        output: String? = nil,
        report: HealthReport? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.output = output
        self.report = report
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
    /// 这条消息是什么时候产生的。
    ///
    /// 可空:这个字段是后加的,之前存下来的会话里没有——与其编一个时间,不如在菜单里
    /// 不显示。
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolCalls: [ToolCallRecord] = [],
        errorDescription: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolCalls = toolCalls
        self.errorDescription = errorDescription
        self.createdAt = createdAt
    }
}
