import Foundation

/// 界面上「这些数字是从哪儿来的」那几句话。**一处定义**,首屏、设置页、状况详情页、
/// 每一张查询结果面板说的都是它。
///
/// 2026-08-19 那次审核里的 Guideline 2.5.1:用了 HealthKit,却没在界面上把这件事说清楚。
/// 这条不是文案洁癖——`heart.text.square` 那个图标和「你的健康数据」这种说法,对着一个
/// 第一次打开 app 的人(审核员就是),说不出**数据是从 Apple 的「健康」App 来的**。而这正是
/// 他要确认的那件事:用户能不能一眼看出这个 app 在读他的 HealthKit。
///
/// 所以每一句都同时说三件事:**来源**(Apple「健康」App / HealthKit)、**只读**、
/// **不写不改**。少一件,剩下两件就得靠别处补。
enum HealthKitAttribution {
    /// 名字本身。中文用户认得的是「健康」App,审核员认得的是 HealthKit,两个都写上。
    static let source = String(localized: "Apple「健康」App（HealthKit）")

    /// 首屏欢迎卡上那一句。第一次打开 app 的人读到的第一段关于数据来源的话。
    static let welcome = String(localized: "步数、睡眠、心率这些数字来自 \(source)。Vana 只读取你授权的项目，不会写入或修改你的健康记录。")

    /// 设置页那一节的标题。原来叫「健康数据」——那四个字说不出这些数据是谁家的。
    static let settingsSection = "\(source)"

    /// 设置页那颗授权按钮。
    static let authorizeAction = String(localized: "请求读取 Apple 健康（HealthKit）")

    /// 一张查询结果面板顶上那行小字,和状况详情页底下那句。
    static let panelNote = String(localized: "来自 \(source)，只读取，不修改")

    /// 设置页那一节底下那段。
    ///
    /// **整段必须是一条字符串**:原来是 `panelNote + """…"""`,而 `String` 拼接不是
    /// 字面量,编译器抽不到,英文设备上后半段就原样显示中文——2026-08-21 审核那台 iPad 上
    /// 看到的正是这一节:上半句英文、下半句中文,而他此刻正要按的就是上面那颗按钮。
    static let settingsFooter = String(localized: "\(panelNote)。新增的数据类型（血压、血氧、呼吸频率、体温）需要重新请求才能读取。已经做过选择的项 iOS 不会再问，要打开或关闭请到“健康”App > 共享 > App > Vana。")

    /// 状况详情页底下那句:多一句「读不到多半是没戴设备」,那是这一页特有的困惑。
    static let statusFooter = String(localized: "\(panelNote)。缺少的项目多半是那几天没有戴设备。")
}
