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

        await MainActor.run {
            onOpen?(CheckInLaunch(
                topicId: topicId?.isEmpty == false ? topicId : nil,
                question: question?.isEmpty == false ? question : nil
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
