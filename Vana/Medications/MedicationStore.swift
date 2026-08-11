import Foundation

/// 用药与补剂的持久化:`Documents/medications.json`,一个文件装下全部。
///
/// **文件保护等级比 `memory.json` 高一档**(`.completeFileProtection`):记忆里最坏是「他喜欢
/// 早睡」,这张表里是过敏史和正在吃的处方药。
///
/// **不做淘汰。** `MemoryStore` 会挤掉最久没更新的自动记忆,因为那些是模型猜的;这里每一条
/// 都是用户自己录的,替他删掉一条他录过的药是这个功能能做的最糟的事。装不下 prompt 是
/// `MedicationSnapshot` 的问题(它裁的是**进模型的那一份**,盘上一条不少),不是存储的问题。
/// 只留一个防跑飞的硬上限,挡住模型连着调二百次 `log_medication`。
actor MedicationStore {
    /// 当前那位成员的用药与补剂表(同 `SessionStore.shared`)。
    ///
    /// 这张表是家人成员**最主要**的信息来源:他没有 HealthKit,「他在吃什么、什么不能吃」
    /// 几乎就是模型手上的全部。混在一起的那天,禁忌那一组会指到另一个人身上去。
    static var shared: MedicationStore { TenantScope.currentStores.medications }

    /// 防跑飞用的硬上限,不是容量规划。真有人吃六十样东西,那也是他的事。
    static let maxItems = 200

    private let fileURL: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// 读盘结果留在 actor 里。所有写入都从这儿过,缓存不会和文件漂移。
    private var cached: [MedicationItem]?

    /// - Parameter directory: 测试必须传自己的临时目录。app 侧的测试跑在 app host 里,
    ///   `MedicationStore.shared` 就是模拟器上那份真的 `medications.json`——测试写它等于把
    ///   用户录的药删了(`MemoryStore` 那条血泪)。
    init(directory: URL = URL.documentsDirectory) {
        fileURL = directory.appending(path: "medications.json", directoryHint: .notDirectory)
        decoder.dateDecodingStrategy = .iso8601
        encoder.dateEncodingStrategy = .iso8601
    }

    // MARK: - 读

    func snapshot() -> MedicationSnapshot {
        MedicationSnapshot(items: loaded())
    }

    func items() -> [MedicationItem] { loaded() }

    func item(named name: String) -> MedicationItem? {
        let target = MedicationItem.normalize(name)
        guard !target.isEmpty else { return nil }
        return loaded().first { MedicationItem.normalize($0.name) == target }
    }

    /// 说好该回头看的那几条。
    func dueFollowUps(at now: Date = Date()) -> [MedicationItem] {
        loaded().filter { $0.isFollowUpDue(at: now) }
    }

    // MARK: - 写

    @discardableResult
    func add(_ item: MedicationItem) throws -> [MedicationItem] {
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return loaded() }
        var all = loaded()
        guard all.count < Self.maxItems else { return all }
        // 同名的当成同一样东西:改它,不是再加一条。用户说「布洛芬没用」之后又说「布洛芬
        // 其实还行」,该留一条,不是两条互相矛盾的。
        if let index = all.firstIndex(where: {
            MedicationItem.normalize($0.name) == MedicationItem.normalize(name)
        }) {
            var merged = all[index]
            merged.status = item.status
            if !item.when.isEmpty { merged.when = item.when }
            if !item.reason.isEmpty { merged.reason = item.reason }
            if !item.outcome.isEmpty { merged.outcome = item.outcome }
            if !item.note.isEmpty { merged.note = item.note }
            if item.followUpAt != nil { merged.followUpAt = item.followUpAt }
            merged.updatedAt = Date()
            all[index] = merged
            return try persist(all)
        }
        var inserted = item
        inserted.name = name
        all.append(inserted)
        return try persist(all)
    }

    @discardableResult
    func update(_ item: MedicationItem) throws -> [MedicationItem] {
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == item.id }) else { return all }
        var updated = item
        updated.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return all }
        updated.updatedAt = Date()
        all[index] = updated
        return try persist(all)
    }

    /// 对话里更新一条的结果和状态(`update_medication`)。
    ///
    /// 只动传进来的那几项:模型说「那个没用」时它手上没有 `when` 和 `reason`,全量覆盖会把
    /// 用户当初写的那几句抹掉。
    @discardableResult
    func update(
        name: String,
        status: MedicationStatus? = nil,
        outcome: String? = nil,
        clearFollowUp: Bool = false
    ) throws -> MedicationItem? {
        var all = loaded()
        let target = MedicationItem.normalize(name)
        guard let index = all.firstIndex(where: { MedicationItem.normalize($0.name) == target }) else {
            return nil
        }
        if let status { all[index].status = status }
        if let outcome, !outcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            all[index].outcome = outcome.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 结果记下来了,那个约定就兑现了。不清掉的话接下来几天的早上会重复问同一句。
        if clearFollowUp || outcome != nil { all[index].followUpAt = nil }
        all[index].updatedAt = Date()
        let updated = all[index]
        _ = try persist(all)
        return updated
    }

    /// 生成出来的一般功效。用户改过的不覆盖——同 `MemoryStore` 里 pinned 那条。
    @discardableResult
    func setGeneratedBrief(id: UUID, text: String) throws -> [MedicationItem] {
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].briefIsUserWritten else {
            return all
        }
        all[index].brief = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return try persist(all)
    }

    /// 兑现一条回访:通知点开之后就把它消掉,否则接下来几天的早上会重复同一句。
    @discardableResult
    func clearFollowUp(id: UUID) throws -> [MedicationItem] {
        var all = loaded()
        guard let index = all.firstIndex(where: { $0.id == id }) else { return all }
        all[index].followUpAt = nil
        all[index].updatedAt = Date()
        return try persist(all)
    }

    @discardableResult
    func delete(id: UUID) throws -> [MedicationItem] {
        try persist(loaded().filter { $0.id != id })
    }

    @discardableResult
    func removeAll() throws -> [MedicationItem] {
        try persist([])
    }

    // MARK: - 存

    private func loaded() -> [MedicationItem] {
        if let cached { return cached }
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? decoder.decode([MedicationItem].self, from: data)
        else {
            cached = []
            return []
        }
        let normalized = Self.sorted(items)
        cached = normalized
        return normalized
    }

    @discardableResult
    private func persist(_ items: [MedicationItem]) throws -> [MedicationItem] {
        let kept = Self.sorted(items)
        cached = kept
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(kept).write(to: fileURL, options: [.atomic, .completeFileProtection])
        return kept
    }

    /// 固定顺序:先按状态(不能吃在最前),同组里旧的在前。
    ///
    /// 顺序稳定不只是好看——这份东西进的是 system 段,顺序一抖就是一次 prompt 缓存失效。
    private static func sorted(_ items: [MedicationItem]) -> [MedicationItem] {
        items.sorted { lhs, rhs in
            let left = MedicationStatus.allCases.firstIndex(of: lhs.status) ?? 0
            let right = MedicationStatus.allCases.firstIndex(of: rhs.status) ?? 0
            if left != right { return left < right }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}
