import AppIntents

/// 把 intent 登记成"不用先去快捷指令里设置就能说"的短语。
///
/// 每条短语里必须出现 `\(.applicationName)`——这是 App Shortcuts 的硬性要求,也是它和
/// Apple Intelligence 的分界线:说出 app 名字的定向调用不需要 Apple Intelligence,所以在
/// 中国大陆一样能用。Siri 拿这些短语做的是**匹配**,不是理解,所以同一件事要多写几个说法。
///
/// 中文短语能不能被 Siri 认出来,取决于 app 的开发语言是不是中文(`project.yml` 里的
/// `developmentLanguage: zh-Hans`)。短语是按开发语言登记的,那项设成 en 的话,这里写的
/// 中文在中文 Siri 上一句都匹配不上。
struct VanaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodayStatusIntent(),
            phrases: [
                "用\(.applicationName)看看我今天状态",
                "用 \(.applicationName) 看看今天状态",
                "问\(.applicationName)我今天怎么样",
                "\(.applicationName)今天状态"
            ],
            shortTitle: "今天状态",
            systemImageName: "chart.line.uptrend.xyaxis"
        )

        AppShortcut(
            intent: LastNightSleepIntent(),
            phrases: [
                "问\(.applicationName)昨晚睡得怎么样",
                "用\(.applicationName)看看昨晚的睡眠",
                "用 \(.applicationName) 看看昨晚睡眠",
                "\(.applicationName)昨晚睡眠"
            ],
            shortTitle: "昨晚睡眠",
            systemImageName: "moon.stars"
        )

        AppShortcut(
            intent: LastWorkoutIntent(),
            phrases: [
                "用\(.applicationName)复盘刚才那次训练",
                "问\(.applicationName)刚才练得怎么样",
                "用 \(.applicationName) 看看最近一次训练",
                "\(.applicationName)最近一次训练"
            ],
            shortTitle: "复盘训练",
            systemImageName: "figure.cooldown"
        )

        AppShortcut(
            intent: AskVanaIntent(),
            phrases: [
                "问\(.applicationName)",
                "问\(.applicationName)一个问题",
                "用\(.applicationName)问问题",
                "打开\(.applicationName)问问题"
            ],
            shortTitle: "问 Vana",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }

    /// 快捷指令里那几张卡片的颜色。挑蓝绿一系,和健康类的观感对得上。
    static let shortcutTileColor: ShortcutTileColor = .teal
}
