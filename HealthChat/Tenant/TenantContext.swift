import SwiftUI

/// 成员名单在界面这一侧的样子。
///
/// `TenantScope` 是全局真相(同步、随处可读),这一层只做两件事:把名单变成 `@Observable` 让
/// SwiftUI 跟着刷新,以及**保证两边永远一致**——每一次写都先落盘、再同步给 `TenantScope`、
/// 最后才更新自己。反过来的顺序会在写盘失败时留下一个界面上已经切过去、而 store 还指着上一位
/// 的状态,那正是串数据的样子。
@MainActor
@Observable
final class TenantContext {
    private(set) var tenants: [Tenant]
    private(set) var current: Tenant
    /// 迁移成功了才算真的隔离。false 时整个成员入口不出现——一个点进去不起作用的开关,
    /// 比没有这个开关糟。
    let isolationAvailable: Bool
    /// 上一次写失败的原因。给界面显示,不吞掉。
    var failure: String?

    private let store: TenantStore

    init(store: TenantStore = .shared) {
        self.store = store
        isolationAvailable = TenantScope.isolationAvailable
        current = TenantScope.current
        tenants = (try? store.tenants()) ?? [TenantScope.current]
    }

    /// 只有一位成员时不必在界面上出现「成员」这件事。
    ///
    /// 但入口本身要在(不然没法添加第二位),所以这个判断只用来决定**导航栏和列表上要不要
    /// 一直标着名字**,不用来决定入口在不在。
    var hasFamily: Bool { tenants.count > 1 }

    func select(_ tenant: Tenant) {
        guard tenant.id != current.id else { return }
        // 先动全局,再动自己。反过来的话,SwiftUI 会在 store 还指着上一位的时候就重建
        // `ChatViewModel`——而它一造出来就去读 `SessionStore.shared`。
        TenantScope.select(tenant)
        current = tenant
    }

    func add(name: String, ageBand: Tenant.AgeBand?) {
        perform {
            let tenant = try store.add(name: name, ageBand: ageBand)
            tenants = try store.tenants()
            // 加完直接切过去。他刚打完名字,下一步想做的就是问那个人的事;留在列表里再点
            // 一次,中间那一下什么都没发生。
            select(tenant)
        }
    }

    func update(_ tenant: Tenant, name: String, ageBand: Tenant.AgeBand?) {
        perform {
            try store.update(id: tenant.id, name: name, ageBand: ageBand)
            tenants = try store.tenants()
            if let latest = tenants.first(where: { $0.id == tenant.id }) {
                TenantScope.refresh(latest)
                if current.id == latest.id { current = latest }
            }
        }
    }

    /// 删一位成员,连他的整个目录一起删。删的正好是当前这位就退回机主。
    func remove(_ tenant: Tenant) {
        perform {
            try store.remove(id: tenant.id)
            tenants = try store.tenants()
            TenantScope.fallBackToOwnerIfNeeded(removed: tenant.id)
            current = TenantScope.current
        }
    }

    private func perform(_ work: () throws -> Void) {
        do {
            failure = nil
            try work()
        } catch {
            failure = error.localizedDescription
        }
    }
}
