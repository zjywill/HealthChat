import Foundation
import Testing

@testable import Vana

/// 从「文件」进来的那条路:Word、纯文本,以及它们和照片在模型眼里的区别。
///
/// docx 不走识别——里面的字**就是字**,渲染成图再认一遍是把原文降级成识别结果。所以这里盯的
/// 是另一套东西:zip 解得对不对、表格还原成不成、编码猜不猜得中,以及最要紧的那条——
/// **文件里的文字不能被说成「识别出来的」**,不然模型会去要求用户核对一份根本没经过识别的原文。
@Suite("Document import")
struct DocumentImportTests {

    // MARK: - zip

    @Test("从 zip 里按名字取出一条（不压缩）")
    func readsStoredEntry() throws {
        let archive = ZIPFixture.archive(entries: [("word/document.xml", Data("你好".utf8), false)])
        let entry = try ZIPArchive.entry(named: "word/document.xml", in: archive)
        #expect(String(decoding: entry, as: UTF8.self) == "你好")
    }

    @Test("压缩过的那条也读得出来")
    func readsDeflatedEntry() throws {
        // Word 存正文用的就是 deflate,这条路才是线上真正会走的那条。
        let body = Data(String(repeating: "血红蛋白 132 g/L\n", count: 50).utf8)
        let archive = ZIPFixture.archive(entries: [("word/document.xml", body, true)])
        let entry = try ZIPArchive.entry(named: "word/document.xml", in: archive)
        #expect(entry == body)
    }

    @Test("多条时挑对那一条")
    func picksTheRightEntry() throws {
        let archive = ZIPFixture.archive(entries: [
            ("[Content_Types].xml", Data("类型".utf8), true),
            ("word/document.xml", Data("正文".utf8), true),
            ("word/styles.xml", Data("样式".utf8), false),
        ])
        let entry = try ZIPArchive.entry(named: "word/document.xml", in: archive)
        #expect(String(decoding: entry, as: UTF8.self) == "正文")
    }

