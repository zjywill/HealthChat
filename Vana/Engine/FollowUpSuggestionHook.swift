import Foundation
import AgentRuntime

/// 答完一轮就去写几条追问 chip。`AgentHook` 的第一个使用者。
///
/// 走 hook 而不是在 `ChatViewModel` 那条回复链上开个洞,换来的是三件事:这次生成拖多久都
/// 不影响正在流的那段字;它自己知道"下一轮开跑了,刚才那几条作废";而回复链上那个状态机
/// 一行没动。
///
/// **一条会话一个**。它记着的是"上一句问了什么",换了会话就该忘干净——所以由
/// `ChatViewModel` 在换会话时连宿主一起丢掉,而不是在这儿加一个 reset。
///
/// 三条不生成的情况:
/// - 这一轮被停掉或者报错。没有可接的结论,而且用户此刻想按的是重试,不是追问。
/// - 助手一个字没说(只跑了工具就被截断之类)。
/// - 后台派生的那几轮——它们**根本不挂 hook**(`AIKitEngine(hooks:)` 默认 nil),没有用户
///   在场,写给谁看。
actor FollowUpSuggestionHook: AgentHook {
    typealias Generate = @Sendable (FollowUpContext) async -> [String]
    typealias Deliver = @MainActor @Sendable ([String]) -> Void

    private let generate: Generate
    private let deliver: Deliver
    /// 这一轮开跑时用户问的那句。
    ///
    /// 材料分在两条通知里:问句在 `turnStarted` 的历史里(这一轮的 transcript 还是空的),
    /// 回答在 `turnFinished` 里。靠 `turnId` 对上,不靠"最近那一条"——插话续跑时会连着来
    /// 两轮,认最近那条就会拿上一轮的问句去配这一轮的回答。
    private var pending: (turnId: UUID, question: String)?
    private var inFlight: Task<Void, Never>?

    init(generate: @escaping Generate, deliver: @escaping Deliver) {
        self.generate = generate
        self.deliver = deliver
    }

    func observe(_ notice: AgentHookNotice) async {
        switch notice.kind {
        case .turnStarted(let start):
            // 下一轮开跑了,上一轮答完之后正在写的那几条就作废了:它们接的是上一句,而屏幕上
            // 马上会多出一段新的回答。插话续跑时这一下就在几微秒之内发生,那次生成基本没花钱。
            inFlight?.cancel()
            inFlight = nil
            pending = (notice.turnId, Self.question(in: start.history))
        case .toolFinished:
            break
        case .turnFinished(let outcome):
            let question = pending?.turnId == notice.turnId ? pending?.question ?? "" : ""
            pending = nil
            guard outcome.state == .completed else { return }

            let answer = Self.answer(in: outcome.transcript)
            guard !answer.isEmpty else { return }
            let context = FollowUpContext(
                question: Self.appendingInterjections(to: question, from: outcome.transcript),
                answer: answer,
                toolNames: Self.toolNames(in: outcome.transcript)
            )

            let generate = generate
            let deliver = deliver
            inFlight = Task {
                let suggestions = await generate(context)
                // 取消不一定能打断底下那次网络请求,所以交付之前再看一眼:这几条可能已经
                // 接不上屏幕上的对话了。
                guard !Task.isCancelled, !suggestions.isEmpty else { return }
                await deliver(suggestions)
            }
        }
    }

    // MARK: - 从通知里取材料

    /// 用户这一轮问的那句:历史里最后一条他自己说的话。
    ///
    /// 跳过 app 写的占位("已停止回复"之类):那句话不是他说的,拿它去生成追问会得到三条
    /// 关于"为什么停了"的问题。
    private static func question(in history: [AgentChatMessageDTO]) -> String {
        history.last { $0.role == .user && !$0.textIsPlaceholder && !$0.text.isEmpty }?.text ?? ""
    }

    /// 中途插的那几句也算他问的。它们在 transcript 里是普通的 user 消息。
    private static func appendingInterjections(
        to question: String,
        from transcript: AgentTranscript
    ) -> String {
        let interjections = transcript.messages
            .filter { $0.role == .user }
            .map(\.text)
            .filter { !$0.isEmpty }
        return ([question] + interjections)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func answer(in transcript: AgentTranscript) -> String {
        transcript.messages
            .filter { $0.role == .assistant }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func toolNames(in transcript: AgentTranscript) -> [String] {
        var seen: Set<String> = []
        var names: [String] = []
        for message in transcript.messages {
            for part in message.parts {
                guard case .toolResult(let result) = part else { continue }
                guard seen.insert(result.toolName).inserted else { continue }
                names.append(result.toolName)
            }
        }
        return names
    }
}
