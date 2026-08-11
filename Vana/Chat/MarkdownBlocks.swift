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
    ///
    /// 交给系统之前先过一道 `CJKEmphasis`——中文里最常见的一种粗体写法,CommonMark 认不出来。
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: CJKEmphasis.rebalanced(text),
            options: .init(
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )) ?? AttributedString(text)
    }
}

/// 中文标点后面紧接着汉字时,粗体不闭合——星号原样显示给用户看。
///
/// 模型写 `**睡眠结果先说重点：**最近 7 天只有 3 晚有记录`,屏幕上出现的是两对星号。根子在
/// CommonMark 的 delimiter flanking 规则:闭合的那个 `**` 前一个字符是「：」(标点)、后一个
/// 字符是「最」(既不是空白也不是标点),于是它不算 right-flanking delimiter,强调不闭合。
/// 反过来 `**睡眠**：` 没事——那时候 `**` 后面跟着的是标点。
///
/// 那条规则是照着西文写的:英文里 `**bold**` 后面天然跟着一个空格。中文没有词间空格,而
/// 「**小标题：**正文」恰好是模型写中文时最爱用的格式之一,所以这条路每天都会走到。
///
/// **修的是渲染这一侧,不是提示词。** 中文标点后面直接接汉字本来就是正常中文,模型没写错;
/// 而 `.inlineOnlyPreservingWhitespace` 也不能为此换成 `.full`(它会把单换行折叠掉,见上)。
///
/// 做法是把贴着定界符**内侧**的标点挪到外面去:`**重点：**正文` → `**重点**：正文`。这是一次
/// 纯粹的重排——**一个字符都不增不减,前后顺序也不变**,唯一的代价是那个冒号不再是粗体。
/// 在一个逐字显示化验数值的 app 里这个性质比"冒号也要粗"要紧得多:插零宽字符、或者干脆自己
/// 拼 `AttributedString`,都会多出一条能把数字弄丢或者弄错位的路,而屏幕上看不出来。
///
/// 四条边界:
///
/// - **代码不碰**。围栏(``` / ~~~)和行内反引号里的星号原样留着——那儿的星号就是星号。
/// - **只认成对的 `**`**。落单的星号(`1*2*3` 这种乘号写法)和 `***三个***` 从头到尾不在这套
///   东西的视野里,行为和以前逐字一样。
/// - **系统认得的不动**。两侧都合规时原样返回,不做无谓的重排——不然「**睡眠**：」也会被
///   翻一遍,而它本来就是对的。
/// - **挪完复核,过不了就整个放弃**。宁可留着那对星号(用户看得见、看得懂那是没渲染),
///   也不端出一段被改坏的话。
enum CJKEmphasis {

    /// 纯函数,可测。
    static func rebalanced(_ text: String) -> String {
        guard text.contains("**") else { return text }

        var chars = Array(text)
        let code = codeMask(chars)
        let starts = delimiters(in: chars, code: code)
        guard starts.count >= 2 else { return text }

        var changed = false
        // 重排不改变长度,所以下标一直有效;从后往前只是为了嵌套时里面那一对先定下来,
        // 外面那一对看到的邻居才是最终形态。
        for pair in pairs(of: starts, in: chars).sorted(by: { $0.open > $1.open }) {
            if rebalance(open: pair.open, close: pair.close, in: &chars) { changed = true }
        }
        return changed ? String(chars) : text
    }

    // MARK: - 找定界符

    /// 只认长度**正好**是 2 的那种。`***又粗又斜***` 和落单的 `*` 交给系统,少一处能判错的地方。
    private static func delimiters(in chars: [Character], code: [Bool]) -> [Int] {
        var result: [Int] = []
        var index = 0
        while index < chars.count {
            guard chars[index] == "*", !code[index] else {
                index += 1
                continue
            }
            var end = index
            while end < chars.count, chars[end] == "*", !code[end] { end += 1 }
            if end - index == 2 { result.append(index) }
            index = end
        }
        return result
    }

    /// 配对。**这里用的是放宽过的规则**(只要求定界符不贴着空白),否则出问题的那一对
    /// 恰好就是配不上的那一对——严格规则正是它渲染不出来的原因。
    private static func pairs(of starts: [Int], in chars: [Character]) -> [(open: Int, close: Int)] {
        var stack: [Int] = []
        var result: [(open: Int, close: Int)] = []
        for start in starts {
            let canClose = !isWhitespace(chars[safe: start - 1])
            let canOpen = !isWhitespace(chars[safe: start + 2])
            if canClose, let open = stack.popLast() {
                // 中间一个字都没有的 `****` 本来就画不出东西,两个都丢掉。
                if start > open + 2 { result.append((open, start)) }
            } else if canOpen {
                stack.append(start)
            }
        }
        return result
    }

    // MARK: - 重排

