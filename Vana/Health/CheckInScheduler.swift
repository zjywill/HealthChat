import Foundation
import UserNotifications

/// 主动 check-in:早晚各一条通知,内容来自本地算出来的处境。
///
/// 通知文案在**排程时**就写死了,所以它描述的是排程那一刻的数据。这是个有意的取舍:
/// 另一条路是到点再算,那需要后台唤醒,而后台唤醒什么时候执行由系统说了算,更不可靠。
/// 因此文案只说已经发生的事("昨晚少睡了 1 小时 40 分"),不说"今天你应该……"。
///
/// 点开通知会带着对应话题开一条新会话——用户不用自己再描述一遍。
enum CheckInScheduler {
    /// 通知里带的话题 id,点开时用来定位会话话题。
    static let topicKey = "topicId"
    static let questionKey = "question"
    /// 这条通知是在兑现哪条「待跟进」。点开之后那条记忆就该消失了——说好回头看的事已经
    /// 看了,还留着只会在接下来几天的早上重复同一句。
    static let followUpKey = "followUpId"
    /// 点开之后回到哪条延续线。
    ///
    /// 由这里写死而不是让 app 那头去推:通知文案是排程那一刻定下的,它说的是哪条线,点开就该
    /// 落在哪条线。留给收件方现算的话,两边的判断迟早分叉。
    static let threadKey = "threadId"
    /// 点开之后落在哪位成员那儿。见 `schedule` 里那段。
    static let tenantKey = "tenantId"

    private static let morningIdentifier = "checkin.morning"
    private static let eveningIdentifier = "checkin.evening"

    static func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    /// 按当前设置重排。关掉开关就是全部撤销。
    static func reschedule() async {
        let defaults = UserDefaults.standard
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(
            withIdentifiers: [morningIdentifier, eveningIdentifier]
        )

        guard defaults.bool(forKey: EngineSettings.checkInsEnabledKey),
              await isAuthorized() else {
            return
        }

        let situation = await HealthSituation.detect(interests: await TenantScope.ownerStores.sessions.interests())
        let dueFollowUps = EngineSettings.memoryEnabled
            ? await TenantScope.ownerStores.memory.snapshot().due(at: Date())
            : []
        var conclusions: [UUID: String] = [:]
        for followUp in dueFollowUps {
            conclusions[followUp.id] = await FollowUpRunner.conclusion(for: followUp)
        }
        let dueMedications = EngineSettings.medicationsEnabled
            ? await TenantScope.ownerStores.medications.dueFollowUps()
            : []
        let goalNote = await morningGoalNote()
        let morningHour = hour(forKey: EngineSettings.morningCheckInHourKey, fallback: EngineSettings.defaultMorningHour)
        let eveningHour = hour(forKey: EngineSettings.eveningCheckInHourKey, fallback: EngineSettings.defaultEveningHour)

        await schedule(
            identifier: morningIdentifier,
            hour: morningHour,
            content: content(
                for: .morning,
                situation: situation,
                dueFollowUps: dueFollowUps,
                followUpConclusions: conclusions,
                dueMedications: dueMedications,
                goalNote: goalNote
            )
        )
        await schedule(
            identifier: eveningIdentifier,
            hour: eveningHour,
            content: content(for: .evening, situation: situation, dueFollowUps: dueFollowUps)
        )
    }

    // MARK: - 文案

    /// 不是 private:「说好今天回头看的事有没有被提起」得有测试盯着,而这段只在早上八点跑。
    struct CheckIn {
        let title: String
        let body: String
        let topicId: String?
        let question: String?
        var followUpId: UUID?
        /// 点开之后该回到哪条延续线。
        var threadId: String?
    }

    /// 一条目标线今天值不值得说一句。
    struct GoalNote: Equatable {
        let threadId: String
        let title: String
        /// `GoalDigest` 已经替他问过一轮得出的结论。没有就不进通知——空口说一句
        /// 「你的『减脂』还在进行中」对用户是零信息。
        let conclusion: String
    }

