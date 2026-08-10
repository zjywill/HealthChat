import Foundation
import AIKit

/// 首屏那句话的润色。
///
/// 本地已经算出了「发生了什么」(`HealthSituation.quickSummary`),这一步只把它写成人话。
/// 分两级和首屏那三条建议是同一套:本地那句立刻出、不花钱、没配 key 也有,模型那句回来了
/// 原地换掉。所以**失败即放弃**——调用方手里已经有一句能显示的话了。
///
/// 和 `QuestionSuggester` 的区别只在喂什么:那边要写具体的问题,得看见最近几天的原始数据;
/// 这边**只喂本地判定出来的那几条结论,一行原始数据都不给**。多给的每一个数字都是它可以
/// 写进句子里的数字,而这句话是用户打开 app 看到的第一句——帖子里抱怨 Gemini Health 的
/// 「偶尔报错健康数据」正是这条路上出的事。少给一半材料换掉一整类幻觉,划算。
struct QuickSummaryWriter: Sendable {
    let providerId: String
    let model: String
    /// 本地判定出来的处境。模型拿到的是"昨晚少睡 100 分钟"这种结论,不是一堆原始数字。
    let situation: HealthSituation

    /// 首屏一句话的上限。
    ///
    /// 两行左右。再长就不是"几秒钟看完"的东西了,而这句话的全部价值就在于它比下面那张
    /// 欢迎卡先被读完。
    static let maxCharacters = 60

    private static let instructions = """
    你在为一个健康 app 的首屏写一句话。用户刚打开它，还没开口问任何事，\
    这句话是他看到的第一行字。

    要求：
    - 只输出一到两句中文，写成一段，不要换行，总共不超过 60 个字。
    - 只说「发生了什么」和「要不要在意」。不要提问，不要给建议、行动方案或者安慰。
    - 只能用下面给出的事实。**不许出现事实里没有的数字**，也不要把给出的数字换算成别的说法。
    - 口气平静，像一个刚看过数据的人随口说的第一句，不是播报。不要用「您」。
    - 不做诊断，不提疾病名。
    - 不要编号、不要引号、不要任何解释。
    """

    /// 返回一句可以直接显示的话。
    ///
    /// 模型没帮上忙的每一种情况(没什么可说、没配 key、写跑题了)都**原样退回本地那句**,
    /// 而不是返回空——首屏那个位置不该因为一次网络失败就空一块。
    func summary() async throws -> String {
        // 没有触发点时根本不叫模型:让它为"没什么可说"写一句,它会为了有话说而把常态
        // 写成异常——而那正是这句话最不能出的错。顺带省下一次调用。
        guard !situation.notableTriggers.isEmpty else { return situation.quickSummary }

        guard let storedKey = try KeychainStore.get(account: KeychainStore.apiKeyAccount) else {
            throw AgentError.needsAPIKey
        }
        let key = storedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AgentError.needsAPIKey }

        let client = try AIClient(providerId: providerId, configuration: .init(apiKey: key))
        let response = try await client.generate(CallOptions(
            model: model,
            prompt: [
                .system(Self.instructions),
                .user(Self.request(for: situation))
            ],
            maxOutputTokens: 200,
            // 比首屏那三条低:这句话要贴着给定的事实写,不需要它发挥。
            temperature: 0.4,
            // 同 `FollowUpSuggester`:留空是接受模型的默认,而好几家的默认是思考——
            // 思考算进 output,这 200 个 token 会在写出正文之前就用光。
            thinking: .off
        ))

        guard let written = Self.parse(response.text) else {
            #if DEBUG
            // 作废这条路是静默的:界面上只表现为"本地那句一直没换掉"。写长了、带了壳、
            // 分成三行写,原因只有原文说得清。
            print("[首屏一句话] 这次没能用，模型原样输出：\n\(response.text)")
            #endif
            return situation.quickSummary
        }
        return written
    }

    /// 不是 private:发给模型的到底是哪几条事实,得有测试盯着——尤其是"原始数据没跟着进去"。
    static func request(for situation: HealthSituation) -> String {
        let facts = situation.notableTriggers.prefix(3).map { "- \($0.brief)" }
        return """
        现在是\(situation.period.label)。

        从他的健康数据里读到的事实（按重要性排好，第一条最该被说到）：
        \(facts.joined(separator: "\n"))
        """
    }

    static func parse(_ text: String) -> String? {
        ModelLines.single(text, minCharacters: 8, maxCharacters: maxCharacters)
    }
}
