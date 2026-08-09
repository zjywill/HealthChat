import AppIntents

/// 三条"说一句就有答案"的 intent,加一条"把问题带进 app"。
///
/// 分工是死的:前三条在后台跑,只念本地算出来的事实,不联网、不花钱、不需要 API key;
/// 最后一条把 app 拉起来,让完整的 agent 去回答开放问题。中间没有第三种形态——让 Siri
/// 等一轮模型调用,等到的多半是超时。
///
/// 之所以是这三条:它们对应用户真会在没手的时候问的事(刚醒、刚练完、随口问一句今天),
/// 而且每一条本地都算得出确切答案。

// MARK: - 今天怎么样

struct TodayStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "看看今天状态"
    static let description = IntentDescription(
        "念一句今天的活动量，和最值得注意的那一项。",
        categoryName: "健康"
    )
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 插值而不是 `IntentDialog(stringLiteral:)`:后者会把整句当成本地化 key。
        let line = await SpokenBrief.todayStatus()
        return .result(dialog: "\(line)")
    }
}

// MARK: - 昨晚睡得怎么样

struct LastNightSleepIntent: AppIntent {
    static let title: LocalizedStringResource = "昨晚睡得怎么样"
    static let description = IntentDescription(
        "念一句昨晚的睡眠时长、上下床时间，以及和最近几晚的差。",
        categoryName: "健康"
    )
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await SpokenBrief.lastNightSleep()
        return .result(dialog: "\(line)")
    }
}

// MARK: - 复盘最近那次训练

struct LastWorkoutIntent: AppIntent {
    static let title: LocalizedStringResource = "复盘最近一次训练"
    static let description = IntentDescription(
        "念一句最近那次锻炼的时长、距离、心率和消耗，并和同类训练比一比。",
        categoryName: "健康"
    )
    static var supportedModes: IntentModes { .background }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await SpokenBrief.lastWorkout()
        return .result(dialog: "\(line)")
    }
}

// MARK: - 问 Vana

/// 开放问题走这条:打开 app,把问题原样带进一条新会话,由 agent 回答。
///
/// 不在 Siri 里念答案,因为答案不是一两句话——它要查几轮数据、要给图表、用户多半还要追问。
/// 语音只负责把问题接下来,剩下的交给屏幕。
struct AskVanaIntent: AppIntent {
    static let title: LocalizedStringResource = "问 Vana"
    static let description = IntentDescription(
        "把问题带进 Vana，打开 app 接着聊。",
        categoryName: "健康"
    )
    /// `.immediate`:用户说完就该看见 app 起来,而不是先愣几秒。
    static var supportedModes: IntentModes { .foreground(.immediate) }

    @Parameter(title: "问题", requestValueDialog: "想问什么？")
    var question: String

    @MainActor
    func perform() async throws -> some IntentResult {
        VanaLaunchRouter.shared.ask(question)
        return .result()
    }
}
