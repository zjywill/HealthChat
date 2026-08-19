import CoreGraphics
import Testing

@testable import Vana

/// 输入区上方那颗「回到底部」什么时候出现。
///
/// 盯的是 2026-08-20 在 iPhone 上逮到的那次:第一版把底部安全区算了两遍
/// (`contentSize + insB - (offset + containerSize)`),而 `containerSize` **已经是扣掉安全区
/// 之后的高度**。贴在底部时它算出 284、门槛才 240,于是那颗按钮一直亮着——界面上不报错,
/// 只是一个本该藏起来的按钮从不消失。
///
/// 下面两组数字是真机上读出来的,不是推出来的。
@Suite("Jump to bottom")
struct JumpToBottomTests {

    /// 贴在底部:874 的屏,上下安全区 116 / 156,所以 `containerSize` 是 602。
    /// 正文底下还有 12 点内边距,所以「下面还剩多少」应该是个位数,不是 284。
    @Test("贴底时算出来接近 0")
    func atBottom() {
        let below = ScrollBottomDistance.below(contentHeight: 4246, visibleMaxY: 4390, bottomInset: 156)
        #expect(below < 20)
        #expect(!ScrollBottomDistance.isScrolledUp(
            contentHeight: 4246, visibleMaxY: 4390, bottomInset: 156, threshold: 240
        ))
    }

    /// 往回翻 708 点之后的同一屏:偏移 3516 → 2808,`visibleRect.maxY` 4390 → 3682。
    /// 「下面还剩多少」要跟着走同样的距离。
    @Test("往回翻多远，就是多远")
    func tracksTheScroll() {
        let atBottom = ScrollBottomDistance.below(contentHeight: 4246, visibleMaxY: 4390, bottomInset: 156)
        let scrolledUp = ScrollBottomDistance.below(contentHeight: 4246, visibleMaxY: 3682, bottomInset: 156)
        #expect(abs((scrolledUp - atBottom) - 708) < 1)
        #expect(ScrollBottomDistance.isScrolledUp(
            contentHeight: 4246, visibleMaxY: 3682, bottomInset: 156, threshold: 240
        ))
    }

    /// 内容比一屏还短:下面本来就没有东西,那颗按钮不该出现。
    @Test("内容不满一屏时不出现")
    func shortConversation() {
        #expect(!ScrollBottomDistance.isScrolledUp(
            contentHeight: 300, visibleMaxY: 874, bottomInset: 156, threshold: 240
        ))
    }
}