    /// 挑一个跟这个时段相关的触发点。挑不到就用一句通用的邀请,不硬编故事。
    ///
    /// 说好要回头看的事排在所有触发点前面:那是用户自己定下的约定,而触发点只是数据里
    /// 冒出来的一个现象。约到今天早上的事没被提起,这个功能就等于没有。
    /// - Parameter followUpConclusions: `FollowUpRunner` 已经替这几条待跟进跑出来的结论。
    ///   有结论就把它当正文——「说好两周后看深睡」是一句提醒,「深睡回到 1 小时 20 分了,
    ///   比两周前多了 25 分钟」才是他当初定下这个约定想要的东西。
    /// - Parameter goalNote: 有进展可说的那条目标线,由 `GoalDigest` 每周替他问一次得出。
    /// - Parameter dueMedications: 说好回头问「有没有用」的那几样。排在记忆的待跟进后面、
    ///   目标进展前面——它和待跟进是同一种东西(一个带日子的约定),只是记在另一张表上;
    ///   而目标进展一周才有一次,晚一天说没什么损失。
    ///
    ///   **这是用药表的闭环。** 没有这一下,`outcome` 那一列永远是空的:用户试了两周之后
    ///   不会主动回来告诉 app 结果,而那一列正是这张表最值钱的东西。
    static func content(
        for period: DayPeriod,
        situation: HealthSituation,
        dueFollowUps: [MemoryItem] = [],
        followUpConclusions: [UUID: String] = [:],
        dueMedications: [MedicationItem] = [],
        goalNote: GoalNote? = nil
    ) -> CheckIn {
        // 只放在早上那条里。晚上再说一遍同一件事,是两条通知讲一个内容。
        if period == .morning, let followUp = dueFollowUps.first {
            let conclusion = followUpConclusions[followUp.id]
            return CheckIn(
                title: conclusion == nil ? "说好今天回头看的" : "说好今天回头看的，看过了",
                body: conclusion ?? followUp.text,
                topicId: nil,
                // 问的还是原来那句。点开是要接着聊的,不是要它把通知上那行再念一遍。
                question: followUp.text,
                followUpId: followUp.id,
                threadId: SessionThread.followUp(followUp.id).id
            )
        }

        // 说好回头问「有没有用」的那一样。同样只放早上那条。
        //
        // 不替他先跑一轮(不像 `FollowUpRunner`):「褪黑素有没有用」这件事**数据里没有答案**,
        // 只有他自己知道。替他查一遍睡眠再说「你的深睡多了 12 分钟」是在用一个碰巧的数字
        // 替他回答一个主观问题——而这一列要的恰恰是他那句「没什么感觉」。
        if period == .morning, let medication = dueMedications.first {
            return CheckIn(
                title: "说好回头问你一句",
                body: "\(medication.name)试下来怎么样？",
                topicId: nil,
                question: "\(medication.name)试下来有感觉吗？",
                threadId: SessionThread.medication(medication.id).id
            )
        }

        // 目标排在触发点前面,和待跟进同一个道理:那是**用户自己定下的**一件事,而触发点
        // 只是数据里冒出来的现象。它一周才说一次(`GoalDigest.minimumInterval`),
        // 挤不掉几天的触发点。
        if period == .morning, let goalNote {
            return CheckIn(
                title: goalNote.title,
                body: goalNote.conclusion,
                topicId: nil,
                // 点开落回那条线,接着聊。不预填问题——进展已经在通知里说了,再替他问一遍
                // 「进展怎么样」只会得到同一段话。
                question: nil,
                threadId: goalNote.threadId
            )
        }

        let relevant = situation.triggers.first { trigger in
            switch period {
            case .morning:
                switch trigger {
                case .shortSleep, .missingLastNight, .longSleepStillLow,
                     .elevatedRestingHR, .suppressedHRV, .lateBedtimeDrift, .weeklyReview:
                    return true
                default:
                    return false
                }
            case .afternoon, .evening:
                switch trigger {
                case .justTrained, .bigActivityDay, .sedentaryStreak, .noStepsToday, .noWorkouts:
                    return true
                default:
                    return false
                }
            }
        }

        if let relevant {
            let question = relevant.question
            return CheckIn(
                title: period == .morning ? "早上好" : "今天收个尾",
                body: relevant.brief,
                topicId: topicId(for: relevant),
                question: question.text
            )
        }

        switch period {
        case .morning:
            return CheckIn(
                title: "早上好",
                body: "昨晚的睡眠数据已经同步好了，要看看吗？",
                topicId: "sleep",
                question: "昨晚睡得怎么样？"
            )
        case .afternoon, .evening:
            return CheckIn(
                title: "今天收个尾",
                body: "今天的活动量已经记完了，要看看吗？",
                topicId: "activity",
                question: "今天运动量够吗？"
            )
        }
    }

