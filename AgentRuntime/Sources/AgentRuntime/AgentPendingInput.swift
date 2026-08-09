import Foundation

/// 用户在这一轮**还在跑的时候**补发的一句话。
///
/// 带 `id` 是因为 app 那头这句话已经是一条真实的消息了(气泡早就出现在屏幕上),
/// loop 把它并进上下文之后要能告诉 app「就是这几条」——那个状态是用户判断
/// 「它到底听见没有」的唯一依据,靠文本比对认回去是不可靠的(同一句话可以发两遍)。
public struct AgentPendingInput: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var text: String

    public init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

/// 去问一次「有没有排着的新消息」。
///
/// `AgentLoop` 在每个工具轮边界问一次:那是这一轮里唯一能从容改道的地方——上一次请求
/// 已经付过钱了,屏幕上的字一个都不用撤,而下一次请求还没发出去。
///
/// **返回即消费**:loop 拿到就会把它们拼进这一轮的上下文,不会再问第二次。实现方必须在
/// 返回的同时清掉自己那份队列,否则同一句话会在下一个边界被再发一遍。
public typealias AgentPendingInputProvider = @Sendable () async -> [AgentPendingInput]
