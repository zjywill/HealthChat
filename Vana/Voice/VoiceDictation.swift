import AVFoundation
import Foundation
import Observation
import Speech

/// 说出来的那一段怎么和输入框里已经有的字拼起来。
///
/// **接在后面,不覆盖。** 打了半句发现不好打、改成说完的,是这颗按钮最常见的用法之一;
/// 而覆盖掉他刚打的字是不可撤销的(输入框没有撤销)。
enum VoiceTranscript {
    static func merge(base: String, spoken: String) -> String {
        guard !spoken.isEmpty else { return base }
        guard !base.isEmpty else { return spoken }
        guard let last = base.last, let first = spoken.first else { return base + spoken }
        if last.isWhitespace { return base + spoken }
        // 中文之间不补空格(补了反而多一格),英文数字之间要补——「HRV」接在「my」后面
        // 挤成一个词就是另一个东西了。
        let needsSpace = last.isASCII && (last.isLetter || last.isNumber)
            && first.isASCII && (first.isLetter || first.isNumber)
        return needsSpace ? base + " " + spoken : base + spoken
    }
}

/// 按住说话。**本机识别,录音不落盘,出来的是一条和打字一模一样的文本消息。**
///
/// 用 iOS 26 的 `SpeechAnalyzer` + `SpeechTranscriber`,不用旧的 `SFSpeechRecognizer`——后者
/// 默认走服务器,而这里要的正是本机(飞行模式下照常认,音频一个字节都不出这台设备)。
///
/// 几条不要破坏的:
///
/// - **松手只填输入框,不自动发送。** 识别错一个药名就直接发出去,比多点一下糟得多;而这个
///   app 的发送按钮语义已经定过一次(「只看输入框里有没有字」),填进去正好落进那套。
/// - **Vana 自己不下载任何东西。** 本机模型是系统级的共享资产(`AssetInventory`),装没装
///   由系统和用户决定——用过 iOS 的听写就会有,没有的话在「设置 › 通用 › 键盘 › 启用听写」
///   那边装。这里只**读**状态:没装就当这台设备没有这个功能,那颗按钮整个不出现(同
///   「这台设备不支持中文」那一档)。
///
///   这条以前是反的:第一次按住说话时自动开下几百兆,既没报体积也没问一句。
///   2026-08-16 被 App Store 判了 Guideline 4.2.3(ii)。加一张写明体积的确认卡也能过,
///   但**不下载**这条更干净——不是"满足了那条规矩",是那条规矩不适用了,而且省掉了
///   下载失败、下到一半、计费流量这一整类要处理的事。
/// - **中文不可用要说得出口。** `supportedLocales` 是运行时的,SDK 里查不出来。这台设备上
///   没有中文就明说,并指一条还走得通的路(键盘上那颗麦克风)。设置页里那一段显示的就是
///   这里的状态——这个功能是否成立,靠它验。
/// - **不做常驻监听。** 没有唤醒词,不后台录音;引擎只活在手指按着的那几秒里。
/// - **不做「读出回答」那一头。** 这个 app 的回答密集全是数字、日期、区间,念出来是灾难。
///   语音输出该有的形态是 `SpokenBrief` 那三条 Siri intent(专门为口播写的一两句本地文案)。
@MainActor
@Observable
final class VoiceDictation {
    static let shared = VoiceDictation()

    /// 这台设备上这件事成不成立。
    ///
    /// 分这么细是因为四种「不能用」要说的是四句不同的话:等一下就好、按一下开始下、去系统
    /// 设置里给权限、这条路在这台设备上根本不通。合并成一句「语音识别不可用」的话,前三种
    /// 都会被当成第四种,用户就一直在等一件不会发生的事(同设置页里位置那三种状态)。
    enum Availability: Equatable {
        /// 还没查过。
        case unknown
        /// 模型装好了,按住就能说。
        case ready
        /// 这台设备支持中文,但系统还没装那份模型。**Vana 不会去下它**,所以对用户来说
        /// 这和「用不了」是同一件事,只是说法不同:那句话要指向 iOS 的听写设置。
        case needsDownload
        /// 系统正在装(别处触发的,不是 Vana)。等它装完就好,所以和 `needsDownload` 分开。
        case downloading
        /// 这台设备上没有可用的中文(或当前语言)识别。**这是 T0 那个问题的答案。**
        case unsupportedLocale
        /// 框架整个用不了。
        case unavailable

