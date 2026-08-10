import Foundation
import Testing

@testable import HealthChat

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
