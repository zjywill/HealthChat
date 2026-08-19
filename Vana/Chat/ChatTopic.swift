import Foundation

/// 一次对话围绕的话题。
///
/// 新会话让用户先点一下"想聊什么",比让模型猜便宜得多:话题一确定,系统提示里就写清了
/// 该优先看哪些数据、怎么口径回答,工具还是那五个,只是模型知道该先调哪个、按什么筛。
struct ChatTopic: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let icon: String
    /// 写进系统提示的一句话:这次围绕什么、优先看什么。
    let focus: String
    /// 这个话题下的默认问题,选完话题立刻能点,不用等模型。
    let questions: [String]
}

/// 话题目录。运动按 Apple Health 的锻炼类型分,指标按工具能读到的数据分。
enum ChatTopics {
    /// 运动:名字跟 `HealthStore` 给锻炼记录起的名字一致,模型好在数据里对上号。
    static let workouts: [ChatTopic] = [
        ChatTopic(
            id: "running",
            name: String(localized: "跑步"),
            icon: "figure.run",
            focus: "用户想聊跑步。优先看 workouts 里类型为「跑步」的记录（时长、消耗、频次），"
                + "再结合静息心率、HRV 和睡眠判断恢复情况。其他类型的锻炼只在做对比时提。",
            questions: [String(localized: "最近跑量合适吗？"), String(localized: "跑完恢复得怎么样？"), String(localized: "这周还能再跑吗？")]
        ),
        ChatTopic(
            id: "cycling",
            name: String(localized: "骑行"),
            icon: "figure.outdoor.cycle",
            focus: "用户想聊骑行。优先看 workouts 里类型为「骑行」的记录，结合消耗和恢复指标回答。",
            questions: [String(localized: "最近骑行强度如何？"), String(localized: "骑完恢复得怎么样？"), String(localized: "这周骑够了吗？")]
        ),
        ChatTopic(
            id: "strength",
            name: String(localized: "力量训练"),
            icon: "dumbbell",
            focus: "用户想聊力量训练。优先看 workouts 里类型为「力量训练」的记录，"
                + "关注频次和间隔，结合静息心率与 HRV 判断是否需要休息。",
            questions: [String(localized: "这周练了几次？"), String(localized: "间隔够恢复吗？"), String(localized: "今天适合再练吗？")]
        ),
        ChatTopic(
            id: "swimming",
            name: String(localized: "游泳"),
            icon: "figure.pool.swim",
            focus: "用户想聊游泳。优先看 workouts 里类型为「游泳」的记录，结合消耗和恢复指标回答。",
            questions: [String(localized: "最近游得够多吗？"), String(localized: "游完消耗多少？"), String(localized: "频次合适吗？")]
        ),
        ChatTopic(
            id: "walking",
            name: String(localized: "步行徒步"),
            icon: "figure.walk",
            focus: "用户想聊步行和徒步。优先看 daily_steps，再看 workouts 里「步行」「徒步」的记录。",
            questions: [String(localized: "最近走得够吗？"), String(localized: "今天走了多少？"), String(localized: "这周比上周多吗？")]
        ),
        ChatTopic(
            id: "yoga",
            name: String(localized: "瑜伽拉伸"),
            icon: "figure.yoga",
            focus: "用户想聊瑜伽和拉伸。优先看 workouts 里「瑜伽」的记录，"
                + "结合 HRV 和睡眠聊放松与恢复,不要把它当成高强度训练来评估。",
            questions: [String(localized: "最近练得规律吗？"), String(localized: "对睡眠有帮助吗？"), String(localized: "HRV 有变化吗？")]
        ),
        ChatTopic(
            id: "hiit",
            name: String(localized: "高强度间歇"),
            icon: "flame",
            focus: "用户想聊高强度间歇训练。优先看 workouts 里「高强度间歇训练」的记录，"
                + "重点是频次和恢复——连续多次高强度要提醒风险。",
            questions: [String(localized: "这周几次高强度？"), String(localized: "恢复跟得上吗？"), String(localized: "今天还能练吗？")]
        )
    ]

    /// 指标:每一条都对应至少一个能读到数据的工具。
    static let metrics: [ChatTopic] = [
        ChatTopic(
            id: "sleep",
            name: String(localized: "睡眠"),
            icon: "moon.stars",
            focus: "用户想聊睡眠。优先用 sleep_summary（时长、入睡与起床时间、波动），"
                + "需要时用 heart_rate_summary 看静息心率和 HRV 与睡眠的关系。",
            questions: [String(localized: "昨晚睡得怎么样？"), String(localized: "最近睡眠稳定吗？"), String(localized: "入睡时间在变晚吗？")]
        ),
        ChatTopic(
            id: "heart",
            name: String(localized: "心率与 HRV"),
            icon: "heart.text.square",
            focus: "用户想聊静息心率和 HRV。优先用 heart_rate_summary，"
                + "把变化和睡眠、锻炼负荷联系起来解释，但不要做诊断。",
            questions: [String(localized: "静息心率正常吗？"), String(localized: "HRV 最近怎么样？"), String(localized: "和睡眠有关系吗？")]
        ),
        ChatTopic(
            id: "activity",
            name: String(localized: "日常活动量"),
            icon: "figure.walk.motion",
            focus: "用户想聊日常活动量。优先用 daily_steps，必要时用 workouts 补充有记录的锻炼。",
            questions: [String(localized: "今天活动量够吗？"), String(localized: "这周比上周多吗？"), String(localized: "哪天动得最少？")]
        ),
        ChatTopic(
            id: "body",
            name: String(localized: "体重与体脂"),
            icon: "scalemass",
            focus: "用户想聊体重和体脂。优先用 body_metrics 看趋势而不是单日数值，"
                + "结合活动量和锻炼解释变化，注意体重日常波动本来就大。",
            questions: [String(localized: "体重趋势怎么样？"), String(localized: "体脂有变化吗？"), String(localized: "和运动量有关吗？")]
        ),
        ChatTopic(
            id: "bloodPressure",
            name: String(localized: "血压"),
            icon: "heart.circle",
            focus: "用户想聊血压。用 blood_pressure；这项多数人没有记录（需要血压计写入），"
                + "没有数据就直说并告诉用户怎么补上，不要用心率代替血压回答。可以解释一般范围，但不做诊断。",
            questions: [String(localized: "最近血压怎么样？"), String(localized: "血压有波动吗？"), String(localized: "和运动有关系吗？")]
        ),
        ChatTopic(
            id: "vitals",
            name: String(localized: "血氧与呼吸"),
            icon: "lungs",
            focus: "用户想聊血氧、呼吸频率或体温。用 vitals；这几项要够新的 Apple Watch 才有，"
                + "缺哪项就说明缺哪项。数值异常时提醒这不等于诊断，建议找专业人员。",
            questions: [String(localized: "血氧正常吗？"), String(localized: "呼吸频率稳定吗？"), String(localized: "睡眠体温有变化吗？")]
        ),
        ChatTopic(
            id: "overall",
            name: String(localized: "整体状态"),
            icon: "chart.line.uptrend.xyaxis",
            focus: "用户想要一份整体判断。睡眠、活动量、心率与 HRV、锻炼都看一遍，"
                + "先给一句总结，再点出最值得注意的那一项。",
            questions: [String(localized: "我最近状态如何？"), String(localized: "有哪项需要注意？"), String(localized: "这周比上周好吗？")]
        )
    ]

    static let all: [ChatTopic] = workouts + metrics

    static func topic(id: String?) -> ChatTopic? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}
