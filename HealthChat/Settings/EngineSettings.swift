import Foundation

/// 云端引擎的设置项。provider / model 不是秘密,走 UserDefaults;API key 只进 Keychain。
enum EngineSettings {
    static let providerKey = "providerId"
    static let modelKey = "model"
    static let personaKey = "assistantPersona"
    static let thinkingEnabledKey = "thinkingEnabled"
    static let checkInsEnabledKey = "checkInsEnabled"
    static let memoryEnabledKey = "memoryEnabled"
    static let medicationsEnabledKey = "medicationsEnabled"
    static let morningCheckInHourKey = "morningCheckInHour"
    static let eveningCheckInHourKey = "eveningCheckInHour"

    static let defaultProvider = "anthropic"
    static let defaultModel = "claude-sonnet-5"
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
}
