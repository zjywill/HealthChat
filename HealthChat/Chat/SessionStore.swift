import Foundation

/// 会话持久化:`Documents/sessions/<id>.json`,一条会话一个文件。
///
/// 没有单独的索引文件——索引会和真实文件漂移,而这个规模下直接扫目录足够快,
/// 也不存在"索引说有、文件却没了"的状态。
actor SessionStore {
    static let shared = SessionStore()

    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private init() {
        directory = URL.documentsDirectory.appending(path: "sessions", directoryHint: .isDirectory)
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    func summaries() throws -> [SessionSummary] {
        try allSessions().map(SessionSummary.init)
    }

    func load(id: UUID) throws -> ChatSession? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ChatSession.self, from: Data(contentsOf: url))
    }

    /// 最近更新的一条,启动时接着上次聊。
    func mostRecent() throws -> ChatSession? {
        try allSessions().first
    }

    func save(_ session: ChatSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: fileURL(for: session.id), options: .atomic)
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }

    /// 全部会话,最近更新的在前。解不开的文件跳过——一个坏文件不该让整个列表打不开。
    private func allSessions() throws -> [ChatSession] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )

        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ChatSession.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }
}
