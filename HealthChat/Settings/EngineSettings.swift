import Foundation

/// 云端引擎的设置项。provider / model 不是秘密,走 UserDefaults;API key 只进 Keychain。
enum EngineSettings {
    static let providerKey = "providerId"
    static let modelKey = "model"
    static let personaKey = "assistantPersona"
    static let checkInsEnabledKey = "checkInsEnabled"
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
}
