import SwiftUI
import UserNotifications

@main
struct HealthChatApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedCheckIn: CheckInLaunch?
    @State private var launchRouter = VanaLaunchRouter.shared
    private let notificationRelay = NotificationRelay()

    var body: some Scene {
        WindowGroup {
            ChatView(openedCheckIn: $openedCheckIn)
                .task {
                    UNUserNotificationCenter.current().delegate = notificationRelay
                    notificationRelay.onOpen = { openedCheckIn = $0 }
                    // 冷启动时 Siri 的 intent 可能比这里还早跑完,那种情况下
                    // `onChange` 永远不会响——所以出现的时候先主动取一次。
                    drainSiriQuestion()
                }
                // app 已经开着的时候再问一句,走的是这条。
                .onChange(of: launchRouter.pending) {
                    drainSiriQuestion()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台和退到后台各重排一次:通知文案是排程时写死的,
            // 越接近使用时刻重排,内容越新。
            guard phase == .active || phase == .background else { return }
            Task { await CheckInScheduler.reschedule() }
            // 到期的待跟进、该报进展的目标——有一件就替他跑一轮,跑出结论了再重排一次,
            // 让早上那条通知带上它。**不能**并进上面那个 `reschedule`:那一轮是完整的模型
            // 调用加几轮工具,让通知排程等着它,就是拿一件确定的事去赌一件不确定的事。
            Task {
                if await BackgroundDigest.runIfDue() {
                    await CheckInScheduler.reschedule()
                }
            }
        }
    }

    /// Siri 和通知共用同一个入口:`openedCheckIn`。多一条路进 app 不该多一套载入逻辑。
    private func drainSiriQuestion() {
        guard let asked = launchRouter.consume() else { return }
        openedCheckIn = asked
    }
}

/// 从别处进 app 时带过来的东西:该聊哪个话题、开场问什么、要不要直接发出去。
struct CheckInLaunch: Equatable {
    let topicId: String?
    let question: String?
    /// 通知是**邀请**,让用户看一眼再决定问不问;Siri 是用户已经把问题说出口了,该直接发。
    var autoSend = false
    /// 这次是在兑现哪条「待跟进」。开完这条会话它就该退休了。
    var followUpId: UUID?
    /// 接到哪条延续线上。
    ///
    /// check-in 通知有(每天早上那句该连成一条线),Siri 没有——那是一句临时想到的问题,
    /// 把它接到昨天的 check-in 后面,只会让两件事互相干扰。
    var thread: SessionThread?
}

/// `UNUserNotificationCenterDelegate` 得是个类,这里只做一件事:把点击转成上面那个值。
@MainActor
final class NotificationRelay: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((CheckInLaunch) -> Void)?

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let topicId = info[CheckInScheduler.topicKey] as? String
        let question = info[CheckInScheduler.questionKey] as? String
        let followUpId = (info[CheckInScheduler.followUpKey] as? String).flatMap(UUID.init(uuidString:))
        // 回到哪条线是排程时就写好的。这里现算的话,通知说的是「减脂」、点开却落在 check-in,
        // 而两边谁对谁错没人说得清。旧通知里没有这个键,退回 check-in——和这个功能上线前一样。
        let thread = (info[CheckInScheduler.threadKey] as? String)
            .flatMap(SessionThread.init(id:)) ?? .checkIn

        await MainActor.run {
            onOpen?(CheckInLaunch(
                topicId: topicId?.isEmpty == false ? topicId : nil,
                question: question?.isEmpty == false ? question : nil,
                followUpId: followUpId,
                thread: thread
            ))
        }
    }

    /// app 开着的时候也让通知露个面,否则用户以为没设置成功。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
