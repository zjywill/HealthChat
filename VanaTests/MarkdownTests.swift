import Foundation
import Testing

@testable import Vana

/// 助手气泡里的块级 markdown。
///
/// 盯的是**屏幕上出现原始符号**这一类失灵:气泡原来只认行内语法,模型列每日数据用的表格
/// 于是变成一堆竖线和横杠。看不懂那堆符号的人恰好最需要那张表。
@Suite("Markdown")
struct MarkdownTests {

    private static func table(in text: String) -> MarkdownTable? {
        for case .table(let table) in MarkdownBlocks.parse(text) { return table }
        return nil
    }

    @Test("表格拆得出表头和数据行")
    func parsesTable() throws {
        let table = try #require(Self.table(in: """
            | 日期 | 入睡 | 深睡 |
            |------|------|------|
            | 08-06 | 22:32 | 77 分钟 |
            | 08-05 | 23:10 | 83 分钟 |
            """))
        #expect(table.headers == ["日期", "入睡", "深睡"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0] == ["08-06", "22:32", "77 分钟"])
    }

    @Test("两侧的竖线可有可无")
    func parsesTableWithoutOuterPipes() throws {
        let table = try #require(Self.table(in: """
            日期 | 深睡
            --- | ---
            08-06 | 77 分钟
            """))
        #expect(table.headers == ["日期", "深睡"])
        #expect(table.rows == [["08-06", "77 分钟"]])
    }

    /// 只看竖线的话,正文里的顿号写法会被当成一张两行的表——而它只是一句话。
    @Test("没有分隔行就不是表格")
    func requiresDelimiterRow() {
        let blocks = MarkdownBlocks.parse("深睡 | 核心 | REM 三个阶段都读到了。")
        #expect(blocks == [.text("深睡 | 核心 | REM 三个阶段都读到了。")])
    }

    /// `---` 单独一行是分割线,不是表格的分隔行。
    @Test("横线不当成分隔行")
    func horizontalRuleIsNotADelimiter() {
        let blocks = MarkdownBlocks.parse("""
            这里有 | 一根竖线
            ---
            后面还有话
            """)
        #expect(Self.table(in: "这里有 | 一根竖线\n---\n后面还有话") == nil)
        #expect(blocks.count == 1)
    }

    /// 少显示一个数字比排版难看严重得多。
    @Test("行比表头长或短都不丢格子")
    func padsRaggedRows() throws {
        let table = try #require(Self.table(in: """
            | 日期 | 深睡 |
            |---|---|
            | 08-06 |
            | 08-05 | 83 分钟 | 多出来的一格 |
            """))
        #expect(table.columnCount == 3)
        #expect(table.rows[0] == ["08-06", "", ""])
        #expect(table.rows[1] == ["08-05", "83 分钟", "多出来的一格"])
    }

    /// 流式输出中途的正常状态:表头和分隔行已经吐出来了,第一行还没到。
    @Test("只有表头也是一张表，不是错误")
    func headerOnlyTableIsValid() throws {
        let table = try #require(Self.table(in: "| 日期 | 深睡 |\n|---|---|"))
        #expect(table.headers == ["日期", "深睡"])
        #expect(table.rows.isEmpty)
        #expect(!table.isEmpty)
    }

    @Test("表格前后的段落都留着")
    func keepsSurroundingProse() {
        let blocks = MarkdownBlocks.parse("""
            最近四晚是这样：

            | 日期 | 深睡 |
            |---|---|
            | 08-06 | 77 分钟 |

            深睡一路小幅往下走。
            """)
        #expect(blocks.count == 3)
        #expect(blocks.first == .text("最近四晚是这样："))
        #expect(blocks.last == .text("深睡一路小幅往下走。"))
    }

    @Test("标题不留井号")
    func parsesHeading() {
        #expect(MarkdownBlocks.parse("## 睡眠") == [.heading("睡眠")])
        // 井号后面没有字的不算标题,原样留着。
        #expect(MarkdownBlocks.parse("###") == [.text("###")])
    }

    /// `.full` 会按 CommonMark 把单换行折叠掉,模型列的每日数据于是糊成一坨
    /// (「22:26–05:19」直接粘上下一行的日期)。这条盯着那一档没被换掉。
    @Test("段落里的单换行不许被折叠")
    func preservesSingleNewlines() {
        let rendered = String(MarkdownInline.attributed("08-06 22:26–05:19\n08-05 23:10–06:02").characters)
        #expect(rendered.contains("\n"))
    }
}

/// 中文标点后面紧接着汉字时的粗体。
///
/// 盯的还是**屏幕上出现原始符号**那一类失灵:「**小标题：**正文」是模型写中文时最爱用的
/// 格式之一,而 CommonMark 的 flanking 规则认不出它的收尾——星号原样显示给用户看。
@Suite("中文粗体")
struct CJKEmphasisTests {

    private static func bold(in text: String) -> [String] {
        let attributed = MarkdownInline.attributed(text)
        return attributed.runs.compactMap { run in
            guard run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true else { return nil }
            return String(attributed[run.range].characters)
        }
    }

    private static func plain(_ text: String) -> String {
        String(MarkdownInline.attributed(text).characters)
    }

    /// 复现:闭合的 `**` 前面是「：」、后面是汉字,强调不闭合,两对星号原样显示。
    @Test("中文标点后接汉字的粗体要渲染出来")
    func rendersBoldBeforeCJK() {
        let text = "**睡眠结果先说重点：**最近 7 天只有 3 晚有记录"
        #expect(Self.plain(text) == "睡眠结果先说重点：最近 7 天只有 3 晚有记录")
        #expect(Self.bold(in: text) == ["睡眠结果先说重点"])
    }

    /// 冒号挪到粗体外面,**一个字符都不增不减、顺序也不变**——只是它不再是粗体。
    @Test("挪的是位置，不是字")
    func movesPunctuationWithoutChangingCharacters() {
        #expect(CJKEmphasis.rebalanced("**重点：**最近") == "**重点**：最近")
        #expect(CJKEmphasis.rebalanced("第一条**注意：**别空腹") == "第一条**注意**：别空腹")
        // 开头那一侧同理:`**「睡眠」**很差` 里开合两边都不合规。
        #expect(CJKEmphasis.rebalanced("最近**「睡眠」**很差") == "最近「**睡眠**」很差")
    }

    /// 系统本来就认得的不要动——不然「**睡眠**：」也会被翻一遍,而它本来就是对的。
    @Test("系统认得的原样留着")
    func leavesValidEmphasisAlone() {
        #expect(CJKEmphasis.rebalanced("**睡眠**：最近 7 天") == "**睡眠**：最近 7 天")
        #expect(CJKEmphasis.rebalanced("**bold** text") == "**bold** text")
        #expect(Self.bold(in: "**睡眠**：最近 7 天") == ["睡眠"])
    }

    /// 落单的星号从头到尾不在这套东西的视野里:只认成对的 `**`。
    @Test("普通星号一个都不碰")
    func ignoresLoneAsterisks() {
        #expect(CJKEmphasis.rebalanced("1*2*3 是这么算的") == "1*2*3 是这么算的")
        #expect(CJKEmphasis.rebalanced("2**3 次方") == "2**3 次方")
        #expect(CJKEmphasis.rebalanced("***又粗又斜：***正文") == "***又粗又斜：***正文")
    }

    /// 代码里的星号就是星号。
    @Test("代码块和行内代码不碰")
    func leavesCodeAlone() {
        let fenced = """
            ```
            **重点：**这是代码
            ```
            """
        #expect(CJKEmphasis.rebalanced(fenced) == fenced)
        #expect(CJKEmphasis.rebalanced("行内 `**重点：**` 这样") == "行内 `**重点：**` 这样")
        // 反引号没有收尾的时候它只是个反引号,外面那对粗体照修。
        #expect(CJKEmphasis.rebalanced("`未闭合 **重点：**正文") == "`未闭合 **重点**：正文")
    }

    /// 挪完还是不合规就整个放弃:宁可留着那对星号,也不端出一段被改坏的话。
    @Test("挪不动就原样留着")
    func givesUpWhenRebalancingWouldNotHelp() {
        // 里面全是标点,挪完就剩一对空定界符。
        #expect(CJKEmphasis.rebalanced("**……**正文") == "**……**正文")
        // markdown 自己要用的标点不挪:挪走 `]` 会拆掉一个链接。
        #expect(CJKEmphasis.rebalanced("**[标题]**正文") == "**[标题]**正文")
    }

    /// 表格的格子和标题走的是同一条行内解析,这条盯着它们一起受益。
    @Test("表格格子里的粗体也认")
    func appliesInsideTableCells() {
        #expect(Self.plain("**深睡：**77 分钟") == "深睡：77 分钟")
    }
}
