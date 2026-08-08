import Foundation

actor ConversationStore {
    static let shared = ConversationStore()

    private let fileURL: URL

    private init() {
        fileURL = URL.documentsDirectory.appending(
            path: "conversation.json",
            directoryHint: .notDirectory
        )
    }

    func load() throws -> [ChatMessage] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([ChatMessage].self, from: data)
    }

    func save(_ messages: [ChatMessage]) throws {
        let data = try JSONEncoder().encode(messages)
        try data.write(to: fileURL, options: .atomic)
    }

    func clear() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}
