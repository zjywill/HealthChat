import SwiftUI
import UserNotifications

@main
struct VanaApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var openedCheckIn: CheckInLaunch?
    @State private var launchRouter = VanaLaunchRouter.shared
    @State private var tenants: TenantContext
    private let notificationRelay = NotificationRelay()

    /// **成员名单在任何视图建起来之前就位。**
    ///
    /// `ChatViewModel` 一造出来就去问 `SessionStore.shared` 是哪个目录,那一步等不了一个 async
    /// 的答案。这里同步做完(迁移就是几次目录改名),启动路径上因此没有"还不知道当前是谁"的
    /// 窗口——而那个窗口里读到的会是别人的数据。
    init() {
        // 默认 provider 和模型在任何一屏画出来之前就落进 UserDefaults。设置页显示的那份
        // 和发请求时读的那份必须是同一份——见 `EngineSettings.seedDefaultsIfNeeded`。
        EngineSettings.seedDefaultsIfNeeded()
        TenantScope.bootstrap()
        _tenants = State(initialValue: TenantContext())
    }

    var body: some Scene {
        WindowGroup {
            ChatView(openedCheckIn: $openedCheckIn)
                // 切成员就是**整个换掉**这一屏,不是给 view model 发一条「现在换成妈妈」:
                // 回复可能正在飞、hook 记着上一句、四个 store 的缓存全是上一位的东西,而漏掉
                // 任何一样都是把上一位的内容端到下一位名下。换掉整个对象,这几件一次全没了。
                .id(tenants.current.id)
                .environment(tenants)
                .task {
                    UNUserNotificationCenter.current().delegate = notificationRelay
                    // 通知是排给某一位成员的(眼下恒是机主:check-in 讲的是 HealthKit 里的
                    // 事)。用户可能正看着妈妈那一栏点开它——不先切回去,那条讲机主睡眠的
                    // 通知会在妈妈的会话里开一段对话。
                    notificationRelay.onOpen = { open($0) }
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
            // 回到前台重定一次位。切走的这段时间里人可能已经换了个城市,而下一句话就要带着
            // 地名发出去了。没授权时它直接返回,不弹任何东西。
            if phase == .active {
                LocationProvider.shared.refresh(force: true)
            }
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
        open(asked)
    }

    /// 通知和 Siri 共用的落地:先把成员切对,再把问题交给界面。
    ///
    /// 顺序不能反。`ChatView` 是按成员号重建的(`.id`),先设 `openedCheckIn` 的话那条 launch
    /// 会被交给**上一位成员**的 view model,而它下一刻就被丢掉了——表现为点开通知什么都没发生。
    private func open(_ launch: CheckInLaunch) {
        if let id = launch.tenantId,
           let tenant = tenants.tenants.first(where: { $0.id == id }) {
            tenants.select(tenant)
        }
        openedCheckIn = launch
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
    /// 该落在哪位成员那儿。排程时写死,见 `CheckInScheduler.tenantKey`。
    ///
    /// Siri 那条没有:它问的是这台设备主人的健康数据,而那本来就是机主。
    var tenantId: UUID?
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
        // 旧通知里没有这个键。nil 就是"别切",和多成员上线之前一样。
        let tenantId = (info[CheckInScheduler.tenantKey] as? String).flatMap(UUID.init(uuidString:))

        await MainActor.run {
            onOpen?(CheckInLaunch(
                topicId: topicId?.isEmpty == false ? topicId : nil,
                question: question?.isEmpty == false ? question : nil,
                followUpId: followUpId,
                thread: thread,
                tenantId: tenantId
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
