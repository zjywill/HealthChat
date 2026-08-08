import Foundation
import AgentRuntime

/// 引擎在一轮回复中吐出的事件:文本增量,或一次工具调用的开始与结束,以及整轮结束。
///
/// 开始和结束分开发:工具跑起来先让界面有反应,结果回来再补上——合成一个事件的话,
/// 慢查询期间界面上什么都不会动。
typealias AgentEvent = AgentTurnEvent

enum AgentError: LocalizedError {
    case needsAPIKey
    case needsModelSelection
    case cloudService(String)
    case toolLoopLimit
    case incompleteResponse
    case responseTruncatedDuringToolCall
    case contextWindowExceeded

    var errorDescription: String? {
        switch self {
        case .needsAPIKey: "需要先在设置里填写云端 API key"
        case .needsModelSelection: "需要先在设置里选择云端模型"
        case .cloudService(let message): "云端服务返回错误：\(message)"
        case .toolLoopLimit: "健康查询次数过多，请缩小问题范围后重试"
        case .incompleteResponse: "模型回复没有正常结束，请重试"
        case .responseTruncatedDuringToolCall: "模型在发出工具调用时被截断，参数可能不完整，请重试"
        case .contextWindowExceeded: "当前对话过长，超出模型上下文限制，请开启新对话或缩小问题范围"
        }
    }

    /// runtime 的错误是英文、中立的(它不知道自己在给谁跑);中文文案属于这一层。
    ///
    /// 取消不翻译——上层要靠 `CancellationError` 区分"用户按了停止"和"真出错了"。
    static func wrapping(_ error: any Error) -> any Error {
        switch error {
        case let agentError as AgentError:
            return agentError
        case is CancellationError:
            return error
        case let loopError as AgentLoopError:
            switch loopError {
            case .service(let message): return AgentError.cloudService(message)
            case .contentFilter: return AgentError.cloudService("模型因安全策略拒绝了这次请求")
            case .toolRoundLimit: return AgentError.toolLoopLimit
            case .incompleteResponse: return AgentError.incompleteResponse
            case .truncatedDuringToolCall: return AgentError.responseTruncatedDuringToolCall
            case .contextWindowExceeded: return AgentError.contextWindowExceeded
            }
        default:
            return error
        }
    }
}

extension ModelSummarizer {
    /// 中文的总结提示。摘要是发给模型看的,和对话同语言才不会平白多一层翻译损耗。
    ///
    /// 「保留什么、丢什么」写得很具体是有原因的:说得笼统模型就只会写一段客套的概述,
    /// 把真正要留的数字丢掉——那样压缩就等于失忆。
    static func healthChat(client: any AgentModelClient) -> ModelSummarizer {
        ModelSummarizer(
            client: client,
            instruction: """
                你在压缩一段健康助手的对话，好让它能在更小的上下文窗口里继续。
                只输出两段，各自用标签包起来：

                <visible>一句话给用户看的回顾：到目前为止聊过什么。</visible>
                <replay>给接着聊下去的助手看的要点笔记。必须保留：已经给出的结论；\
                调用过哪些工具、参数是什么；工具返回的具体数字（步数、时长、心率、体重等）；\
                用户说过的偏好、身体情况和限制。可以丢掉：寒暄、重复的提问、已经被结论概括掉的逐行原始数据。\
                写成笔记，不要写成文章。</replay>

                不要编造对话里没有的事实。数字必须原样保留，不要四舍五入。
                """,
            requestFormat: "下面是要压缩的对话：\n\n%@",
            fallbackVisibleFormat: "早先的 %d 条对话已折叠"
        )
    }
}

extension TranscriptCompactor {
    /// 折叠提示是要发给模型看的,所以跟对话同语言。
    static let healthChat = TranscriptCompactor(
        maxCharactersPerToolCall: 180,
        maxToolCallsInDigest: 6,
        digestHeaderFormat: "[这一轮折叠了 %d 次健康查询，只保留要点]",
        truncationSuffix: "…（已截断）",
        overflowFormat: "（另有 %d 次查询未列出）"
    )
}

/// 对话引擎统一接口。UI 层只认这个协议和 AgentEvent,不感知引擎差异。
/// 当前唯一实现是 AIKitEngine(端上 FoundationModels 引擎暂时移除,见 PLAN.md M3)。
protocol AgentEngine: Sendable {
    var name: String { get }

    /// 发送一轮对话,流式返回事件。工具调用在引擎内部完成。
    func reply(to history: [ChatMessage]) -> AsyncThrowingStream<AgentEvent, Error>
}