        var isReady: Bool { self == .ready }
    }

    enum Status: Equatable {
        case idle
        case starting
        case listening
    }

    private(set) var availability: Availability = .unknown
    private(set) var status: Status = .idle
    /// 这一次说出来的字(已定稿的 + 还在改的那一小段)。界面实时上屏读它。
    private(set) var transcript = ""
    /// 0…1 的音量,给波形用。
    private(set) var level: Float = 0
    /// 按了但没能开始录音时给用户看的一句话。几秒后自己消失——它是一次提示,不是一种状态。
    private(set) var notice: String?
    /// 最终真正用上的那个 locale。设置页显示它:「这台设备上认的是 zh_CN」。
    private(set) var resolvedLocale: Locale?
    /// 这台设备到底认得哪几种语言。
    ///
    /// 只在「中文不可用」那一句里露出来,而那正是唯一需要它的时候:`supportedLocales` 是运行时
    /// 的、SDK 里查不出来、模拟器上还是空的,所以「为什么不能用」在真机之外没有别的答案来源。
    /// 上一版把这句话收成一句「不支持」,结果是拿着手机也说不清到底缺的是什么(那一轮排查
    /// 花掉的时间比这个字段贵得多)。
    private(set) var supportedLocaleIdentifiers: [String] = []

    var isListening: Bool { status == .listening }

    /// 按住说话按钮亮不亮。**没授权的时候仍然亮**——按下去才是请求麦克风权限的时机,
    /// 而灰着的按钮说不出「为什么灰」。
    ///
    /// 模型没装的时候整颗不出现,和「这台设备不支持中文」同一档:Vana **自己不下载任何
    /// 东西**(见 `Availability.needsDownload`),所以那一按注定做不成事,而一颗按下去
    /// 只会说「还不能用」的按钮,比没有这颗按钮更糟。
    var isEnabled: Bool {
        switch availability {
        case .ready:
            return true
        case .unknown:
            // 还没查过就先亮着:`start()` 里会先 `refresh()` 一次,那时候才知道结果。
            // 灰着起步的话,设置页进来之前那几帧按钮会闪一下。
            return true
        case .needsDownload, .downloading, .unsupportedLocale, .unavailable:
            return false
        }
    }

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var analyzer: SpeechAnalyzer?
    @ObservationIgnored private var transcriber: SpeechTranscriber?
    @ObservationIgnored private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    @ObservationIgnored private var levelContinuation: AsyncStream<Float>.Continuation?
    @ObservationIgnored private var recognizerTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// 已经定稿的那几段。volatile 的那一小段单独放,它会被后来的结果整段替换掉。
    @ObservationIgnored private var finalized = ""
    @ObservationIgnored private var volatileText = ""
    /// 这是第几次按住说话。
    ///
    /// `start` 里有好几个 await(要权限、查资产、开引擎),而手指可以在那几百毫秒里就松开。
    /// 没有这个号的话,松手时看到的是 `.starting`,而那次已经在飞的 `start` 回来之后照样把
    /// 状态推到 `.listening`——录音留在那儿一直开着,界面上表现为按钮亮着不肯灭。
    @ObservationIgnored private var token = 0

    /// 收尾最多等这么久。等不到就把已经定稿的那部分交出去——手指已经松开了,界面不能停在
    /// 「正在听」上。
    private static let finalizeTimeout = Duration.seconds(3)
    private static let noticeDuration = Duration.seconds(5)
    /// 音量最快多久往界面上报一次。
    private static let levelInterval = Duration.milliseconds(50)

    // MARK: - 可用性