    private static func rebalance(open: Int, close: Int, in chars: inout [Character]) -> Bool {
        let contentStart = open + 2
        guard close > contentStart else { return false }

        let opening = flanking(at: open, in: chars)
        let closing = flanking(at: close, in: chars)
        // 系统自己认得,别动它。
        guard !(opening.left && closing.right) else { return false }

        var lead = 0
        if !opening.left {
            while contentStart + lead < close, isMovable(chars[contentStart + lead]) { lead += 1 }
        }
        var trail = 0
        if !closing.right {
            while close - trail - 1 >= contentStart + lead, isMovable(chars[close - trail - 1]) { trail += 1 }
        }
        guard lead > 0 || trail > 0 else { return false }
        // 挪完里面就空了(比如 `**……**`)——那对星号留着,总好过拼出一个 `****`。
        guard contentStart + lead < close - trail else { return false }

        let region = chars[open..<(close + 2)]
        let coreStart = region.startIndex + 2 + lead
        let coreEnd = region.endIndex - 2 - trail
        let rearranged = Array(region[(region.startIndex + 2)..<coreStart])
            + ["*", "*"]
            + Array(region[coreStart..<coreEnd])
            + ["*", "*"]
            + Array(region[coreEnd..<(region.endIndex - 2)])

        var probe = chars
        probe.replaceSubrange(open..<(close + 2), with: rearranged)
        // 复核:挪完之后两侧都得真的合规,不然这一趟只是把话改坏了。
        guard flanking(at: open + lead, in: probe).left,
              flanking(at: close - trail, in: probe).right
        else { return false }

        chars = probe
        return true
    }

    // MARK: - flanking

    /// CommonMark 的 left/right-flanking 判定。行首行尾按空白算。
    private static func flanking(at start: Int, in chars: [Character]) -> (left: Bool, right: Bool) {
        let before = chars[safe: start - 1]
        let after = chars[safe: start + 2]
        return (
            left: !isWhitespace(after)
                && (!isPunctuation(after) || isWhitespace(before) || isPunctuation(before)),
            right: !isWhitespace(before)
                && (!isPunctuation(before) || isWhitespace(after) || isPunctuation(after))
        )
    }

    private static func isWhitespace(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace
    }

    /// CommonMark 的「Unicode punctuation character」:ASCII 那一串,加上 Unicode 的 P 类。
    /// 中文那些(:,。!?「」（）、;…—)全在 P 类里。
    private static func isPunctuation(_ character: Character?) -> Bool {
        guard let character else { return false }
        return asciiPunctuation.contains(character) || character.isPunctuation
    }

    /// 可以挪的标点。markdown 自己要用的那些一个都不挪:把 `]` 挪出去会拆掉一个链接,
    /// 把 `*` 挪出去会当场拼出第三个星号。挪不动就在上面那道复核里整个放弃。
    private static func isMovable(_ character: Character) -> Bool {
        isPunctuation(character) && !reservedPunctuation.contains(character)
    }

    private static let asciiPunctuation = Set(##"!"#$%&'()*+,-./:;<=>?@[\]^_`{|}~"##)
    private static let reservedPunctuation = Set(##"*_`[]()<>~\!#|&"##)

    // MARK: - 代码

    /// 围栏和行内反引号盖住的位置。那儿的星号就是星号。
    private static func codeMask(_ chars: [Character]) -> [Bool] {
        var mask = [Bool](repeating: false, count: chars.count)

        var index = 0
        var fence: (marker: Character, length: Int)?
        while index < chars.count {
            var lineEnd = index
            while lineEnd < chars.count, chars[lineEnd] != "\n" { lineEnd += 1 }
            let marker = fenceMarker(chars, from: index, to: lineEnd)
            if let open = fence {
                for position in index..<lineEnd { mask[position] = true }
                if let marker, marker.marker == open.marker, marker.length >= open.length { fence = nil }
            } else if let marker {
                for position in index..<lineEnd { mask[position] = true }
                fence = marker
            }
            index = lineEnd + 1
        }

        index = 0
        while index < chars.count {
            guard chars[index] == "`", !mask[index] else {
                index += 1
                continue
            }
            let openingEnd = backtickRun(chars, from: index, mask: mask)
            let length = openingEnd - index
            // 找同样长度的一段收尾。找不到就不是代码,那个反引号只是个反引号。
            var probe = openingEnd
            var closing: Int?
            while probe < chars.count {
                guard chars[probe] == "`", !mask[probe] else {
                    probe += 1
                    continue
                }
                let end = backtickRun(chars, from: probe, mask: mask)
                if end - probe == length {
                    closing = probe
                    break
                }
                probe = end
            }
            if let closing {
                for position in index..<(closing + length) { mask[position] = true }
                index = closing + length
            } else {
                index = openingEnd
            }
        }

        return mask
    }

    private static func backtickRun(_ chars: [Character], from start: Int, mask: [Bool]) -> Int {
        var end = start
        while end < chars.count, chars[end] == "`", !mask[end] { end += 1 }
        return end
    }

    private static func fenceMarker(
        _ chars: [Character],
        from start: Int,
        to end: Int
    ) -> (marker: Character, length: Int)? {
        var index = start
        while index < end, chars[index] == " ", index - start < 3 { index += 1 }
        guard index < end, chars[index] == "`" || chars[index] == "~" else { return nil }
        let marker = chars[index]
        var length = 0
        while index < end, chars[index] == marker {
            index += 1
            length += 1
        }
        return length >= 3 ? (marker, length) : nil
    }
}

private extension Array where Element == Character {
    subscript(safe index: Int) -> Character? {
        indices.contains(index) ? self[index] : nil
    }
}
