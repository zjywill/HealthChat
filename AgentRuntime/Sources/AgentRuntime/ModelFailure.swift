import Foundation

/// 一轮失败之后要不要再试一次,以及等多久。
///
/// 手机上跑 agent 和服务器上不一样:一次 502、一次基站切换、一次流被中间设备掐断,都不该
/// 让用户重问一遍。但重试必须是**有分类的**——对着「余额不足」重试三次只是把同一个错误
/// 报三遍,还耽误了给用户看到真正的原因。分类在 `ModelFailure`,预算在这里。
public struct RetryPolicy: Equatable, Sendable {
    public var isEnabled: Bool
    /// 最多重试几次。首次请求不算重试。
    public var maxRetries: Int
    /// 第 n 次重试等 `baseDelay * 2^(n-1)`,封顶 `maxDelay`。
    public var baseDelay: Duration
    public var maxDelay: Duration

    public init(
        isEnabled: Bool = true,
        maxRetries: Int = 3,
        baseDelay: Duration = .seconds(1),
        maxDelay: Duration = .seconds(20)
    ) {
        self.isEnabled = isEnabled
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()
    public static let disabled = RetryPolicy(isEnabled: false, maxRetries: 0)

    public func allowsRetry(attempt: Int) -> Bool {
        isEnabled && attempt <= maxRetries
    }

    /// 第 `attempt` 次重试(从 1 开始)之前要等的时间。
    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0 else { return .zero }
        let exponent = min(attempt - 1, 16)
        return min(baseDelay * (1 << exponent), maxDelay)
    }
}

/// 失败原因的分类器。
///
/// 两条通道,顺序不能反:
/// 1. **传输层看错误码**。`URLError` 有结构化的 code,而它的 `localizedDescription` 是**跟着
///    系统语言走的**——中文手机上「请求超时」永远匹配不上 "timed out"。拿本地化字符串
///    做网络故障分类,等于只在英文设备上能重试。
/// 2. **provider 侧看字符串**。那段话是 API 返回的原始 payload,不本地化,而且经过各家 SDK、
///    网关、代理转手之后,能稳定留下来的也只有它——错误码在这条链路上活不下来。
public enum ModelFailure {
    /// 明确不该重试的:重试也还是这个结果,而且每试一次都在拖延用户看到真正的原因。
    private static let permanent = [
        // 额度、账单、订阅上限。这些是账户状态,不是拥塞。
        "insufficient quota", "quota exceeded", "out of budget", "billing",
        "usage limit", "credit balance", "payment required",
        // 鉴权和请求本身就是错的。
        "invalid api key", "invalid x api key", "incorrect api key", "api key not valid",
        "unauthorized", "authentication", "permission denied", "forbidden",
        "invalid request error", "model not found", "does not exist"
    ]

    /// 拥塞、限流、网络抖动、流被提前掐断——都是再试一次就可能好的。
    private static let transient = [
        // provider 侧的负载和 HTTP 状态。
        "overloaded", "rate limit", "ratelimit", "too many requests",
        "429", "500", "502", "503", "504", "529",
        "service unavailable", "server error", "internal error", "temporarily unavailable",
        "capacity", "try again", "retry",
        // 网络和传输层。手机上这一类最多。
        "network", "connection refused", "connection lost", "connection reset",
        "connection error", "cannot connect", "not connected to the internet",
        "the request timed out", "timed out", "timeout",
        "software caused connection abort", "socket", "other side closed",
        "fetch failed", "getaddrinfo", "enotfound", "eai again", "dns",
        // 流没走完就断了。SDK 各写各的话,但都长这样。
        "ended without", "stream ended", "unexpected end", "incomplete",
        "terminated", "cancelled by the server"
    ]

    /// 上下文塞不下。这条不能走重试——原样再发一次还是塞不下,得先压缩。
    private static let overflow = [
        "context length", "context window", "context_length", "maximum context",
        "too many tokens", "too many input tokens", "prompt is too long",
        "input is too long", "exceeds the maximum", "reduce the length",
        "request too large", "413", "string too long"
    ]

    /// 大小写、下划线、连字符各家写法不一,统一成小写空格再比。
    private static func normalized(_ description: String) -> String {
        description
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    public static func isContextOverflow(_ description: String) -> Bool {
        let text = normalized(description)
        return overflow.contains { text.contains($0) }
    }

    public static func isRetryable(_ description: String) -> Bool {
        let text = normalized(description)
        // 顺序有意义:溢出和永久失败都会命中 transient 里的某个词(比如 "413" 里的 "13"、
        // 账单错误里的 "try again"),必须先被挡下来。
        guard !isContextOverflow(text) else { return false }
        guard !permanent.contains(where: { text.contains($0) }) else { return false }
        return transient.contains { text.contains($0) }
    }

    /// 传输层的失败按错误码判,判不了才回落到文案。
    public static func isRetryable(_ error: any Error, description: String) -> Bool {
        transportVerdict(for: error) ?? isRetryable(description)
    }

    /// 这是不是一个可以再试一次的传输故障。不是传输故障就返回 nil,交给文案那条通道。
    private static func transportVerdict(for error: any Error) -> Bool? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        switch nsError.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotFindHost,
             NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorBadServerResponse,
             NSURLErrorResourceUnavailable,
             NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive,
             NSURLErrorDataNotAllowed,
             NSURLErrorSecureConnectionFailed,
             NSURLErrorZeroByteResource:
            // 换基站、进电梯、Wi-Fi 切 5G——手机上这一类最多,而且下一秒就好了。
            return true
        default:
            // 证书不对、URL 不对、被 ATS 拦下:再试一次还是这个结果。
            return false
        }
    }
}

/// 一次重试的通知。给 UI 用——退避期间界面上什么都不动的话,用户只会以为卡死了。
public struct AgentRetryNotice: Equatable, Sendable {
    public var attempt: Int
    public var maxAttempts: Int
    public var delay: Duration
    /// provider 报的原文。
    public var reason: String

    public init(attempt: Int, maxAttempts: Int, delay: Duration, reason: String) {
        self.attempt = attempt
        self.maxAttempts = maxAttempts
        self.delay = delay
        self.reason = reason
    }
}

/// 这次压缩是谁触发的。
public enum AgentCompactionReason: String, Equatable, Sendable {
    /// 估算跨过了水位线,主动压。
    case threshold
    /// provider 已经报了上下文超限,压完重跑这一轮。
    case overflowRecovery
}
