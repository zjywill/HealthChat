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

        let situation = await HealthSituation.detect()
        let morningHour = hour(forKey: EngineSettings.morningCheckInHourKey, fallback: EngineSettings.defaultMorningHour)
        let eveningHour = hour(forKey: EngineSettings.eveningCheckInHourKey, fallback: EngineSettings.defaultEveningHour)

        await schedule(
            identifier: morningIdentifier,
            hour: morningHour,
            content: content(for: .morning, situation: situation)
        )
        await schedule(
            identifier: eveningIdentifier,
            hour: eveningHour,
            content: content(for: .evening, situation: situation)
        )
    }

    // MARK: - 文案

    private struct CheckIn {
        let title: String
        let body: String
        let topicId: String?
        let question: String?
    }

    /// 挑一个跟这个时段相关的触发点。挑不到就用一句通用的邀请,不硬编故事。
    private static func content(for period: DayPeriod, situation: HealthSituation) -> CheckIn {
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

    private static func schedule(identifier: String, hour: Int, content: CheckIn) async {
        let notification = UNMutableNotificationContent()
        notification.title = content.title
        notification.body = content.body
        notification.sound = .default
        notification.userInfo = [
            topicKey: content.topicId ?? "",
            questionKey: content.question ?? ""
        ]

        var components = DateComponents()
        components.hour = hour
        components.minute = 0

        let request = UNNotificationRequest(
            identifier: identifier,
            content: notification,
            // 每天重复。文案下次打开 app 时会被重排刷新。
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private static func hour(forKey key: String, fallback: Int) -> Int {
        let stored = UserDefaults.standard.object(forKey: key) as? Int
        return min(max(stored ?? fallback, 0), 23)
    }
}
