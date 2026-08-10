import CoreGraphics
import Foundation

/// 识别出来的一段文字和它在图上的位置。
///
/// 坐标**归一化、原点在左上、y 向下**——也就是阅读顺序那一侧。Vision 给的是左下原点,
/// 翻面在 `TextRecognizer` 里做一次,这支纯函数就不用认识 Vision 的任何类型,测试也才喂得进
/// 固定的数组(`RecognizedTextObservation` 造不出来)。
struct RecognizedFragment: Equatable, Sendable {
    var text: String
    var frame: CGRect

    init(text: String, frame: CGRect) {
        self.text = text
        self.frame = frame
    }

    /// 测试和调用方都按「左上角 + 宽高」想事情,写全 `CGRect` 太吵。
    init(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.init(text: text, frame: CGRect(x: x, y: y, width: width, height: height))
    }
}

/// 把散落的识别结果重新排回人看得懂的样子。
///
/// **这是这个功能的主要工作量,不是接 API 那一步。** 化验单是表格:项目 / 结果 / 单位 /
/// 参考范围 / 箭头。按识别顺序把 `topCandidates(1).string` 平铺成一段文字,
/// 「血红蛋白 132 g/L 130-175 ↓」会被拆散重排,数值和项目对不上——而对不上的那次,模型会
/// 一本正经地解释一个错的数。所以按 y 聚成行、按 x 排成列。
enum RecognizedTextLayout {

    /// 同一行的判据:两段文字在竖直方向上压过对方一半以上。
    ///
    /// 按「中心点差多少」判会在一行里混着大小字号时翻车(表格里的箭头比项目名矮一半),
    /// 按重叠比例判则只要它们确实并排就成立。
    static let sameRowOverlapRatio: CGFloat = 0.5

    /// 隔多远算换了一列:横向空白超过这一行字高的这么多倍。
    ///
    /// 以字高为单位而不是画面宽度的固定比例——同一份化验单拍近拍远,列间距在画面里差着一倍,
    /// 而它相对字高几乎不变。
    static let columnGapRatio: CGFloat = 0.75

    /// 挨得多近才算「识别把一句话切成了两段」:横向空白不到这一行字高的这么多倍。
    ///
    /// 只在这个范围里的中文之间不补空格。再宽一点就补——那多半是版面上真的空出来的一格
    /// (「性别：男    年龄：34」),连起来写成「男年龄」比多一个空格难读得多。
    static let joinGapRatio: CGFloat = 0.25

    /// 列与列之间的分隔。
    ///
    /// 用竖线不用空格:模型要靠它把「130-175」认成参考范围而不是上一格的一部分,而空格在
    /// 中文行里本来就到处都是,分不出「这里是一列」还是「这里断了个词」。
    static let columnSeparator = " | "

    /// 按几何把碎片重排成文本。行内用列分隔,行间换行。
    static func reconstruct(_ fragments: [RecognizedFragment]) -> String {
        rows(from: fragments).map(line(of:)).joined(separator: "\n")
    }

    /// 聚成行。返回的每一行按 x 从左到右排好。
    static func rows(from fragments: [RecognizedFragment]) -> [[RecognizedFragment]] {
        let usable = fragments
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                if lhs.frame.midY != rhs.frame.midY { return lhs.frame.midY < rhs.frame.midY }
                return lhs.frame.minX < rhs.frame.minX
            }

        var rows: [[RecognizedFragment]] = []
        // 锚点是这一行**第一个**碎片,不是这一行到目前为止的并集。并集会一路长高,
        // 在页面有一点倾斜时把下一行也吸进来,整张表就塌成一行。
        var anchor: CGRect?

        for fragment in usable {
            if let anchor, overlapsVertically(anchor, fragment.frame) {
                rows[rows.count - 1].append(fragment)
            } else {
                rows.append([fragment])
                anchor = fragment.frame
            }
        }

        return rows.map { $0.sorted { $0.frame.minX < $1.frame.minX } }
    }

    private static func overlapsVertically(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let overlap = min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY)
        guard overlap > 0 else { return false }
        return overlap >= sameRowOverlapRatio * min(lhs.height, rhs.height)
    }

    private static func line(of row: [RecognizedFragment]) -> String {
        var line = ""
        var previous: RecognizedFragment?

        for fragment in row {
            let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            defer { previous = fragment }
            guard let previous else {
                line = text
                continue
            }
            line += separator(after: previous, before: fragment) + text
        }
        return line
    }

    private static func separator(
        after previous: RecognizedFragment,
        before next: RecognizedFragment
    ) -> String {
        let gap = next.frame.minX - previous.frame.maxX
        let unit = min(previous.frame.height, next.frame.height)
        if unit > 0, gap > columnGapRatio * unit { return columnSeparator }
        // 贴着的中文之间不补空格:那是识别把一句话切成了两段,补一个空格等于在句子中间
        // 插了个词边界。隔开一点的就照补——那是版面上真的空出来的一格。
        if gap < joinGapRatio * unit,
           isIdeograph(previous.text.last),
           isIdeograph(next.text.first) {
            return ""
        }
        return " "
    }

    private static func isIdeograph(_ character: Character?) -> Bool {
        guard let scalar = character?.unicodeScalars.first else { return false }
        return (0x3040...0x9FFF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
    }

    // MARK: - 截断

    /// 一份多页化验单能识别出好几千字,而 `ContextPolicy` 那四档降级**只管工具输出,不管用户
    /// 消息**——没有任何一档会在它进上下文之前拦住它。
    ///
    /// 所以在这儿就截,**按行边界**(同 `ContextPolicy.maxToolOutputCharacters`):半行数据
    /// 比没有这行更糟。截了多少要说出来,而且是在用户按发送之前说——他自己就能删掉不相关的
    /// 那几页,或者把要问的那一项挪上来。
    static func truncated(
        _ text: String,
        maxCharacters: Int
    ) -> (text: String, droppedLines: Int) {
        guard text.count > maxCharacters else { return (text, 0) }

        var kept: [Substring] = []
        var length = 0
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines {
            // +1 是那个换行符。
            let next = length + line.count + (kept.isEmpty ? 0 : 1)
            guard next <= maxCharacters else { break }
            kept.append(line)
            length = next
        }
        // 第一行本身就超长(整张图识别成一行):那也得留下点东西,按字符硬截。
        if kept.isEmpty {
            return (String(text.prefix(maxCharacters)), max(lines.count - 1, 0))
        }
        return (kept.joined(separator: "\n"), lines.count - kept.count)
    }
}
