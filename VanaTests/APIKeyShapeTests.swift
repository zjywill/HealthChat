import Testing
@testable import Vana

/// key 和 provider 对不上这件事,要在他按发送之前说出来。
///
/// 这一组盯的是**「开口的时候一定是对的」**:漏报只是回到没有这道岗的状态,误报却会让一个
/// 其实填对了的人去反复检查一个没有问题的地方。所以下面沉默的那几条和报警的那几条一样要紧。
@Suite("API key 形状")
struct APIKeyShapeTests {
    @Test("审核那次的原样：DeepSeek 的 key 配 Anthropic")
    func reviewCase() throws {
        // 审核员截图里那把是 `sk-d13…d869`,配着停在默认值的 Anthropic。
        let warning = try #require(APIKeyShape.mismatch(
            key: "sk-d13abcdefghijklmnopqrstuvwxyz0123456789d869",
            providerId: "anthropic",
            providerName: "Anthropic"
        ))
        // 要说清「都是 sk-ant- 开头」,不然他不知道该拿什么去比对。
        #expect(warning.contains("sk-ant-"))
        #expect(warning.contains("Anthropic"))
    }

    @Test("key 自报家门时，要说得出它是哪家的")
    func signatureNamesTheOwner() throws {
        let warning = try #require(APIKeyShape.mismatch(
            key: "sk-ant-api03-abcdefghijklmnop",
            providerId: "deepseek",
            providerName: "DeepSeek"
        ))
        #expect(warning.contains("Anthropic"))
        #expect(warning.contains("DeepSeek"))
    }

    @Test("对得上就闭嘴")
    func matchingKeysAreSilent() {
        #expect(APIKeyShape.mismatch(
            key: "sk-ant-api03-abcdefghijklmnop",
            providerId: "anthropic",
            providerName: "Anthropic"
        ) == nil)

        #expect(APIKeyShape.mismatch(
            key: "AIzaSyAbCdEfGhIjKlMnOpQrStUvWxYz",
            providerId: "google",
            providerName: "Google"
        ) == nil)

        #expect(APIKeyShape.mismatch(
            key: "xai-abcdefghijklmnopqrstuvwxyz",
            providerId: "xai",
            providerName: "xAI"
        ) == nil)
    }

    /// **这一条是这套东西的边界。** `sk-` 是 OpenAI、DeepSeek、Mistral 以及一堆兼容
    /// OpenAI 协议的服务共用的开头,拿它去猜是掷硬币——而猜错的代价比不猜大。
    @Test("分不出来的一律沉默，不猜")
    func ambiguousPrefixesStaySilent() {
        for provider in ["openai", "deepseek", "mistral"] {
            #expect(APIKeyShape.mismatch(
                key: "sk-abcdefghijklmnopqrstuvwxyz0123456789",
                providerId: provider,
                providerName: provider
            ) == nil, "\(provider) 不该被 `sk-` 这个共用前缀判成错的")
        }

        // OpenAI 的 key 有 sk-、sk-proj-、sk-svcacct- 好几种写法,而且还在加。
        // 它不能进「必须长这样」那张表,否则每加一种新写法就是一次误报。
        #expect(APIKeyShape.mismatch(
            key: "sk-proj-abcdefghijklmnop",
            providerId: "openai",
            providerName: "OpenAI"
        ) == nil)
    }

    @Test("空的和只有空白的不算错，那是「还没填」")
    func emptyIsNotAMismatch() {
        #expect(APIKeyShape.mismatch(key: "", providerId: "anthropic", providerName: "Anthropic") == nil)
        #expect(APIKeyShape.mismatch(key: "   \n", providerId: "anthropic", providerName: "Anthropic") == nil)
    }

    @Test("前后空白不影响判定——粘贴最容易带上它们")
    func trimsWhitespace() {
        #expect(APIKeyShape.mismatch(
            key: "  sk-ant-api03-abcdefgh\n",
            providerId: "anthropic",
            providerName: "Anthropic"
        ) == nil)

        #expect(APIKeyShape.mismatch(
            key: " sk-ant-api03-abcdefgh ",
            providerId: "deepseek",
            providerName: "DeepSeek"
        ) != nil)
    }

    /// `sk-or-` 和 `sk-ant-` 都以 `sk-` 开头,表里长的要排在能抢它的短前缀前面。
    /// 现在表里没有短到会抢的,这条是为了加前缀的人别把顺序弄反。
    @Test("OpenRouter 的 sk-or- 不会被别的 sk- 前缀抢走")
    func openRouterIsNotShadowed() throws {
        #expect(APIKeyShape.mismatch(
            key: "sk-or-v1-abcdefghijklmnop",
            providerId: "openrouter",
            providerName: "OpenRouter"
        ) == nil)

        let warning = try #require(APIKeyShape.mismatch(
            key: "sk-or-v1-abcdefghijklmnop",
            providerId: "anthropic",
            providerName: "Anthropic"
        ))
        #expect(warning.contains("OpenRouter"))
    }
}
