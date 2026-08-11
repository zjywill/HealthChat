import CoreLocation
import Foundation
import MapKit
import Observation

/// 拿粗定位、翻成一行地名、告诉界面现在是什么授权状态。
///
/// **系统授权本身就是开关,不另做一个**(同网页搜索那把 key)。填了 key 却关着的搜索开关、
/// 授权了却关着的位置开关,在界面上都是两种说法一个结果,而用户改的时候永远猜不到该改哪个。
/// 位置这件事上 iOS 的授权面板还是可撤销的、系统级的、用户已经认得的那一个,再叠一层
/// UserDefaults 只会多出一处能和它对不上的状态。
///
/// 几条边界:
///
/// - **只要 `kCLLocationAccuracyReduced`。** 街道级精度回答不了要位置的那几个问题(气候、
///   时差、当地饮食、就医方式),只是多给了一样能说漏嘴的东西。坐标一个字都不进 prompt。
/// - **拿不到就是拿不到。** 没授权、还没定到、反地理编码失败,对上层是同一件事:
///   `snapshot` 停在 `.unknown`,system 段里那一段不发(见 `LocationSnapshot`)。
/// - **不主动弹面板。** 授权只在用户自己去设置页按那颗按钮时才请求。一个健康 app 在用户
///   刚打开、还没问过一句话的时候弹定位面板,多数人会直接按不允许——而那一下是不可撤销的,
///   之后只能去 iOS 设置里改。
/// - **同城之内不重新编码。** 粗定位本来就只有一两公里的分辨率,而 `CLGeocoder` 的频率限制
///   很硬:每问一句编码一次,几轮之后它只会开始返回错误。
@MainActor
@Observable
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    /// 拼进 system 段的那一行。界面也读它显示「现在认为你在哪」——模型看到的和用户看到的
    /// 必须是同一句,否则这个开关就没法验证。
    private(set) var snapshot: LocationSnapshot = .unknown
    private(set) var authorization: CLAuthorizationStatus = .notDetermined

    /// 城市之内挪动不重新反地理编码。
    private static let sameCityRadius: CLLocationDistance = 5_000
    /// 两次定位之间至少隔这么久。每发一句话都定一次位,拿回来的是同一个城市,花掉的是电。
    private static let refreshInterval: TimeInterval = 10 * 60
    /// 地名跟着提示词的语言走,不跟系统语言:system 段整段是中文,中间插一行
    /// "Hangzhou, Zhejiang" 只会让模型在回答里也跟着切语言。
    private static let placeLocale = Locale(identifier: "zh_Hans_CN")

    @ObservationIgnored private let manager = CLLocationManager()
    /// 上一次真正编码过的那个点。用来判断「还在同一个城市」。
    @ObservationIgnored private var geocoded: CLLocation?
    @ObservationIgnored private var isGeocoding = false
    @ObservationIgnored private var lastRequestedAt: Date?

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    /// 拒过一次之后 app 再也弹不出面板,只能引导用户去 iOS 设置。这两种状态在界面上要说的
    /// 是同一句话,所以合并成一个。
    var isDenied: Bool {
        authorization == .denied || authorization == .restricted
    }

    override init() {
        super.init()
        manager.delegate = self
        // 只要粗的。`Info.plist` 里的 `NSLocationDefaultAccuracyReduced` 管的是授权面板上
        // 那个「精确位置」开关露不露出来,这一行管的是**实际拿到的数据**——两处都要有:
        // 用户在 iOS 设置里手动把精确位置打开了,这一行仍然把我们限制在粗定位上。
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        authorization = manager.authorizationStatus
        // 冷启动时系统往往已经有一个缓存位置。先用它顶上,第一句话就能带上地名,不用等
        // 一次真正的定位回来(那可能要好几秒,而用户已经在等回复了)。
        if isAuthorized, let cached = manager.location {
            resolve(cached)
        }
    }

    /// 用户在设置页按了那颗按钮。
    ///
    /// 已经拒过的不再请求——iOS 不会再弹,调它只是静默地什么都不发生,而界面上看起来像按钮
    /// 坏了。那种情况由界面引导去 iOS 设置。
    func requestAccess() {
        switch authorization {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            refresh(force: true)
        default:
            break
        }
    }

    /// 重新定一次位。回到前台、开始新会话、发出一句话之前都会调。
    ///
    /// 节流在这儿而不在调用方:调用方有好几处,门槛写在各自那边迟早会漂。
    func refresh(force: Bool = false) {
        guard isAuthorized else { return }
        let now = Date()
        if !force, let lastRequestedAt, now.timeIntervalSince(lastRequestedAt) < Self.refreshInterval {
            return
        }
        lastRequestedAt = now
        manager.requestLocation()
    }

    // MARK: - CLLocationManagerDelegate

    // 回调都发在建 manager 的那个 runloop 上,而它建在 `LocationProvider.shared` 第一次被
    // 取用的时候——那是主线程。所以这里可以直接 `assumeIsolated`,不必绕一次 `Task`:
    // 绕过去就要把 `CLLocation`(不是 Sendable)递过隔离边界。
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            // 读的是自己那一份,不是回调递进来的那个引用——后者跨不过隔离边界。
            authorization = self.manager.authorizationStatus
            if isAuthorized {
                refresh(force: true)
            } else {
                // 撤销授权之后立刻停止注入。留着上一次的地名,就是在用户已经说了「别看了」
                // 之后还把他在哪发出去。
                snapshot = .unknown
                geocoded = nil
            }
        }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            guard let latest = locations.last else { return }
            resolve(latest)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        // 定不到位就保持上一次的结果。室内、地下、飞行模式都会走到这儿,而上一次的城市
        // 几乎肯定还是对的——把它清成「不知道」才是更糟的那个选择。
        #if DEBUG
        print("[Location] 定位失败：\(error.localizedDescription)")
        #endif
    }

    // MARK: - 反地理编码

    private func resolve(_ location: CLLocation) {
        if let geocoded, snapshot.isKnown, location.distance(from: geocoded) < Self.sameCityRadius {
            return
        }
        guard !isGeocoding, let request = MKReverseGeocodingRequest(location: location) else { return }
        request.preferredLocale = Self.placeLocale
        isGeocoding = true
        Task {
            defer { isGeocoding = false }
            // 失败就保持上一次的结果:海上、无网络、被限流都会走到这儿,而上一次的城市几乎
            // 肯定还是对的。清成「不知道」是更糟的那个选择。
            guard let address = try? await request.mapItems.first?.addressRepresentations else {
                #if DEBUG
                print("[Location] 反地理编码没有结果")
                #endif
                return
            }
            // `cityWithContext(.full)` 永远带上国家。系统默认会在「就在本国」时省掉它,而
            // 模型不知道用户的「本国」是哪个——省掉之后「杭州市, 浙江省」对它就少了一层。
            guard let place = LocationSnapshot.describe(
                cityWithContext: address.cityWithContext(.full),
                cityName: address.cityName,
                regionName: address.regionName
            ) else { return }
            geocoded = location
            snapshot = LocationSnapshot(place: place)
        }
    }
}
