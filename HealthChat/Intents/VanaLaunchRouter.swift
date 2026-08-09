import Foundation

/// Siri 把问题交给界面的那一手。
///
/// `AskVanaIntent` 和 app 跑在同一个进程里,所以不需要 app group 或者 URL scheme——一个
/// 主线程上的信箱就够了。用 `@Observable` 是为了让界面能等:app 冷启动时 intent 的
/// `perform` 可能比第一次渲染还早,这时候 `.onChange` 是不会响的,得靠界面出现时主动取
/// 一次(`consume`)。两条路都留着,少哪条都会漏掉一次提问。
@MainActor
@Observable
final class VanaLaunchRouter {
    static let shared = VanaLaunchRouter()

    private(set) var pending: CheckInLaunch?

    private init() {}

    /// 用户已经把问题说出口了,所以这条是自动发送的——再让他们按一次发送很没道理。
    func ask(_ question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pending = CheckInLaunch(topicId: nil, question: trimmed, autoSend: true)
    }

    /// 取走并清空。清空是必须的:留着的话下次回到前台会被当成一次新提问再发一遍。
    func consume() -> CheckInLaunch? {
        defer { pending = nil }
        return pending
    }
}
