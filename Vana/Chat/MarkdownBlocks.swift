import Foundation

/// 一段回答拆成的块。
///
/// 气泡原来整段走 `AttributedString(markdown:)` 的 `.inlineOnlyPreservingWhitespace`——粗体、
/// 代码这些行内语法认得,**块级语法一个都不认**。模型很爱用表格列每日数据,于是屏幕上出现的
/// 是一堆竖线和横杠:
///
///     | 日期 | 入睡 | 深睡 |
///     |------|------|------|
///     | 08-06 | 22:32 | 77 分钟 |
///
/// 这不是"样式差一点",是**把一份整理好的数据退回成了原始文本**——而看不懂那堆符号的人,
/// 恰好最需要那张表。
///
/// 那个 `.inlineOnlyPreservingWhitespace` 不能换成 `.full`:它会按 CommonMark 把单换行折叠掉,
/// 模型列的每日数据会糊成一坨(踩过,见 `ChatMessageView.displayText` 上那句注释)。所以块级
/// 那一层在这儿自己拆,行内那一层仍然交给系统。
enum MarkdownBlock: Equatable {
    case text(String)
    /// `## 标题`。不认的话屏幕上就留着两个井号。
    case heading(String)
    case table(MarkdownTable)
}

/// 一张表。**不丢格子**:某一行比表头多出一列时,补的是表头而不是砍掉那一格——
/// 这是健康数据,少显示一个数字比排版难看严重得多。
struct MarkdownTable: Equatable {
    var headers: [String]
    var rows: [[String]]

    var columnCount: Int { headers.count }

    /// 只有表头、还没有数据行,是**流式输出中途的正常状态**(表头和分隔行已经吐出来了,
    /// 第一行还没到)。不当成错误,照常画出表头——下一片到了它自己就长出来。
    var isEmpty: Bool { headers.isEmpty }
}

enum MarkdownBlocks {

    /// 把一段回答拆成块。纯函数,可测。
    static func parse(_ text: String) -> [MarkdownBlock] {
        let lines = text.components(separatedBy: .newlines)
        var blocks: [MarkdownBlock] = []
        var buffer: [String] = []

        func flushText() {
            let joined = buffer
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeAll()
            guard !joined.isEmpty else { return }
            blocks.append(.text(joined))
        }

        var index = 0
        while index < lines.count {
            if let (table, next) = table(startingAt: index, in: lines) {
                flushText()
                blocks.append(.table(table))
                index = next
                continue
            }
            if let heading = heading(in: lines[index]) {
                flushText()
                blocks.append(.heading(heading))
                index += 1
                continue
            }
            buffer.append(lines[index])
            index += 1
        }
        flushText()
        return blocks
    }

    // MARK: - 表格

    /// **必须有分隔行才算表格。** 只看竖线的话,「深睡 | 核心 | REM」这种正文里的顿号写法
    /// 会被当成一张两行的表——而它只是一句话。
    private static func table(startingAt index: Int, in lines: [String]) -> (MarkdownTable, Int)? {
        guard index + 1 < lines.count,
              isRow(lines[index]),
              isDelimiter(lines[index + 1])
        else { return nil }

        let headers = cells(in: lines[index])
        guard !headers.isEmpty else { return nil }

        var rows: [[String]] = []
        var next = index + 2
        while next < lines.count, isRow(lines[next]) {
            rows.append(cells(in: lines[next]))
            next += 1
        }

        // 补齐到最宽的那一行。模型偶尔会漏掉一格,也可能多出一格;两种情况都不该让某个
        // 数字消失,也不该让整张表错位。
        let width = max(headers.count, rows.map(\.count).max() ?? 0)
        return (
            MarkdownTable(
                headers: padded(headers, to: width),
                rows: rows.map { padded($0, to: width) }
            ),
            next
        )
    }

    private static func isRow(_ line: String) -> Bool {
        line.contains("|") && !line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `|---|:--:|` 这一行。`---` 单独一行是分割线不是表格,所以竖线是必需的。
    private static func isDelimiter(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|"), trimmed.contains("-") else { return false }
        return trimmed.allSatisfy { "|:- \t".contains($0) }
    }

    /// 两侧的竖线可有可无(模型两种都写)。
    private static func cells(in line: String) -> [String] {
        var parts = line
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.first?.isEmpty == true { parts.removeFirst() }
        if parts.last?.isEmpty == true { parts.removeLast() }
        return parts
    }

    private static func padded(_ cells: [String], to width: Int) -> [String] {
        cells + Array(repeating: "", count: max(0, width - cells.count))
    }

    // MARK: - 标题

    private static func heading(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }
        guard hashes.count <= 6 else { return nil }
        let title = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}

// MARK: - 行内

enum MarkdownInline {
    /// 行内语法交给系统,块级那一层由 `MarkdownBlocks` 先拆掉。
    ///
    /// `.inlineOnlyPreservingWhitespace` 那一档是有意的:`.full` 会按 CommonMark 把单换行
    /// 折叠掉,模型列的每日数据于是糊成一坨(「22:26–05:19」直接粘上下一行的日期)。
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}