    /// 查一遍这台设备上能不能用。设置页进来时、按住说话之前各跑一次。
    ///
    /// 三步都要走:`isAvailable` 是框架层面的开关,`supportedLocales` 才回答「这台设备认不认
    /// 中文」,而 `AssetInventory.status` 回答「模型下载了没有」。`supportedLocale(equivalentTo:)`
    /// **不能单独当判据**——它只做 locale 归一化,`supportedLocales` 是空的时候它照样返回一个
    /// 看着很像样的 `zh_CN`(在模拟器上实测过)。
    func refresh() async {
        guard SpeechTranscriber.isAvailable else {
            availability = .unavailable
            resolvedLocale = nil
            return
        }

        let supported = await SpeechTranscriber.supportedLocales
        supportedLocaleIdentifiers = supported.map(\.identifier).sorted()
        guard let locale = await Self.resolveLocale(among: supported) else {
            availability = .unsupportedLocale
            resolvedLocale = nil
            return
        }
        resolvedLocale = locale

        switch await AssetInventory.status(forModules: [Self.makeTranscriber(locale: locale)]) {
        case .installed:
            availability = .ready
            // 装好了就把这个 locale 占住。名额有限(`maximumReservedLocales`),不占的话
            // 系统可能在别处把它腾走,下次按住说话又要重下一遍。失败无所谓,不影响这一次。
            try? await AssetInventory.reserve(locale: locale)
        case .downloading:
            availability = .downloading
        case .supported:
            availability = .needsDownload
        case .unsupported:
            availability = .unsupportedLocale
        @unknown default:
            availability = .unavailable
        }
    }

    /// 挑一个这台设备认得的 locale。**只认中文。**
    ///
    /// 上一版把 `Locale.preferredLanguages` 排在最前面,于是系统语言是英文的手机上挑中的是
    /// `en_US`——它在 `supportedLocales` 里、资产也装着,一路 `.ready`,按住说话认得好好的,
    /// 只是认出来的是英文。表现是「这手机识别不了中文」,而其实是这段代码自己选的。
    ///
    /// 界面整个是中文的(`developmentLanguage: zh-Hans`,文案全部硬编码),这份词表也全是中文
    /// ——拿一个英文识别器去认「甘氨酸镁」不如不认。所以系统语言在这里**不是**判据:它说的是
    /// 「这台手机的菜单用什么语言」,而这里要问的是「他会对这个 app 说什么语言」。
    ///
    /// 简繁跟着他的偏好走(那个区别是真的),都没有就退简体。一个中文都不支持时返回 nil,
    /// 那颗按钮整个不出现——**不退回英文**:悄悄给他一个做不到那件事的功能,正是上一版的毛病。
    private static func resolveLocale(among supported: [Locale]) async -> Locale? {
        var candidates = Locale.preferredLanguages
            .map { Locale(identifier: $0) }
            .filter { $0.language.languageCode == .chinese }
        candidates.append(Locale(identifier: "zh-Hans-CN"))
        candidates.append(Locale(identifier: "zh-Hant-TW"))

        for candidate in candidates {
            guard let match = await SpeechTranscriber.supportedLocale(equivalentTo: candidate) else {
                continue
            }
            // `supportedLocale(equivalentTo:)` 只归一化,不保证真的支持;要在名单里查到才算。
            if supported.contains(where: { $0.identifier == match.identifier }) {
                return match
            }
        }
        return nil
    }

    // MARK: - 录一段

    /// 开始听。**返回 false 表示这一按没有录起来**——调用方该把键盘调出来,并且屏幕上会有
    /// 一句话说清为什么(`notice`)。
    ///
    /// - Parameter vocabulary: 这条会话的词表(`VoiceVocabulary.terms`)。药名和指标名靠它
    ///   认得准,而这正是自己做语音输入的唯一硬理由。
    @discardableResult
    func start(vocabulary: [String]) async -> Bool {
        guard status == .idle else { return false }
        token += 1
        let token = token
        status = .starting

        guard await Self.requestMicrophone() else {
            return abort(token: token, notice: "要用按住说话，得先在「设置 > Vana > 麦克风」里允许录音。")
        }

        if availability != .ready {
            await refresh()
        }

        switch availability {
        case .ready:
            break
        case .needsDownload:
            // 走不到这儿(`isEnabled` 已经把按钮收起来了),留着是因为可用性是异步查的:
            // 这一按和那次查询可能撞在一起。照实说一句,不去下载。
            return abort(token: token, notice: "这台设备还没装本机语音识别模型，键盘上那颗麦克风可以用。")
        case .downloading:
            return abort(token: token, notice: "语音识别模型正在下载，先用键盘吧。")
        case .unsupportedLocale, .unavailable, .unknown:
            return abort(token: token, notice: "这台设备还不支持中文语音识别，键盘上那颗麦克风可以用。")
        }

        guard let locale = resolvedLocale else {
            return abort(token: token, notice: nil)
        }

        do {
            try await beginListening(locale: locale, vocabulary: vocabulary)
            // 开的过程中手指已经松开了:把刚开起来的这一套原样收掉,别留一个没人管的录音。
            guard token == self.token else {
                teardown()
                return false
            }
            status = .listening
            return true
        } catch {
            teardown()
            return abort(token: token, notice: "麦克风打不开，先用键盘吧。")
        }
    }

