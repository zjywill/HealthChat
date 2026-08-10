import Foundation
import Testing

@testable import HealthChat

/// 首屏那句话。
///
/// 两头各盯一件事:本地那句(`HealthSituation.quickSummary`)得永远说得出口,模型那句
/// (`QuickSummaryWriter`)得**拿不到原始数据**——多给一个数字就是多一个它可以写错的数字,
/// 而这句话是用户打开 app 读到的第一行。
@Suite("Quick summary")
struct QuickSummaryTests {

    // MARK: - 本地那句

    @Test("说的是最要紧那件事,不是时段套话")
    func leadsWithTheTopTrigger() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)]
        )

        #expect(situation.quickSummary.contains("5.4"))
        #expect(situation.quickSummary.contains("92"))
    }

    @Test("最多两条。第三条往下该由那几颗 chip 去问")
    func staysAtTwoFacts() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [
                .shortSleep(hours: 5.4, deficitMinutes: 92),
                .elevatedRestingHR(latest: 61, baseline: 56),
                .weightShift(deltaKg: -1.4, days: 12)
            ]
        )

        #expect(situation.quickSummary.contains("5.4"))
        #expect(situation.quickSummary.contains("61"))
        // 第三条不进这句话,否则首屏就成了一份日报。
        #expect(!situation.quickSummary.contains("1.4"))
    }

    /// 排序是 `ordered` 的事,这句话只负责照着序列取。传进来的顺序就是要说的顺序。
    @Test("顺序跟着 triggers 走")
    func followsTriggerOrder() {
        let situation = HealthSituation(
            period: .afternoon,
            triggers: [
                .justTrained(name: "跑步", minutes: 42, endedMinutesAgo: 20),
                .shortSleep(hours: 5.4, deficitMinutes: 92)
            ]
        )

        let summary = situation.quickSummary
        let trained = summary.range(of: "跑步")
        let slept = summary.range(of: "5.4")
        #expect(trained != nil && slept != nil)
        #expect(trained!.lowerBound < slept!.lowerBound)
    }

    /// 「今天是周一」不是数据里发生的事。它排最后一名,只有别的什么都没有时才轮得到第一,
    /// 而那时候该说的正是"没什么特别的"——不是"周一早上,适合回顾上一周"。
    @Test("周一那条不算一件发生过的事")
    func weeklyReviewIsNotAnObservation() {
        let situation = HealthSituation(period: .morning, triggers: [.weeklyReview])

        #expect(situation.quickSummary == HealthSituation.calmSummary)
        #expect(situation.notableTriggers.isEmpty)
    }

    /// 没有触发点也要说得出一句话——「不用在意」本来就是"要不要在意"的一种回答。
    /// 但措辞收在「没读到值得留意的波动」:步数、心率、体重样本不够时是静默跳过的,
    /// 这里没有资格替用户宣布他一切都好。
    @Test("什么都没读到时也有一句,且不宣布一切正常")
    func calmSummaryDoesNotOverclaim() {
        let situation = HealthSituation(period: .evening, triggers: [])

        #expect(situation.quickSummary == HealthSituation.calmSummary)
        #expect(!situation.quickSummary.contains("正常"))
        #expect(!situation.quickSummary.contains("一切"))
    }

    // MARK: - 发给模型的那份

    /// **这条最要紧。** 喂进去的只有本地判定出来的结论,没有一行原始数据——多给的每一个
    /// 数字都是它可以写进句子里的数字。同 `FollowUpSuggester` 不喂工具输出。
    @Test("只喂结论,不喂原始数据")
    func requestCarriesConclusionsOnly() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92)]
        )
        let request = QuickSummaryWriter.request(for: situation)

        #expect(request.contains("5.4"))
        #expect(request.contains("早上"))
        // 首屏那三条问题要看原始数据才写得具体,这句话不看。工具名出现在这儿就说明
        // 有人把 `QuestionSuggester.digest()` 那套接过来了。
        #expect(!request.contains("sleep_summary"))
        #expect(!request.contains("daily_steps"))
    }

    @Test("周一那条不进发给模型的事实")
    func requestSkipsWeeklyReview() {
        let situation = HealthSituation(
            period: .morning,
            triggers: [.shortSleep(hours: 5.4, deficitMinutes: 92), .weeklyReview]
        )

        #expect(!QuickSummaryWriter.request(for: situation).contains("回顾上一周"))
    }

    // MARK: - 收模型那句

    @Test("两句写成两行也要拼回一句")
    func joinsMultipleLines() {
        let parsed = QuickSummaryWriter.parse("昨晚只睡了 5.4 小时，比平时少了一个半小时。\n今天别安排大强度。")

        #expect(parsed == "昨晚只睡了 5.4 小时，比平时少了一个半小时。今天别安排大强度。")
    }

    @Test("剥掉编号和引号那层壳")
    func stripsShell() {
        #expect(QuickSummaryWriter.parse("「昨晚睡得比平时短一些，白天注意点。」")
            == "昨晚睡得比平时短一些，白天注意点。")
    }

    /// 写超了就整句作废,退回本地那句。截断更糟:一句话在"要不要在意"之前被切断,
    /// 剩下的半句正好是最没用的那半句。
    @Test("写超了就作废,不截断")
    func rejectsOverlongText() {
        let long = String(repeating: "睡", count: QuickSummaryWriter.maxCharacters + 1)

        #expect(QuickSummaryWriter.parse(long) == nil)
    }

    @Test("一个字没写也作废")
    func rejectsEmptyText() {
        #expect(QuickSummaryWriter.parse("\n\n") == nil)
        #expect(QuickSummaryWriter.parse("好的") == nil)
    }
}
