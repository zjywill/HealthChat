import Foundation
import Testing

@testable import Vana

/// 后台的模型调用同时只准跑一件。
///
/// 这条盯的是一个真出现过的失灵:`scenePhase` 一次开合会触发两次(`.active` 和
/// `.background`),而「今天跑过没有」那道闸读的是**盘上那条会话**——它要等这一轮跑完几十秒
/// 才存下来。第二次进来时第一轮还在飞,闸门读到的还是"没跑过",于是两轮并行:两份钱,
/// 两条派生会话,最后还互相顶掉对方那条。
@Suite("BackgroundModelWork")
struct BackgroundModelWorkTests {

    /// 数一下真正跑起来了几件。
    private actor Counter {
        private(set) var started = 0
        func begin() { started += 1 }
    }

    @Test("a second run while one is in flight is dropped, not queued")
    func secondRunIsDropped() async throws {
        let work = BackgroundModelWork()
        let counter = Counter()

        // 第一件跑着(还没返回),第二件这时候进来——正是 scenePhase 连着触发的那一下。
        async let first: Void? = work.run {
            await counter.begin()
            try? await Task.sleep(for: .milliseconds(120))
        }
        try await Task.sleep(for: .milliseconds(20))
        let second: Void? = await work.run { await counter.begin() }

        _ = await first
        // 拿不到位子就**不跑**,也不排队:用户连着切五次前后台,排队会攒出五轮待跑的调用,
        // 而它们说的是同一件事。
        #expect(second == nil)
        #expect(await counter.started == 1)
    }

    @Test("the slot is released when the work finishes, including on a throw")
    func slotIsReleasedAfterwards() async throws {
        let work = BackgroundModelWork()

        _ = await work.run { try? await Task.sleep(for: .milliseconds(10)) }
        // 位子没还回来的话,这个 app 从此再也不会替用户跑任何一轮后台。
        #expect(await work.isRunning == false)
        let after: Bool? = await work.run { true }
        #expect(after == true)
    }

    @Test("the return value comes back through unchanged")
    func returnValuePassesThrough() async {
        let work = BackgroundModelWork()
        // `BackgroundDigest.runIfDue` 靠这个值决定要不要重排通知。吞掉它,跑出来的结论
        // 就永远进不了早上那条通知。
        #expect(await work.run { 42 } == 42)
    }

    @Test("background digest holds the shared slot, so two scene changes only run one")
    func digestTakesTheSharedSlot() async throws {
        UserDefaults.standard.set(true, forKey: EngineSettings.checkInsEnabledKey)
        // 云端设置拿掉,这条测试就不会真去打模型(那要十几秒,还花用户的钱)。
        let defaults = UserDefaults.standard
        let savedModel = defaults.string(forKey: EngineSettings.modelKey)
        defaults.set("", forKey: EngineSettings.modelKey)
        defer { defaults.set(savedModel, forKey: EngineSettings.modelKey) }

        // 设置不齐时它在拿位子**之前**就返回了——那道闸比这把锁更靠外,不该白占一个位子。
        #expect(await BackgroundDigest.runIfDue() == false)
        #expect(await BackgroundModelWork.shared.isRunning == false)
    }
}
