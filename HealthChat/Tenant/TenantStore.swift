import Foundation
import Synchronization

/// 成员名单:`Documents/tenants.json`,外加把老数据搬进机主目录的那一次迁移。
///
/// **同步的,不是 actor。** 别的几个 store 是 actor,因为它们要在用户等回复的时候被反复读写;
/// 这一份不一样——它一共几十字节,一次启动读一遍,改动只发生在用户点「添加成员」的时候。
/// 而它必须在**任何视图建起来之前**就位:`ChatViewModel` 一造出来就去问 `SessionStore.shared`
/// 是哪个目录,那一步等不了一个 async 的答案。把它做成 async 的代价是整个 app 的启动路径上
/// 多一个"还不知道当前是谁"的窗口,而那个窗口里读到的是**上一个成员的数据**。
final class TenantStore: Sendable {
    static let shared = TenantStore()

    /// 名单文件的格式版本。眼下只用来认出"这份文件已经迁移过了"。
    static let currentVersion = 1
    /// 防跑飞用的硬上限,不是容量规划。
    static let maxTenants = 12

    private let parent: URL
    private let fileURL: URL
    private let state = Mutex<Roster?>(nil)

    struct Roster: Codable, Sendable {
        var version: Int
        var tenants: [Tenant]
    }

    /// - Parameter parent: 测试必须传自己的临时目录。`TenantStore.shared` 指的是模拟器上
    ///   那份真的成员名单,测试写它等于把用户的家人删了——`MemoryStore` 那条血泪的第五次。
    init(parent: URL = URL.documentsDirectory) {
        self.parent = parent
        fileURL = parent.appending(path: "tenants.json", directoryHint: .notDirectory)
    }

    // MARK: - 读

    /// 名单。第一次调用会连带做迁移;失败就抛,由调用方退回单租户模式。
    func tenants() throws -> [Tenant] {
        try loaded().tenants
    }

    func owner() throws -> Tenant {
        // 机主恰好一个。名单里没有机主是一种不该存在的状态——真出现了(文件被人改过),
        // 补一个出来比崩掉强,但**不改 id**去认领已有的目录:那会把家人的数据端给机主。
        guard let owner = try loaded().tenants.first(where: \.isOwner) else {
            throw TenantStoreError.ownerMissing
        }
        return owner
    }

    func tenant(id: UUID) -> Tenant? {
        (try? loaded().tenants)?.first { $0.id == id }
    }

    // MARK: - 写

    @discardableResult
    func add(name: String, ageBand: Tenant.AgeBand?) throws -> Tenant {
        var roster = try loaded()
        guard roster.tenants.count < Self.maxTenants else {
            throw TenantStoreError.tooMany
        }
        let tenant = Tenant(
            name: Tenant.normalized(name: name),
            kind: .managed,
            ageBand: ageBand
        )
        // 目录先建出来再落名单。反过来的话,名单上会先出现一个点进去什么都没有的成员。
        try FileManager.default.createDirectory(
            at: TenantPaths.root(for: tenant.id, parent: parent),
            withIntermediateDirectories: true
        )
        roster.tenants.append(tenant)
        try write(roster)
        return tenant
    }

    /// 改名字和年龄段。id 和 kind 改不动——那两样定义了"这是谁"和"他有没有健康数据"。
    func update(id: UUID, name: String, ageBand: Tenant.AgeBand?) throws {
        var roster = try loaded()
        guard let index = roster.tenants.firstIndex(where: { $0.id == id }) else { return }
        roster.tenants[index].name = Tenant.normalized(name: name)
        roster.tenants[index].ageBand = ageBand
        try write(roster)
    }

    /// 删一个成员,**连他的整个目录一起删**。
    ///
    /// 会话、附件、记忆、用药表全在那一个目录里,所以删除是一次 `removeItem`,不用扫全库
    /// 确认删干净了——这正是当初选目录隔离而不是给每条记录加 tenantId 的那份白拿。
    ///
    /// 机主删不掉:删了之后这台设备的健康数据就没有归属了。
    func remove(id: UUID) throws {
        var roster = try loaded()
        guard let tenant = roster.tenants.first(where: { $0.id == id }) else { return }
        guard !tenant.isOwner else { throw TenantStoreError.cannotRemoveOwner }
        roster.tenants.removeAll { $0.id == id }
        // 先落名单再删目录:反过来的话,删文件删到一半崩了,名单上那个成员还在,点进去是空的。
        // 这个顺序下最坏是盘上留一个没人指向的目录——下次删不掉,但也读不到。
        try write(roster)
        try? FileManager.default.removeItem(at: TenantPaths.root(for: id, parent: parent))
    }

    // MARK: - 载入与迁移

    private func loaded() throws -> Roster {
        if let cached = state.withLock({ $0 }) { return cached }
        let roster = try loadOrMigrate()
        state.withLock { $0 = roster }
        return roster
    }

    private func loadOrMigrate() throws -> Roster {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: fileURL) {
            // 名单在就说明迁移做过了。这是幂等的那一半:跑第二遍在这里直接返回。
            return try decoder.decode(Roster.self, from: data)
        }
        return try migrateLegacyLayout()
    }

    /// 老版本的数据直接躺在 `Documents/` 下,那一份就是机主的。搬进 `tenants/<owner>/`。
    ///
    /// **幂等、原子、失败整个退回。** 迁移途中崩一次就把用户一年的会话和用药表弄丢,是这个
    /// 功能一开始就该防住的事。所以搬到一半出错时把已经搬过的原样搬回去,名单也不写——
    /// 下次启动看到的还是老布局,重来一遍就是。
    private func migrateLegacyLayout() throws -> Roster {
        let owner = Tenant.owner()
        let destination = TenantPaths.root(for: owner.id, parent: parent)
        let manager = FileManager.default
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)

        var moved: [(from: URL, to: URL)] = []
        do {
            for item in TenantPaths.perTenantItems {
                let from = parent.appending(path: item.name, directoryHint: item.hint)
                let to = destination.appending(path: item.name, directoryHint: item.hint)
                guard manager.fileExists(atPath: from.path(percentEncoded: false)) else { continue }
                guard !manager.fileExists(atPath: to.path(percentEncoded: false)) else { continue }
                try manager.moveItem(at: from, to: to)
                moved.append((from: from, to: to))
            }
            let roster = Roster(version: Self.currentVersion, tenants: [owner])
            try write(roster, cache: false)
            return roster
        } catch {
            for move in moved.reversed() {
                try? manager.moveItem(at: move.to, to: move.from)
            }
            throw error
        }
    }

    private func write(_ roster: Roster, cache: Bool = true) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        // 成员名单里只有称呼和年龄段,但它是通往几个成员的健康数据的目录——和
        // `medications.json` 同一档保护。
        try encoder.encode(roster).write(to: fileURL, options: [.atomic, .completeFileProtection])
        if cache {
            state.withLock { $0 = roster }
        }
    }
}

enum TenantStoreError: LocalizedError {
    case ownerMissing
    case cannotRemoveOwner
    case tooMany

    var errorDescription: String? {
        switch self {
        case .ownerMissing: "成员名单里没有机主"
        case .cannotRemoveOwner: "本人这一条不能删除"
        case .tooMany: "最多只能添加 \(TenantStore.maxTenants) 位成员"
        }
    }
}
