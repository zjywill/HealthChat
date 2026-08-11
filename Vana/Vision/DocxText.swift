import Foundation

/// 从 .docx 里取正文。
///
/// **不走识别那条路。** docx 里的字就是字,渲染成图再 OCR 一遍,是把好端端的原文降级成
/// 识别结果,还得替它承担认错一个小数点的风险。iOS 又没有现成的读法(`NSAttributedString`
/// 在 iOS 上只认 plain / RTF / RTFD / HTML,`officeOpenXML` 那一档是 macOS 独有的),
/// 所以自己解:docx 是个 zip,正文在 `word/document.xml`。
///
/// **表格用和识别结果同一个列分隔**(`RecognizedTextLayout.columnSeparator`)。同一份化验单
/// 从「拍一张」和「选文件」两条路进来,在模型眼里必须长得一样——不然同一个提示词要照顾两种
/// 排版,而分歧的那次就是它把参考范围读成结果的那次。
enum DocxText {

    static let documentPath = "word/document.xml"

    static func text(of data: Data) throws -> String {
        let xml = try ZIPArchive.entry(named: documentPath, in: data)
        return text(ofDocumentXML: xml)
    }

    /// 纯函数,吃的是 `word/document.xml` 本身。测试直接喂 XML,不用先造一个 zip。
    static func text(ofDocumentXML xml: Data) -> String {
        let reader = Reader()
        let parser = XMLParser(data: xml)
        parser.delegate = reader
        parser.parse()
        return collapseBlankLines(reader.finish())
    }

    /// 连续空行压成一个。Word 文档里空段落是随手敲出来的,一份报告能敲出十几个——每一个
    /// 都是进上下文要付钱的换行。
    private static func collapseBlankLines(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty, lines.last?.isEmpty == true { continue }
            lines.append(trimmed)
        }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// OOXML 里正文的形状很小:段落(`w:p`)装着若干文本片段(`w:t`),表格是
    /// `w:tbl` → `w:tr` → `w:tc`,而单元格里装的还是段落。别的元素(样式、修订、批注)一概
    /// 不认——它们不是用户要问的东西。
    private final class Reader: NSObject, XMLParserDelegate {
        private var lines: [String] = []
        private var row: [String] = []
        private var cell = ""
        private var paragraph = ""
        /// 表格可以嵌套,用计数而不是布尔:嵌套时内层的 `</w:tc>` 会把外层也当成结束了。
        private var cellDepth = 0
        private var isInsideTextRun = false

        func finish() -> String {
            flushParagraph()
            return lines.joined(separator: "\n")
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            switch Self.localName(of: elementName) {
            case "t":
                isInsideTextRun = true
            case "tr":
                row = []
            case "tc":
                cellDepth += 1
                cell = ""
            case "tab":
                // 表格外用 tab 排出来的「列」很常见,但也可能只是段首缩进。补一个空格,
                // 不冒充列分隔——认错一次,模型就会把缩进读成一格数据。
                paragraph += " "
            case "br":
                paragraph += cellDepth > 0 ? " " : "\n"
            default:
                break
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName: String?
        ) {
            switch Self.localName(of: elementName) {
            case "t":
                isInsideTextRun = false
            case "p":
                flushParagraph()
            case "tc":
                flushParagraph()
                row.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
                cellDepth = max(0, cellDepth - 1)
            case "tr":
                lines.append(row.joined(separator: RecognizedTextLayout.columnSeparator))
                row = []
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard isInsideTextRun else { return }
            paragraph += string
        }

        /// 一个段落写完了。在单元格里的接到这一格上(一格里的几段是同一格的内容,不是几行),
        /// 在外面的才自成一行。
        private func flushParagraph() {
            let text = paragraph.trimmingCharacters(in: .whitespaces)
            paragraph = ""
            guard cellDepth > 0 else {
                lines.append(text)
                return
            }
            guard !text.isEmpty else { return }
            cell += cell.isEmpty ? text : " \(text)"
        }

        /// `w:t` 里的 `w` 只是约定俗成的前缀。按后缀认,换个前缀的文档照样读得出来。
        private static func localName(of elementName: String) -> Substring {
            guard let colon = elementName.lastIndex(of: ":") else { return elementName[...] }
            return elementName[elementName.index(after: colon)...]
        }
    }
}
