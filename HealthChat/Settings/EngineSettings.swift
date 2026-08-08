import Foundation

enum EngineChoice: String, CaseIterable, Identifiable {
    case automatic
    case onDevice
    case cloud

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            return "自动"
        case .onDevice:
            return "端上"
        case .cloud:
            return "云端"
        }
    }
}

enum EngineSettings {
    static let choiceKey = "engineChoice"
    static let providerKey = "providerId"
    static let modelKey = "model"

    static let defaultChoice = EngineChoice.automatic.rawValue
    static let defaultProvider = "anthropic"
    static let defaultModel = "claude-sonnet-5"
}
