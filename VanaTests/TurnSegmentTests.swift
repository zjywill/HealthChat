import Foundation
import Testing
import AgentRuntime

@testable import Vana

/// 助手气泡里一轮回复的**排列顺序**。
///
/// 盯的是三类失灵,它们同一个根:`text` 和 `reasoning` 各是一个一直往后接的字符串,
/// `toolCalls` 是一个数组,而模型这一轮实际是交错的(想一段、说一段、查一次,再来一轮)。
/// 三堆各自堆在一起的老排法带来的是——
///
/// - 每插一颗 chip,底下已经写好的正文整个往下挪一次(那阵跳动);
/// - 「现在查这三项：」被排到它引出的那三次查询**下面**,因果反了;
/// - 四轮思考全被拼进顶上那**一颗** chip,而且接缝处连空格都没有
///   (「I'll do them one at a time.」直接粘上「Sleep data: 3 nights recorded」)。
@Suite("TurnSegment")
struct TurnSegmentTests {

    /// 只看形状,不看内容长短。
    private static func shape(_ message: ChatMessage) -> [String] {
        message.turnSegments.map { segment in
            switch segment {
            case .reasoning(let text, _): "think:\(text)"
            case .text(let text, _): "text:\(text)"
            case .tool(let call): "tool:\(call.name)"
            }
        }
    }

    private static func finish(_ message: inout ChatMessage, id: String) {
        message.finishToolCall(id: id, output: .init(kind: .table, text: "08-06 6 小时 29 分"), isError: false)
    }

    @Test("一轮的顺序是:想、说、查,再来一轮")
    func interleavesInHappenedOrder() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendReasoning("先查睡眠。")
        message.appendText("先看睡眠。我查最近 7 晚。")
        message.startToolCall(.init(id: "1", name: "sleep_summary", input: "{}"))
        Self.finish(&message, id: "1")
        message.appendReasoning("拿到睡眠了,接着查心率。")
        message.appendText("睡眠结果：三晚有记录。我查最近 7 天。")
        message.startToolCall(.init(id: "2", name: "heart_rate_summary", input: "{}"))
        Self.finish(&message, id: "2")
        message.appendText("心率结果：贴着基线。")

        #expect(Self.shape(message) == [
            "think:先查睡眠。",
            "text:先看睡眠。我查最近 7 晚。",
            "tool:sleep_summary",
            "think:拿到睡眠了,接着查心率。",
            "text:睡眠结果：三晚有记录。我查最近 7 天。",
            "tool:heart_rate_summary",
            "text:心率结果：贴着基线。",
        ])
    }

    /// 这一条是「第二轮到底有没有 thinking」在界面上唯一的答案。两轮的思考粘在一颗 chip 里
    /// 时,屏幕上看不出哪一轮想过——而它们本来就是分开的两段。
    @Test("哪一轮没想,那一轮就没有思考 chip")
    func skipsChipForRoundsWithoutReasoning() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendReasoning("先查睡眠。")
        message.appendText("我查一下。")
        message.startToolCall(.init(id: "1", name: "sleep_summary", input: "{}"))
        Self.finish(&message, id: "1")
        // 第二轮一个字的思考都没有,直接接着说。
        message.appendText("三晚有记录。")

        #expect(Self.shape(message) == [
            "think:先查睡眠。",
            "text:我查一下。",
            "tool:sleep_summary",
            "text:三晚有记录。",
        ])
    }

    /// 同一批发出去的几次调用位置相同,连着排,中间不插空段。
    @Test("并行发起的几次调用连着排")
    func keepsParallelCallsTogether() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendText("三项一起查。")
        message.startToolCall(.init(id: "1", name: "sleep_summary", input: "{}"))
        message.startToolCall(.init(id: "2", name: "heart_rate_summary", input: "{}"))
        Self.finish(&message, id: "1")
        Self.finish(&message, id: "2")
        message.appendText("都拿到了。")

        #expect(Self.shape(message) == [
            "text:三项一起查。",
            "tool:sleep_summary",
            "tool:heart_rate_summary",
            "text:都拿到了。",
        ])
    }

    /// 之前存下来的会话里没有这两个位置。**不去猜**——猜错的表现是一段话被切在莫名其妙的
    /// 地方,而退回老排法只是没那么好看。
    @Test("旧会话退回老排法:思考和 chip 都在正文前面")
    func fallsBackWhenOffsetsAreMissing() {
        let message = ChatMessage(
            role: .assistant,
            text: "查完了,三晚有记录。",
            reasoning: "先查睡眠。",
            toolCalls: [ToolCallRecord(id: "1", name: "sleep_summary", input: "{}", output: "…")]
        )

        #expect(Self.shape(message) == [
            "think:先查睡眠。",
            "tool:sleep_summary",
            "text:查完了,三晚有记录。",
        ])
    }

    /// 撤字发生在重试之前(`.textRolledBack`),而那几颗 chip 的位置早就记下了。夹不住的话
    /// 这里是一次越界。
    @Test("撤字之后越界的位置被夹回正文末尾")
    func clampsOffsetsPastTheEnd() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendText("先看睡眠，我查一下。")
        message.startToolCall(.init(id: "1", name: "sleep_summary", input: "{}"))
        Self.finish(&message, id: "1")
        message.rollBackText(6)

        #expect(Self.shape(message) == ["text:先看睡眠", "tool:sleep_summary"])
    }

    /// `ask_user` 成功的那次不出胶囊(卡片就在下面),所以它也**不在正文里切一刀**——
    /// 屏幕上那个位置什么都没有,切开只会让一段话在莫名其妙的地方断开。
    @Test("不出胶囊的那次调用不切正文")
    func doesNotSplitAroundHiddenCalls() throws {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendText("这个得先问你一句。")
        message.startToolCall(.init(id: "1", name: AskUserTools.askToolName, input: "{}"))
        let asked = AskUserQuestion(
            question: "你说的头疼是哪一种？",
            options: [.init(label: "胀痛"), .init(label: "刺痛")]
        )
        message.finishToolCall(
            id: "1",
            output: .init(
                kind: .text,
                text: "已显示",
                metadata: AskUserQuestion.encodeForToolMetadata(asked)
            ),
            isError: false
        )
        message.appendText("等你选完再往下说。")

        #expect(Self.shape(message) == ["text:这个得先问你一句。等你选完再往下说。"])
    }

    /// 切点落在换行后面时那一段会以空行开头,chip 底下会多撑出一截空白。
    @Test("切出来的段落不带前导空行")
    func trimsLeadingBlankLines() {
        var message = ChatMessage(role: .assistant, text: "")
        message.appendText("我查一下。\n\n")
        message.startToolCall(.init(id: "1", name: "sleep_summary", input: "{}"))
        Self.finish(&message, id: "1")
        message.appendText("\n\n三晚有记录。")

        #expect(Self.shape(message) == [
            "text:我查一下。",
            "tool:sleep_summary",
            "text:三晚有记录。",
        ])
    }
}
