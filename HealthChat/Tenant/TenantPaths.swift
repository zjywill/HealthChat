import Foundation

/// 每个成员一个目录:`Documents/tenants/<uuid>/{sessions,attachments,memory.json,medications.json}`。
///
/// **目录隔离,不是给每条记录加 tenantId。** 判据是失败模式:加字段要求每一处查询都记得带上
/// 过滤条件,而漏一处的后果是**串数据**——拿妹妹的化验单去解释爸爸的心率,静默、看着正常、
/// 事后查不出来。目录隔离漏写代码的失败模式是"看不到",用户当场就发现了。在健康 app 里这两种
/// 错误的代价差着一个数量级。
///
/// 白拿的还有两样:四个 store 早就为了测试留好了目录注入口(那条「测试必须传自己的临时目录」
/// 的血泪),所以租户化就是**换一个 parent**,不用动任何数据模型;删一个成员就是删一个目录,
/// 不用扫全库确认删干净了。
enum TenantPaths {
    static let rootName = "tenants"

    struct Item: Sendable {
        let name: String
        let hint: URL.DirectoryHint
    }

    /// 跟着成员走的那几样东西。**这份清单就是"隔离"这句话的定义**——隐私会话那条规矩
    /// (按有哪些写入路径定义,不按名字)在这儿同样成立,漏一条,整个承诺就是假的。
    ///
    /// 少了谁:Keychain 里那两把 key(那是机主的账单,不是成员的属性)、provider / model /
    /// persona / 思考开关(那是"这台设备怎么连模型")、位置授权(系统级的)。
    static let perTenantItems: [Item] = [
        Item(name: "sessions", hint: .isDirectory),
        Item(name: "attachments", hint: .isDirectory),
        Item(name: "memory.json", hint: .notDirectory),
        Item(name: "medications.json", hint: .notDirectory)
    ]

    /// 某个成员的数据根。四个 store 拿它当 parent。
    static func root(for id: UUID, parent: URL = URL.documentsDirectory) -> URL {
        parent
            .appending(path: rootName, directoryHint: .isDirectory)
            .appending(path: id.uuidString, directoryHint: .isDirectory)
    }
}
