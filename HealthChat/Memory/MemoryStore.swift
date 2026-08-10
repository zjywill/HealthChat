import Foundation

/// 记忆持久化:`Documents/memory.json`,一个文件装下全部。
///
/// 没做索引层,也不打算做。Claude Code 那种「索引 + 按需读」是为了几百条记忆装不进上下文
/// 而存在的,代价是漏召回——索引说有、模型没去读。这里的记忆对象只有一个人,全部加起来几十
/// 条、一两千 token,**全量进 system 段**最简单也最可靠,加个硬上限就够了。
actor MemoryStore {
    /// 当前那位成员的记忆(同 `SessionStore.shared`)。「关于这位用户」在多成员之后就是
    /// 「关于这位成员」——妈妈的忌口和机主的作息本来就不该在一个文件里。
    static var shared: MemoryStore { TenantScope.currentStores.memory }

    /// 上限存在的意义是「别让 system 段慢慢长成一篇作文」,不是省那点存储。
    /// 两个都卡:条数管住列表长度,字数管住有人写小作文。
    static let maxItems = 40
    static let maxCharacters = 2_000
    /// 待跟进到期之后再留几天。
    ///
    /// 到期那一刻正是它要派上用场的时候(进 check-in、进 system 段),当场删掉等于永远
    /// 用不上。留三天,够早上那条通知说到它,又不至于变成一条赖着不走的旧提醒。
    static let followUpGrace: TimeInterval = 3 * 86_400

    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// 读盘结果留在 actor 里。每开一条会话都去解一次 JSON 没必要,而所有写入都从这里过,
    /// 缓存不会和文件漂移。
    private var cached: [MemoryItem]?

    init(directory: URL = URL.documentsDirectory) {
        fileURL = directory.appending(path: "memory.json", directoryHint: .notDirectory)
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - 读

    func snapshot(now: Date = Date()) -> MemorySnapshot {
        MemorySnapshot(items: items(now: now))
    }

    /// 早就过了宽限期的在读的时候滤掉,但不为此单独写一次盘——下一次真正的写入会把它
    /// 带走。为了删一条旧记忆去动文件,是拿一次 I/O 换一件没人看得见的事。
    func items(now: Date = Date()) -> [MemoryItem] {
        loaded().filter { !$0.hasExpired(at: now, grace: Self.followUpGrace) }
    }

    // MARK: - 用户手改 / 对话里明确要求

    /// 用户自己加的,或者对话里让 Vana 记的。两种都 `pinned`——他开口说了的东西,
    /// 不该被后台的抽取悄悄改掉或挤掉。
    @discardableResult
    func add(
        kind: MemoryKind,
        text: String,
        origin: MemoryItem.Origin = .manual,
        dueAt: Date? = nil,
        sourceSessionId: UUID? = nil
    ) throws -> [MemoryItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items() }
        var all = loaded()
        all.append(MemoryItem(
            kind: kind,
            text: trimmed,
            origin: origin,
            sourceSessionId: sourceSessionId,
            dueAt: kind == .followUp ? dueAt : nil
        ))
        return try persist(all)
    }

    /// 改过的一律算手写:用户校对过的说法,比抽取器下次的判断可信。
    @discardableResult
    func update(id: UUID, kind: MemoryKind, text: String, dueAt: Date? = nil) throws -> [MemoryItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items() }
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return items() }
        all[index].kind = kind
        all[index].text = trimmed
        all[index].updatedAt = Date()
        all[index].origin = .manual
        // 改成别的类别就没有「回头看」这回事了,留着一个看不见的到期时间,记忆会莫名其妙地消失。
        all[index].dueAt = kind == .followUp ? (dueAt ?? all[index].dueAt) : nil
        return try persist(all)
    }

    @discardableResult
    func delete(id: UUID) throws -> [MemoryItem] {
        try persist(loaded().filter { $0.id != id })
    }

    @discardableResult
    func removeAll() throws -> [MemoryItem] {
        try persist([])
    }

    // MARK: - 抽取器写

    /// 应用一批抽取出来的操作。
    ///
    /// 抽取器输出的是**修改**不是重写,所以这里也只做修改。全量覆盖会把用户手改过的那几条
    /// 一起冲掉,而那几条恰恰是最该留的。
    @discardableResult
    func apply(
        _ operations: [MemoryOperation],
        sessionId: UUID?,
        now: Date = Date()
    ) throws -> [MemoryItem] {
        guard !operations.isEmpty else { return items(now: now) }
        var all = loaded()

        for operation in operations {
            switch operation {
            case .add(let kind, let text, let expiresInDays):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { break }
                // 一模一样的一条别再加。模型偶尔会把上一轮记过的话重说一遍,那不是新事实。
                guard !all.contains(where: { $0.text == trimmed && $0.kind == kind }) else { break }
                all.append(MemoryItem(
                    kind: kind,
                    text: trimmed,
                    createdAt: now,
                    updatedAt: now,
                    origin: .extracted,
                    sourceSessionId: sessionId,
                    dueAt: kind == .followUp
                        ? expiresInDays.map { now.addingTimeInterval(Double($0) * 86_400) }
                        : nil
                ))
            case .update(let id, let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, let index = all.firstIndex(where: { $0.id == id }) else { break }
                // 用户手改过的不让抽取器再动。他改成那样就是不认同模型的说法,下次跑一遍
                // 又被改回去,等于这个设置页是假的。
                guard !all[index].pinned else { break }
                all[index].text = trimmed
                all[index].updatedAt = now
                all[index].sourceSessionId = sessionId
            case .delete(let id):
                guard let index = all.firstIndex(where: { $0.id == id }) else { break }
                guard !all[index].pinned else { break }
                all.remove(at: index)
            }
        }

        return try persist(all, now: now)
    }

    // MARK: - 存

    private func loaded() -> [MemoryItem] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? decoder.decode([MemoryItem].self, from: data)
        else {
            cached = []
            return []
        }
        let normalized = Self.sorted(items)
        cached = normalized
        return normalized
    }

    @discardableResult
    private func persist(_ items: [MemoryItem], now: Date = Date()) throws -> [MemoryItem] {
        let kept = Self.sorted(Self.evicting(items, now: now))
        cached = kept
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(kept).write(to: fileURL, options: .atomic)
        return kept
    }

    /// 固定顺序:先按类别,同类里旧的在前。
    ///
    /// 顺序稳定不只是好看——记忆块进的是 system 段,顺序一抖就是一次 prompt 缓存失效,
    /// 而且抽取器看到的编号(M1、M2…)也会跟着换,上一轮说的「改 M3」就指到别处去了。
    private static func sorted(_ items: [MemoryItem]) -> [MemoryItem] {
        items.sorted { lhs, rhs in
            let left = MemoryKind.allCases.firstIndex(of: lhs.kind) ?? 0
            let right = MemoryKind.allCases.firstIndex(of: rhs.kind) ?? 0
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// 淘汰顺序:先扔过期的,再从最久没更新的自动记忆里扔。
    ///
    /// `pinned` 的永远不扔。全满了又全是用户手写的,就停止接收新的自动记忆——宁可学不到
    /// 新东西,也不能把用户自己写的挤掉。设置页里能看到条数,满了让他自己删。
    private static func evicting(_ items: [MemoryItem], now: Date) -> [MemoryItem] {
        var kept = items.filter { !$0.hasExpired(at: now, grace: followUpGrace) }

        func isOverCapacity() -> Bool {
            kept.count > maxItems || kept.reduce(0) { $0 + $1.text.count } > maxCharacters
        }

        while isOverCapacity() {
            guard let victim = kept
                .filter({ !$0.pinned })
                .min(by: { $0.updatedAt < $1.updatedAt }),
                let index = kept.firstIndex(where: { $0.id == victim.id })
            else { break }
            kept.remove(at: index)
        }

        return kept
    }
}
