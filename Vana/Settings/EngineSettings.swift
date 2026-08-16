import Foundation
import AIKit

/// 云端引擎的设置项。provider / model 不是秘密,走 UserDefaults;API key 只进 Keychain。
enum EngineSettings {
    static let providerKey = "providerId"
    static let modelKey = "model"
    static let personaKey = "assistantPersona"
    static let thinkingEnabledKey = "thinkingEnabled"
    static let checkInsEnabledKey = "checkInsEnabled"
    static let memoryEnabledKey = "memoryEnabled"
    static let medicationsEnabledKey = "medicationsEnabled"
    static let photoImagePolicyKey = "photoImagePolicy"
    static let morningCheckInHourKey = "morningCheckInHour"
    static let eveningCheckInHourKey = "eveningCheckInHour"

    /// 默认 provider 和模型。**只对全新安装生效**——存过的那份在 UserDefaults 里,
    /// 这两个常量只是 `?? defaultProvider` 那一侧的兜底,老用户一个字都不会被改动。
    ///
    /// 2026-08-16 从 anthropic / claude-sonnet-5 换成 deepseek / deepseek-chat,两个理由:
    ///
    /// - **界面整个是中文的,主力用户在国内**,而 DeepSeek 是这几家里 key 最容易拿到的
    ///   (国内支付、不用绕路)。让第一屏的默认值指向一个多数人拿不到 key 的 provider,
    ///   等于给每个新用户先设一道坎。
    /// - 那次 App Store 审核就栽在这上面:审核员按备注粘了一把 DeepSeek 的 key,
    ///   **provider 停在默认的 Anthropic 没动**,于是拿着这把钥匙去敲了另一家的门——
    ///   Anthropic 回 401 "API key is invalid",被判 Guideline 2.1(a)。
    ///
    /// 模型是 `deepseek-v4-flash`。**它看不了图**——DeepSeek 这几个里只有 `deepseek-chat`
    /// 和 `deepseek-reasoner` 能收图,所以默认状态下「照片原图」那一项不起作用(设置页那句
    /// 「当前模型看不了图」会照实说出来,不是静默的)。代价可控:化验单的文字识别本来就在
    /// 本机做,发出去的默认只有文字;要发原图的人换个能看图的模型即可。
    static let defaultProvider = "deepseek"
    static let defaultModel = "deepseek-v4-flash"
    static let defaultPersona = AssistantPersona.balanced.rawValue
    static let defaultMorningHour = 8
    static let defaultEveningHour = 21

    static var persona: AssistantPersona {
        AssistantPersona(rawValue: UserDefaults.standard.string(forKey: personaKey) ?? "")
            ?? .balanced
    }

    /// 让模型先思考再回答。默认开。
    ///
    /// `UserDefaults.bool` 没存过的时候返回 false,直接用会把默认值悄悄翻成「关」。
    static var thinkingEnabled: Bool {
        UserDefaults.standard.object(forKey: thinkingEnabledKey) as? Bool ?? true
    }

    /// 记住用户说过的长期情况和偏好。默认开,关掉之后既不注入也不再抽取,已经记下的
    /// 还留在设置页里——关开关是"先别用",不是"删干净",后者有专门的按钮。
    static var memoryEnabled: Bool {
        UserDefaults.standard.object(forKey: memoryEnabledKey) as? Bool ?? true
    }

    /// 让模型看到用药与补剂清单。默认开。
    ///
    /// **不归在 `memoryEnabled` 下面。** 关掉记忆的人不指望 Vana 还记得他随口说过的话,但他
    /// 仍然会指望这张自己一条条录进去的表还在——那是他的东西,不是模型对他的印象。
    /// 关掉之后 system 段不带名单、三个工具都不挂,但**列表页照常能看能改**:关开关是
    /// 「先别用」,不是「看不见」。
    static var medicationsEnabled: Bool {
        UserDefaults.standard.object(forKey: medicationsEnabledKey) as? Bool ?? true
    }

    /// 照片原图默认发不发。**只是默认**——每一张在核对面板里都还能单独翻。
    ///
    /// 做成设置项而不是写死在「认不出字才发」上,是因为那条规则替用户做完了两个决定:
    /// 「什么时候该发」和「他愿不愿意发」。前一个 app 判得了(有没有认出字是客观的),
    /// 后一个判不了——一个只拍饭菜的人希望每张都直接发,一个只拍化验单的人一张都不想发,
    /// 而默认那档对他们俩都不对。
    ///
    /// **默认仍然是「认不出字时问一句」**:它是三档里唯一不需要用户先想清楚一件事的那档。
    static var photoImagePolicy: PhotoImagePolicy {
        PhotoImagePolicy(rawValue: UserDefaults.standard.string(forKey: photoImagePolicyKey) ?? "")
            ?? .askWhenNoText
    }

    /// 这台设备上配的那个模型看得了图吗。
    ///
    /// **不做成设置项**,和「没配 key 就不挂 `web_search`」、「没授权位置就不注入那一段」
    /// 同一条:模型有没有视觉是它自己的属性,给一个填了却不生效的开关只会让用户猜该改哪个。
    ///
    /// 这一份只给界面用(要不要出那行「让 Vana 直接看图」)——纯查表,没有副作用,
    /// 而 `resolveEngine()` 每问一次就现造一个引擎。真正决定带不带图的那一步在 `runTurn`
    /// 里问**这一轮手上的那个引擎**(`AgentEngine.supportsVision`):设置说的是下一次会用
    /// 哪个模型,而带出去的图必须和真的要跑这一轮的那个对上。
    ///
    /// 目录里没有的模型(自建 endpoint、比目录新)按**没有**算:多问一句「要不要发图」而它
    /// 其实收不了图,换来的是一次白花的往返;少问一句最多是他接着用文字描述,而那本来就是
    /// 这个 app 一直以来的样子。
    static var modelSupportsVision: Bool {
        let provider = UserDefaults.standard.string(forKey: providerKey) ?? defaultProvider
        let model = UserDefaults.standard.string(forKey: modelKey) ?? defaultModel
        return ProviderCatalog.model(model, provider: provider)?.1.supportsVision ?? false
    }
}
