import Foundation

/// 这把 key 看着像不像选中那家 provider 的。
///
/// **这是给 2026-08-16 那次审核补的一道岗。** 审核员按备注粘了一把 DeepSeek 的 key,而
/// Provider 停在当时的默认值 Anthropic 没动——两个字段各自都填得好好的,合起来必然失败,
/// 而在他按下发送之前,屏幕上没有任何一处说过这件事。Anthropic 回了
/// `401 authentication_error`,App 被判 Guideline 2.1(a)。
///
/// 换默认值只解决了"审核员那一把 key"，没解决"key 和 provider 是两个独立字段"这件事:
/// 拿 Anthropic key 的人粘进去不改 provider,踩的是同一个坑。
///
/// ## 只在能确定的时候开口
///
/// 判据是**前缀是否独一份**,不是"看着像不像"。`sk-ant-` 只可能是 Anthropic 的;而 `sk-`
/// 是 OpenAI、DeepSeek、Mistral 和一堆兼容 OpenAI 协议的服务共用的开头,拿它去猜等于
/// 掷硬币。**猜错的代价比不猜大得多**——一句"这把 key 不对"会让一个其实填对了的人去
/// 反复检查一个没有问题的地方,而真正的错误(比如额度用完)还在后面等着。
///
/// 所以分不出来的一律沉默。这道岗只保证:**它开口的时候一定是对的**。
enum APIKeyShape {
    /// 独一份的前缀 → 它属于哪家。顺序有意义:`sk-or-` 和 `sk-ant-` 都以 `sk-` 开头,
    /// 长的排前面(这里没有短到会抢的,但加前缀时要守住这条)。
    private static let signatures: [(prefix: String, providerId: String)] = [
        ("sk-ant-", "anthropic"),
        ("sk-or-", "openrouter"),
        ("AIza", "google"),
        ("xai-", "xai"),
        ("gsk_", "groq")
    ]

    /// 选中这家 provider 时,key **必须**长成这样。
    ///
    /// 只列前缀稳定到可以反过来用的那几家:Anthropic 的 key 一律 `sk-ant-` 开头,所以
    /// "选了 Anthropic 但 key 不是这个开头"本身就是结论。OpenAI 不能进这张表——
    /// 它历史上有 `sk-`、`sk-proj-`、`sk-svcacct-` 好几种,而且还在加。
    private static let required: [String: String] = [
        "anthropic": "sk-ant-",
        "google": "AIza",
        "xai": "xai-",
        "groq": "gsk_"
    ]

    /// 对不上的时候说的那句话;对得上、或者判不出来时返回 nil。
    ///
    /// - Parameters:
    ///   - key: 用户填的那把,调用方负责 trim。
    ///   - providerId: 当前选中的 provider。
    ///   - providerName: 显示名,用来把话说成人话(「Anthropic」而不是「anthropic」)。
    static func mismatch(key: String, providerId: String, providerName: String) -> String? {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }

        // 先看这把 key 有没有自报家门。它比下面那条准:一个 `sk-ant-` 开头的 key 配上
        // 任何别的 provider,都是确定的错,而且能直接说出「它是哪家的」。
        if let signature = signatures.first(where: { key.hasPrefix($0.prefix) }),
           signature.providerId != providerId {
            let owner = displayName(of: signature.providerId)
            return "这把 key 看着是 \(owner) 的，而现在选的是 \(providerName)。"
                + "把 Provider 换成 \(owner)，或者换一把 \(providerName) 的 key。"
        }

        // 再看这家 provider 认不认这个开头。走到这儿说明 key 没自报家门,
        // 所以只能说"不像",不能说"它是谁的"。
        if let expected = required[providerId], !key.hasPrefix(expected) {
            return "\(providerName) 的 key 都是 \(expected) 开头的，这把不是。"
                + "确认一下是不是别家的 key 粘错了地方。"
        }

        return nil
    }

    /// 目录里查得到就用显示名,查不到退回 id——这句话宁可难看一点,也不能因为
    /// 目录没载入就整个不说。
    private static func displayName(of providerId: String) -> String {
        CloudCatalog.provider(providerId).map(CloudCatalog.displayName(of:)) ?? providerId
    }
}
