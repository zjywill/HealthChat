import Foundation

/// 会话持久化:`Documents/sessions/<id>.json`,一条会话一个文件。
///
/// 没有单独的索引文件——索引会和真实文件漂移,而这个规模下直接扫目录足够快,
/// 也不存在"索引说有、文件却没了"的状态。
///
/// 内存里那份索引是另一回事:它随时可以从目录重建,所以不会漂。它存在是因为读目录这件事
/// **跑在用户已经在等的时候**——每轮回复结束刷一次列表,`search_sessions` 每次调用建一次
/// 索引,从 check-in 进 app 找一次延续线。一年三百条会话全量解一遍要 380 毫秒、峰值多 40 MB,
/// 而这三件事各自解一遍。所以:
///
/// 1. **只解用得上的键**(`SessionIndexEntry`)。整份会话里最大的是 `storedTurn`——每条工具
///    结果在那儿还存了第二份给模型回放用。列表和检索一个字都用不上它。
/// 2. **一次扫描喂三个读者**。列表、召回、延续线查的是同一份索引。
/// 3. **按文件改动时间增量更新**。一轮回复结束只有一个文件变了,没道理把另外二百九十九条
///    重解一遍。
///
/// 读某一条会话的全文走 `load(id:)`,那是一次一条,该解就解。
actor SessionStore {
    static let shared = SessionStore()

    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// 索引缓存:文件 → (改动时间, 解出来的那一小部分)。
    private var indexed: [URL: (modifiedAt: Date, entry: SessionIndexEntry)] = [:]
    /// 上一次重建索引之后目录有没有可能变过。自己写的每一次都会置上,外部改动靠改动时间兜底。
    private var indexIsStale = true
    /// 最近更新在前的那份排好序的结果。
    private var sortedEntries: [SessionIndexEntry] = []
    /// 数出来的兴趣倾向。会话没动过就不用重数——Siri 那条路上这一步是在用户等着听话的时候跑的。
    private var cachedInterests: InterestProfile?
    /// 召回索引,连着它是排除哪条会话建的一起缓存。一轮里 `search_sessions` 和
    /// `read_session` 会连着来两次,重建一遍只是重复劳动。
    private var cachedRecall: (excluded: UUID?, index: SessionRecallIndex)?

    /// - Parameter parent: 测试必须传自己的临时目录。app 侧的测试跑在 app host 里,
    ///   `.shared` 指的就是模拟器上那份真的会话——测试往里写等于动用户的对话。
    ///   同一条规矩见 `MemoryStore.init(directory:)`。
    init(parent: URL = URL.documentsDirectory) {
        directory = parent.appending(path: "sessions", directoryHint: .isDirectory)
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - 读

    func summaries() -> [SessionSummary] {
        entries().map(SessionSummary.init)
    }

    func load(id: UUID) throws -> ChatSession? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(ChatSession.self, from: Data(contentsOf: url))
    }

    /// 最近更新的一条,启动时接着上次聊。
    func mostRecent() throws -> ChatSession? {
        guard let newest = entries().first else { return nil }
        return try load(id: newest.id)
    }

    /// 这条延续线上还接得上的那一段;接不上就返回 nil,由调用方另起一条。
    ///
    /// 「接得上」是有期限的,规矩在 `SessionThreadPolicy`——永远接着上一条会把它养成一份
    /// 永不结束的日志。断开的那段一条不丢,`search_sessions` 照样翻得到。
    func openThread(_ thread: SessionThread, now: Date = Date()) -> ChatSession? {
        guard let latest = latestInThread(thread),
              SessionThreadPolicy.canContinue(latest, at: now)
        else { return nil }
        return try? load(id: latest.id)
    }

    /// 这条线上最近的一段,不管还接不接得上。
    ///
    /// `FollowUpRunner` 用它当"这条待跟进跑过没有"的标记:会话本身就是那次跑出来的产物,
    /// 拿产物当标记,就不会出现"标记说跑过了、产物却没存下来"的状态。
    func latestInThread(_ thread: SessionThread) -> SessionIndexEntry? {
        entries().first { $0.threadId == thread.id }
    }

    /// 这条线上的每一段,最近更新的在前。
    func entries(inThread thread: SessionThread) -> [SessionIndexEntry] {
        entries().filter { $0.threadId == thread.id }
    }

    /// 现在有哪几条目标线,最近动过的在前。
    ///
    /// 一条线可能已经分成好几段(`SessionThreadPolicy` 到期就另起一段)。用户眼里那是**一件
    /// 事**,所以这里按线合并,不是按会话列。
    func goals() -> [GoalSummary] {
        var byThread: [String: GoalSummary] = [:]
        var order: [String] = []
        for entry in entries() {
            guard entry.thread?.isGoal == true, let threadId = entry.threadId else { continue }
            if var existing = byThread[threadId] {
                existing.segmentCount += 1
                existing.messageCount += entry.messageCount
                byThread[threadId] = existing
                continue
            }
            order.append(threadId)
            // `entries()` 最近更新的在前,所以第一次遇到的就是最新那一段:名字和时间都取它。
            byThread[threadId] = GoalSummary(
                threadId: threadId,
                title: entry.threadTitle?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                    ?? SessionThread.goal(UUID()).title,
                updatedAt: entry.updatedAt,
                latestSessionId: entry.id,
                segmentCount: 1,
                messageCount: entry.messageCount
            )
        }
        return order.compactMap { byThread[$0] }
    }

    /// 过往会话的召回索引:能检索、能按短编号取回一条。
    ///
    /// - Parameter excluding: 当前这条会话。不排掉的话模型会把正在进行的对话当成"过往"读回来。
    func recallIndex(excluding current: UUID? = nil) -> SessionRecallIndex {
        if let cachedRecall, cachedRecall.excluded == current { return cachedRecall.index }
        let index = SessionRecallIndex(entries: entries(), excluding: current)
        cachedRecall = (current, index)
        return index
    }

    /// 他实际关心什么,按最近的会话加权数出来。
    func interests() -> InterestProfile {
        if let cachedInterests { return cachedInterests }
        // `entries()` 已经按最近更新排好序了,权重衰减正好按这个顺序算。
        let profile = InterestProfile.build(from: entries())
        cachedInterests = profile
        return profile
    }

    // MARK: - 写

    func save(_ session: ChatSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoder.encode(session).write(to: fileURL(for: session.id), options: .atomic)
        invalidate()
    }

    /// 记下这条会话已经抽过记忆的位置。
    ///
    /// 只改这一个字段,不是把 view model 手里那份整份写回去——抽取是后台跑的,回来的时候
    /// 用户可能已经重新打开这条会话又聊了两句,整份覆盖会把那两句抹掉。
    func markMemoryHarvested(id: UUID, messageCount: Int) throws {
        guard var session = try load(id: id) else { return }
        guard messageCount > session.memoryHarvestedMessageCount else { return }
        session.memoryHarvestedMessageCount = messageCount
        try save(session)
    }

    /// 给这条目标线改个名字。名字存在会话上,一段一段往下传。
    func renameThread(_ thread: SessionThread, to title: String) throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for entry in entries() where entry.threadId == thread.id {
            guard var session = try load(id: entry.id) else { continue }
            session.threadTitle = trimmed
            try save(session)
        }
    }

    func delete(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
        invalidate()
    }

    /// 整条线一起删。目标线是用户当成"一件事"来管的,删掉的时候也该是一件事。
    func deleteThread(_ thread: SessionThread) throws {
        for entry in entries() where entry.threadId == thread.id {
            try? FileManager.default.removeItem(at: fileURL(for: entry.id))
        }
        invalidate()
    }

    // MARK: - 索引

    /// 删掉的会话必须**立刻**从召回索引里消失。用户刚把这段对话删了,下一句还能被模型引用
    /// 出来,是这套东西最难解释的一种失灵。
    private func invalidate() {
        indexIsStale = true
        cachedInterests = nil
        cachedRecall = nil
    }

    /// 全部会话的索引,最近更新的在前。
    private func entries() -> [SessionIndexEntry] {
        guard indexIsStale else { return sortedEntries }
        indexIsStale = false

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            indexed = [:]
            sortedEntries = []
            return []
        }

        var refreshed: [URL: (modifiedAt: Date, entry: SessionIndexEntry)] = [:]
        refreshed.reserveCapacity(files.count)

        for url in files where url.pathExtension == "json" {
            let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            // 一轮回复结束只有一个文件变了。另外那些原样留着——重解一遍是纯浪费,
            // 而这段跑在用户已经在等的时候。
            if let cached = indexed[url], cached.modifiedAt == modifiedAt {
                refreshed[url] = cached
                continue
            }
            // 解不开的跳过:一个坏文件不该让整个列表打不开。
            guard let data = try? Data(contentsOf: url),
                  let entry = try? decoder.decode(SessionIndexEntry.self, from: data)
            else { continue }
            refreshed[url] = (modifiedAt, entry)
        }

        indexed = refreshed
        sortedEntries = refreshed.values.map(\.entry).sorted { $0.updatedAt > $1.updatedAt }
        return sortedEntries
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appending(path: "\(id.uuidString).json", directoryHint: .notDirectory)
    }
}
