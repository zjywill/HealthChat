import SwiftUI
import UserNotifications

@main
struct HealthChatApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedCheckIn: CheckInLaunch?
    private let notificationRelay = NotificationRelay()

    var body: some Scene {
        WindowGroup {
            ChatView(openedCheckIn: $openedCheckIn)
                .task {
                    UNUserNotificationCenter.current().delegate = notificationRelay
                    notificationRelay.onOpen = { openedCheckIn = $0 }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // 回到前台和退到后台各重排一次:通知文案是排程时写死的,
            // 越接近使用时刻重排,内容越新。
            guard phase == .active || phase == .background else { return }
            Task { await CheckInScheduler.reschedule() }
        }
    }
}

/// 点开通知时带过来的东西:该聊哪个话题、开场问什么。
struct CheckInLaunch: Equatable {
    let topicId: String?
    let question: String?
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