    /// 这一按没录起来。
    ///
    /// **那句话永远要说出来,哪怕手指已经松开了。** 一次按住只有几百毫秒,而查权限、查资产
    /// 都是 await——多数「没录起来」的情况里,回到这儿时手指早就抬了(`stop()` 已经把状态
    /// 收回 `.idle` 并换了号)。拿那个号去挡住提示,表现就正好是这条路上唯一不能接受的那种:
    /// 按了,什么都没发生。号只用来挡**状态**:更新的一次按下已经开始了,`status` 归它管。
    @discardableResult
    private func abort(token: Int, notice: String?) -> Bool {
        if let notice { show(notice) }
        guard token == self.token else { return false }
        status = .idle
        return false
    }

    private func beginListening(locale: Locale, vocabulary: [String]) async throws {
        finalized = ""
        volatileText = ""
        transcript = ""
        level = 0

        let transcriber = Self.makeTranscriber(locale: locale)
        self.transcriber = transcriber

        // 词表在这儿交给识别器。整份只在开始这一次交,中途不改:说到一半换词表,前半句和
        // 后半句就是在两套偏置下认出来的。
        let context = AnalysisContext()
        context.contextualStrings = [.general: vocabulary]

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.setContext(context)

        let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let (levelStream, levelContinuation) = AsyncStream<Float>.makeStream()
        self.inputContinuation = inputContinuation
        self.levelContinuation = levelContinuation

        // 结果流要在喂音频之前挂起来,不然最前面那半秒的结果没人接。
        recognizerTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        finalized += text
                        volatileText = ""
                    } else {
                        // volatile 的那一段是**整段替换**,不是追加:它是同一小截话的最新猜法。
                        volatileText = text
                    }
                    transcript = finalized + volatileText
                }
            } catch {
                // 认不出来不是错误(同「这张图里没有字」)。已经定稿的那部分照样交出去。
            }
        }

        levelTask = Task { [weak self] in
            // 麦克风一秒给四十多个 buffer,而波形上一秒二十格已经比眼睛快了。每个 buffer 都
            // 往 `@Observable` 上写一次,是让整块输入区一秒重画四十遍去画一件看不出区别的事。
            var peak: Float = 0
            var lastPublished = ContinuousClock.now
            for await value in levelStream {
                peak = max(peak, value)
                let now = ContinuousClock.now
                guard now - lastPublished >= Self.levelInterval else { continue }
                lastPublished = now
                guard let self else { return }
                // 往回收一点:直接赋值的话,说话的间隙会让波形整个塌下去,看着像录音断了。
                level = max(peak, level * 0.7)
                peak = 0
            }
        }

        let session = AVAudioSession.sharedInstance()
        // 只录不放。`.duckOthers` 让正在放的音乐小声下去而不是被掐掉——用户按住说话的时候
        // 多半正戴着耳机听东西。
        try session.setCategory(.record, mode: .default, options: [.duckOthers])
        try session.setActive(true)

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        // 识别器要的采样率和麦克风给的多半对不上(48k vs 16k),中间必须有个转换器。
        //
        // `nonisolated(unsafe)` 是这里唯一诚实的说法:`AVAudioConverter` 不是 Sendable,而它
        // 从建出来到扔掉只被音频线程碰过一次——下面那个闭包是它唯一的使用者。
        let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        nonisolated(unsafe) let converter = analyzerFormat.flatMap {
            AVAudioConverter(from: inputFormat, to: $0)
        }

        // **`@Sendable` 不是装饰,少了它当场崩。**
        //
        // 这个闭包是在一个 `@MainActor` 方法里写出来的,而一个非 `@Sendable` 的闭包会**继承
        // 那份隔离**——源码上一个字都看不出来,编译也一声不吭。但 `installTap` 是在实时音频
        // 线程上调它的,于是 Swift 运行时那句 `dispatch_assert_queue` 当场把进程打掉
        // (真机上按住说话必崩,`_swift_task_checkIsolatedSwift`;模拟器上因为这条路根本走不到
        // 所以测不出来)。`@Sendable` 的闭包永远不带隔离,这才是它该有的样子——上面那句
        // 「主线程的东西一样都不能碰」原来只是一句注释,现在类型系统真的这么认了。
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { @Sendable buffer, _ in
            // 音量和音频各走一条流,由上面那两个 Task 在主线程那头收。
            levelContinuation.yield(Self.level(of: buffer))
            guard let converted = Self.convert(buffer, using: converter) else { return }
            inputContinuation.yield(AnalyzerInput(buffer: converted))
        }

        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: inputStream)
    }

    /// 松手。返回这一次说出来的整句话(已经 trim 过),空字符串表示什么都没认出来。
    func stop() async -> String {
        guard status != .idle else { return "" }
        token += 1
        // 还没开起来就松手了(点了一下):没有音频,也没有结果流要等。
        guard status == .listening else {
            teardown()
            status = .idle
            return ""
        }
        stopAudio()

        // 让识别器把最后那一小段定稿。等不到就交已经定稿的那部分——手指已经松开了。
        let finalize = Task { [analyzer, recognizerTask] in
            try? await analyzer?.finalizeAndFinishThroughEndOfInput()
            await recognizerTask?.value
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await finalize.value }
            group.addTask { try? await Task.sleep(for: Self.finalizeTimeout) }
            await group.next()
            group.cancelAll()
        }

        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        teardown()
        status = .idle
        return text
    }

    /// 手指划开了:这一段不要了。
    func cancel() {
        guard status != .idle else { return }
        token += 1
        stopAudio()
        Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        teardown()
        status = .idle
    }

    // MARK: - 收尾

    private func stopAudio() {
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        inputContinuation?.finish()
        levelContinuation?.finish()
    }

    private func teardown() {
        stopAudio()
        recognizerTask?.cancel()
        levelTask?.cancel()
        recognizerTask = nil
        levelTask = nil
        inputContinuation = nil
        levelContinuation = nil
        engine = nil
        analyzer = nil
        transcriber = nil
        transcript = ""
        finalized = ""
        volatileText = ""
        level = 0
        // 放回去,不然按完一次说话之后别的 app 的声音会一直闷着。
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: - 零件

    /// `volatileResults` 是实时上屏的前提:没有它,用户说完一整句之前屏幕上一个字都不动。
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    private static func requestMicrophone() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        default:
            return await AVAudioApplication.requestRecordPermission()
        }
    }

    /// 麦克风给的格式转成识别器要的那个。转不动就整段丢掉——半个 buffer 的噪声喂进去,
    /// 认出来的是一个看着很正常但是错的词。
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        using converter: AVAudioConverter?
    ) -> AVAudioPCMBuffer? {
        guard let converter else { return buffer }
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0 else { return nil }
        return output
    }

    /// 波形要的那个数。
    ///
    /// 取 RMS 再压成分贝:线性幅度画出来的波形几乎一直贴着底——正常说话的 RMS 只有 0.05
    /// 上下,而人对响度的感觉本来就是对数的。
    private nonisolated static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let sample = channel[index]
            sum += sample * sample
        }
        let rms = (sum / Float(buffer.frameLength)).squareRoot()
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        // -50dB 当成静音,0dB 当成满格。
        return min(max((decibels + 50) / 50, 0), 1)
    }
}
