import Foundation

/// 云端引擎的设置项。provider / model 不是秘密,走 UserDefaults;API key 只进 Keychain。
enum EngineSettings {
    static let providerKey = "providerId"
    static let modelKey = "model"

    static let defaultProvider = "anthropic"
    static let defaultModel = "claude-sonnet-5"
}