    @Test("不是 zip 就照实报错，不猜")
    func rejectsNonArchives() {
        // 猜错的结果是把一段二进制当成正文发给模型。
        #expect(throws: ZIPArchive.Failure.self) {
            try ZIPArchive.entry(named: "word/document.xml", in: Data(repeating: 0x41, count: 512))
        }
    }

    // MARK: - docx 正文

    @Test("段落一段一行")
    func readsParagraphs() {
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:p><w:r><w:t>体检报告</w:t></w:r></w:p>
        <w:p><w:r><w:t>姓名：张三</w:t></w:r></w:p>
        """))
        #expect(text == "体检报告\n姓名：张三")
    }

    @Test("一个段落被拆成几段文本时接回去")
    func joinsRunsWithinAParagraph() {
        // Word 会因为一处加粗、一次拼写检查就把一句话切成好几个 run。
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:p><w:r><w:t>空腹血糖</w:t></w:r><w:r><w:t> 6.4</w:t></w:r><w:r><w:t> mmol/L</w:t></w:r></w:p>
        """))
        #expect(text == "空腹血糖 6.4 mmol/L")
    }

    @Test("表格一行一行，列之间和识别结果用同一个分隔")
    func readsTablesWithTheSameColumnSeparator() {
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:tbl>
          <w:tr>\(cell("项目"))\(cell("结果"))\(cell("参考范围"))</w:tr>
          <w:tr>\(cell("血红蛋白"))\(cell("132"))\(cell("130-175"))</w:tr>
        </w:tbl>
        """))
        // 同一份化验单从「拍一张」和「选文件」两条路进来,在模型眼里必须长得一样。
        #expect(text == "项目 | 结果 | 参考范围\n血红蛋白 | 132 | 130-175")
        #expect(text.contains(RecognizedTextLayout.columnSeparator))
    }

    @Test("一格里的几段接成一格，不是几行")
    func multipleParagraphsInACellStayInOneCell() {
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:tbl><w:tr>
          <w:tc><w:p><w:r><w:t>尿酸</w:t></w:r></w:p><w:p><w:r><w:t>（复查）</w:t></w:r></w:p></w:tc>
          \(cell("456"))
        </w:tr></w:tbl>
        """))
        #expect(text == "尿酸 （复查） | 456")
    }

    @Test("连着的空段落压成一个空行")
    func collapsesBlankParagraphs() {
        // Word 文档里空段落是随手敲出来的,一份报告能敲出十几个,每一个都要付钱。
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:p><w:r><w:t>上半段</w:t></w:r></w:p>
        <w:p/><w:p/><w:p/>
        <w:p><w:r><w:t>下半段</w:t></w:r></w:p>
        """))
        #expect(text == "上半段\n\n下半段")
    }

    @Test("样式、批注这些不是正文的元素一个字都不带进来")
    func ignoresNonBodyElements() {
        let text = DocxText.text(ofDocumentXML: ZIPFixture.documentXML("""
        <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>结论</w:t></w:r></w:p>
        <w:p><w:r><w:instrText>PAGE \\\\* MERGEFORMAT</w:instrText></w:r></w:p>
        """))
        #expect(text == "结论")
    }

    @Test("换个命名空间前缀照样读得出来")
    func toleratesADifferentNamespacePrefix() {
        let xml = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <x:document xmlns:x="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <x:body><x:p><x:r><x:t>血小板 185</x:t></x:r></x:p></x:body></x:document>
        """.utf8)
        #expect(DocxText.text(ofDocumentXML: xml) == "血小板 185")
    }

    @Test("整份 docx 从 zip 一路读到正文")
    func readsAWholeDocx() throws {
        let archive = ZIPFixture.docx(body: """
        <w:p><w:r><w:t>检验报告单</w:t></w:r></w:p>
        <w:tbl><w:tr>\(cell("总胆固醇"))\(cell("5.8"))</w:tr></w:tbl>
        """)
        #expect(try DocxText.text(of: archive) == "检验报告单\n总胆固醇 | 5.8")
    }

    // MARK: - 纯文本

    @Test("UTF-8 的 txt 原样读进来")
    func readsUTF8Text() throws {
        let url = try ZIPFixture.temporaryFile(named: "记录.txt", contents: Data("今天走了 8000 步".utf8))
        #expect(try PlainTextFile.text(at: url) == "今天走了 8000 步")
    }

    @Test("中文 Windows 导出的 GB18030 也认")
    func readsGB18030Text() throws {
        // 「血压」在 GBK 里是 D1 AA D1 B9,而这**正好是**一段合法的 UTF-8(两个西里尔字母)。
        // 「先试 UTF-8,不行再试 GB」在这儿一个错都不会报,直接把乱码发给模型;系统那个编码
        // 探测器在这么短的文本上也照样挑 UTF-8。这条用例盯的就是那一下。
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        let data = try #require("血压 130/85".data(using: encoding))
        let url = try ZIPFixture.temporaryFile(named: "血压.txt", contents: data)
        #expect(try PlainTextFile.text(at: url) == "血压 130/85")
    }

    @Test("真 UTF-8 里的 ℃ 和 ± 不会被当成乱码")
    func keepsGenuineUTF8WithSymbols() throws {
        // 判乱码要求「连着两个」,就是为了让这些孤立的符号不触发误判——化验单上到处都是它们。
        let url = try ZIPFixture.temporaryFile(
            named: "体温.txt",
            contents: Data("体温 36.5°C ±0.2，µg/L".utf8)
        )
        #expect(try PlainTextFile.text(at: url) == "体温 36.5°C ±0.2，µg/L")
    }

    // MARK: - 进来之后是什么

    @Test("docx 进来是一件文件，带着它原来的名字")
    func importsDocxAsADocument() throws {
        let url = try ZIPFixture.temporaryFile(
            named: "体检报告.docx",
            contents: ZIPFixture.docx(body: "<w:p><w:r><w:t>尿酸 456</w:t></w:r></w:p>")
        )
        let imported = AttachmentImporter.load(at: url)
        guard case .document(let name, let text, let dropped, let failure) = imported.first else {
            Issue.record("docx 应该走取文本那条路，不该被当成图去识别")
            return
        }
        #expect(name == "体检报告.docx")
        #expect(text == "尿酸 456")
        #expect(dropped == 0)
        #expect(failure == nil)
    }

    @Test("读不了的格式带一句人话回来，不是静静地少一件")
    func unreadableFileComesBackWithAReason() throws {
        let url = try ZIPFixture.temporaryFile(
            named: "报告.docx",
            contents: Data(repeating: 0x00, count: 300)
        )
        guard case .document(_, let text, _, let failure) = AttachmentImporter.load(at: url).first else {
            Issue.record("应该回一件带失败原因的文件")
            return
        }
        #expect(text.isEmpty)
        #expect(failure != nil)
    }

    @Test("超长的文件和超长的识别结果走同一道闸")
    func longDocumentsAreTruncatedLikeRecognizedText() throws {
        let long = (1...500).map { "第\($0)项 | 数值\($0)" }.joined(separator: "\n")
        let url = try ZIPFixture.temporaryFile(named: "长报告.txt", contents: Data(long.utf8))
        guard case .document(_, let text, let dropped, _) = AttachmentImporter.load(at: url).first else {
            Issue.record("txt 应该走取文本那条路")
            return
        }
        #expect(text.count <= ChatAttachment.maxCharacters)
        #expect(dropped > 0)
    }

    // MARK: - 模型看到的那一份

    @Test("文件那几段标的是文件名，而且不说成「识别出来的」")
    func documentBlocksAreNotCalledRecognized() {
        let text = ChatAttachment.modelText(
            typed: "这份报告怎么看",
            attachments: [ChatAttachment(text: "尿酸 | 456", documentName: "体检报告.docx")]
        )
        #expect(text.contains("【文件 1：体检报告.docx】"))
        // 原样取出来的文本再请用户核对错字,是白问一句。
        #expect(text.contains("原样取出"))
        #expect(!text.contains("识别出的文字"))
    }

    @Test("照片和文件混着来时，开头那句把两者分清楚")
    func mixedAttachmentsExplainBothKinds() {
        let text = ChatAttachment.modelText(
            typed: "",
            attachments: [
                ChatAttachment(text: "血红蛋白 | 132"),
                ChatAttachment(text: "尿酸 | 456", documentName: "体检报告.docx"),
            ]
        )
        #expect(text.contains("照片是本机识别的，可能有错"))
        #expect(text.contains("文件是原样取出的"))
        // 编号是「这句话里的第几件」,两类连着数:各排各的号,「第 2 件」就成了两件东西。
        #expect(text.contains("【照片 1】"))
        #expect(text.contains("【文件 2：体检报告.docx】"))
    }

    @Test("文件被截了也要在发出去的文本里说清楚")
    func truncatedDocumentSaysSo() {
        let text = ChatAttachment.modelText(
            typed: "",
            attachments: [ChatAttachment(text: "开头几项", droppedLines: 40, documentName: "报告.docx")]
        )
        #expect(text.contains("40 行"))
        #expect(text.contains("报告.docx"))
    }

    private func cell(_ text: String) -> String {
        "<w:tc><w:p><w:r><w:t>\(text)</w:t></w:r></w:p></w:tc>"
    }
}