    /// 最近动过的那条目标,如果 `GoalDigest` 已经替他问出了结论。
    ///
    /// 只挑一条。两条目标各占一行,早上那条通知就成了一份日报——而通知只有一行的位置。
    private static func morningGoalNote() async -> GoalNote? {
        for goal in await TenantScope.ownerStores.sessions.goals() {
            guard let conclusion = await GoalDigest.conclusion(for: goal) else { continue }
            return GoalNote(threadId: goal.threadId, title: goal.title, conclusion: conclusion)
        }
        return nil
    }

    private static func topicId(for trigger: HealthTrigger) -> String? {
        switch trigger {
        case .justTrained: "running"
        case .shortSleep, .longSleepStillLow, .missingLastNight, .lateBedtimeDrift: "sleep"
        case .elevatedRestingHR, .suppressedHRV: "heart"
        case .bigActivityDay, .sedentaryStreak, .noStepsToday: "activity"
        case .noWorkouts: "overall"
        case .weightShift: "body"
        case .weeklyReview: "overall"
        }
    }

    // MARK: - 排程

    #if DEBUG
    /// 立刻发一条,内容走的是和真 check-in 完全相同的那条路。
    ///
    /// 不然验证一次要等到早上八点。
    @discardableResult
    static func sendTest(after seconds: TimeInterval = 5) async -> String {
        guard await isAuthorized() else {
            return "还没有通知权限，先打开每日 check-in。"
        }

        let situation = await HealthSituation.detect(interests: await TenantScope.ownerStores.sessions.interests())
        let dueFollowUps = EngineSettings.memoryEnabled
            ? await TenantScope.ownerStores.memory.snapshot().due(at: Date())
            : []
        var conclusions: [UUID: String] = [:]
        for followUp in dueFollowUps {
            conclusions[followUp.id] = await FollowUpRunner.conclusion(for: followUp)
        }
        let checkIn = content(
            for: DayPeriod(),
            situation: situation,
            dueFollowUps: dueFollowUps,
            // 少传一个参数,这条测试通知就在验一条线上根本不存在的路。
            followUpConclusions: conclusions,
            goalNote: await morningGoalNote()
        )
        await schedule(
            identifier: "checkin.test",
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false),
            content: checkIn
        )
        return "\(Int(seconds)) 秒后送达：\(checkIn.body)"
    }
    #endif

    private static func schedule(identifier: String, hour: Int, content: CheckIn) async {
        var components = DateComponents()
        components.hour = hour
        components.minute = 0

        // 每天重复。文案下次打开 app 时会被重排刷新。
        await schedule(
            identifier: identifier,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true),
            content: content
        )
    }

    private static func schedule(
        identifier: String,
        trigger: UNNotificationTrigger,
        content: CheckIn
    ) async {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.userInfo = [
            topicKey: content.topicId ?? "",
            questionKey: content.question ?? "",
            followUpKey: content.followUpId?.uuidString ?? "",
            // 没写线程的走 check-in 那条线,和这个功能上线之前一样。
            threadKey: content.threadId ?? SessionThread.checkIn.id,
            // 点开落在哪位成员那儿,**排程时就写死**(同 `threadKey`)。check-in 讲的是
            // HealthKit 里的事,那份数据只有机主有,所以这里恒是机主——但仍然把它写进去而
            // 不是让收件方现算:用户可能正看着妈妈那一栏点开这条通知,而通知说的是机主的
            // 睡眠。留给收件方判断,两边的口径迟早分叉。
            tenantKey: TenantScope.owner.id.uuidString
        ]

        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: notification, trigger: trigger)
        )
    }

    private static func hour(forKey key: String, fallback: Int) -> Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        return min(max(stored ?? fallback, 0), 23)
    }
}
