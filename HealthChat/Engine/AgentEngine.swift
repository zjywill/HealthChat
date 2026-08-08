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