/// 造 zip 比读 zip 简单得多,所以测试自己造——不用往仓库里塞一个二进制的 .docx,
/// 用例里也就看得见「这份文档长什么样」。
enum ZIPFixture {

    static func documentXML(_ body: String) -> Data {
        Data("""
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>\(body)</w:body></w:document>
        """.utf8)
    }

    static func docx(body: String) -> Data {
        archive(entries: [
            ("[Content_Types].xml", Data("<Types/>".utf8), true),
            (DocxText.documentPath, documentXML(body), true),
        ])
    }

    /// 一个最小可用的 zip。`deflate` 为假时按 stored 存。
    static func archive(entries: [(name: String, data: Data, deflate: Bool)]) -> Data {
        var file = Data()
        var directory = Data()

        for entry in entries {
            let name = Data(entry.name.utf8)
            let deflated = entry.deflate
                ? (try? (entry.data as NSData).compressed(using: .zlib)) as Data?
                : nil
            let payload = deflated ?? entry.data
            let method: UInt16 = deflated == nil ? 0 : 8
            let offset = UInt32(file.count)

            file.append(u32(0x0403_4b50))
            file.append(u16(20))                        // version needed
            file.append(u16(0))                         // flags
            file.append(u16(method))
            file.append(u16(0))                         // time
            file.append(u16(0))                         // date
            file.append(u32(0))                         // crc32:这个读法不校验
            file.append(u32(UInt32(payload.count)))
            file.append(u32(UInt32(entry.data.count)))
            file.append(u16(UInt16(name.count)))
            file.append(u16(0))                         // extra
            file.append(name)
            file.append(payload)

            directory.append(u32(0x0201_4b50))
            directory.append(u16(20))                   // version made by
            directory.append(u16(20))                   // version needed
            directory.append(u16(0))                    // flags
            directory.append(u16(method))
            directory.append(u16(0))
            directory.append(u16(0))
            directory.append(u32(0))
            directory.append(u32(UInt32(payload.count)))
            directory.append(u32(UInt32(entry.data.count)))
            directory.append(u16(UInt16(name.count)))
            directory.append(u16(0))                    // extra
            directory.append(u16(0))                    // comment
            directory.append(u16(0))                    // disk
            directory.append(u16(0))                    // internal attrs
            directory.append(u32(0))                    // external attrs
            directory.append(u32(offset))
            directory.append(name)
        }

        let directoryOffset = UInt32(file.count)
        file.append(directory)
        file.append(u32(0x0605_4b50))
        file.append(u16(0))                             // disk
        file.append(u16(0))                             // directory start disk
        file.append(u16(UInt16(entries.count)))
        file.append(u16(UInt16(entries.count)))
        file.append(u32(UInt32(directory.count)))
        file.append(u32(directoryOffset))
        file.append(u16(0))                             // comment
        return file
    }

    static func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: name, directoryHint: .notDirectory)
        try contents.write(to: url)
        return url
    }

    private static func u16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF)])
    }

    private static func u32(_ value: UInt32) -> Data {
        Data([
            UInt8(value & 0xFF),
            UInt8(value >> 8 & 0xFF),
            UInt8(value >> 16 & 0xFF),
            UInt8(value >> 24 & 0xFF),
        ])
    }
}
