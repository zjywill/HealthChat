import PDFKit
import UIKit
import UniformTypeIdentifiers

/// 从「文件」里选进来的东西。
///
/// **两条路,按「里面的信息是不是字」分,不是按格式分**:
///
/// - 化验单不总是一张纸——医院公众号导出来的多半是一份 PDF,而它和拍出来的照片一样,
///   信息是**印在版面上的**,所以渲染成图走本机识别。PDF 里那层文字图层这里不取:多数体检
///   报告是扫描件,取到的是空的;统一走识别,行为才可预期。
/// - Word 和 txt 里的字**就是字**。渲染成图再认一遍,是把好端端的原文降级成识别结果,还得
///   替它承担认错一个小数点的风险。所以直接取文本(`DocxText` / `PlainTextFile`)。
enum ImportedAttachment {
    case photo(UIImage)
    /// 文件里的原文。`failure` 非空时 `text` 是空的。
    case document(name: String, text: String, droppedLines: Int, failure: String?)
}

enum AttachmentImporter {
    /// 一份 PDF 最多取前几页。
    ///
    /// 体检报告动辄二十页,而后面那些是说明和广告。用户要问的几乎总在前面几页;真要看后面的,
    /// 他可以自己截出来再拍——比让 app 悄悄把二十页识别进上下文诚实。
    static let maxPages = 6

    /// Word。只收 docx,不收 doc:老的 .doc 是另一种二进制格式(OLE 复合文档),
    /// 和 docx 除了名字没有关系,收下来只会读出一堆乱码。
    static let wordType = UTType("org.openxmlformats.wordprocessingml.document")

    /// `.plainText` 一条就覆盖了 txt / md / csv / tsv ——它们都 conform 到它。
    static var contentTypes: [UTType] {
        [.pdf, .image, .plainText, .rtf] + [wordType].compactMap { $0 }
    }

    static func load(at url: URL) -> [ImportedAttachment] {
        // 从「文件」拿到的 URL 在沙箱外,不开这一下读出来的是空的。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType

        if type?.conforms(to: .pdf) == true || url.pathExtension.lowercased() == "pdf" {
            return pages(of: url).map(ImportedAttachment.photo)
        }
        if let wordType, type?.conforms(to: wordType) == true
            || url.pathExtension.lowercased() == "docx" {
            return [document(name: name) { try DocxText.text(of: Data(contentsOf: url)) }]
        }
        if type?.conforms(to: .rtf) == true || url.pathExtension.lowercased() == "rtf" {
            return [document(name: name) { try PlainTextFile.richText(at: url) }]
        }
        if type?.conforms(to: .plainText) == true {
            return [document(name: name) { try PlainTextFile.text(at: url) }]
        }
        // 剩下的当图看:从「文件」里选一张 HEIC 或者扫描出来的 PNG 是常事。
        guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
            return [.document(
                name: name,
                text: "",
                droppedLines: 0,
                failure: "这个格式读不了，试试 PDF、Word、纯文本或者照片。"
            )]
        }
        return [.photo(image)]
    }

    /// 取文本那几条长得一样:成了就截到上限,砸了就把人话带回去。
    ///
    /// 截断走的是识别结果那同一道闸(`RecognizedTextLayout.truncated`)——一份二十页的
    /// Word 和一份二十页的扫描件,对上下文的压力是同一种,没有理由只拦其中一种。
    private static func document(
        name: String,
        reading: () throws -> String
    ) -> ImportedAttachment {
        do {
            let raw = try reading()
            let cut = RecognizedTextLayout.truncated(raw, maxCharacters: ChatAttachment.maxCharacters)
            return .document(name: name, text: cut.text, droppedLines: cut.droppedLines, failure: nil)
        } catch {
            return .document(name: name, text: "", droppedLines: 0, failure: error.localizedDescription)
        }
    }

    private static func pages(of url: URL) -> [UIImage] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<min(document.pageCount, maxPages)).compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            let bounds = page.bounds(for: .mediaBox)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            // 按两倍渲染:一页 A4 的化验单按原尺寸出图,每行字只有十来个像素高,识别率会塌。
            let scale = 2.0
            let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            return UIGraphicsImageRenderer(size: size, format: format).image { context in
                UIColor.white.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                context.cgContext.translateBy(x: 0, y: size.height)
                context.cgContext.scaleBy(x: scale, y: -scale)
                page.draw(with: .mediaBox, to: context.cgContext)
            }
        }
    }
}

/// txt 和 rtf。
enum PlainTextFile {
    enum Failure: LocalizedError {
        case unreadableEncoding

        var errorDescription: String? {
            switch self {
            case .unreadableEncoding: "这个文本文件的编码认不出来，另存成 UTF-8 再试。"
            }
        }
    }

    /// 中文 Windows 上导出来的 txt 十有八九不是 UTF-8,而按 UTF-8 硬读出来的是一屏乱码
    /// ——那会原样发给模型。
    ///
    /// **「先试 UTF-8,不行再试 GB」是错的**,这条路踩过:GBK 的两字节汉字常常**正好是**一段
    /// 合法的 UTF-8。「血压」在 GBK 里是 D1 AA D1 B9,按 UTF-8 解出来是两个西里尔字母,
    /// 一个错都不报。系统那个编码探测器在这种短文本上也照样挑 UTF-8(试过)。
    ///
    /// 所以要看**解出来的像不像人话**:这个 app 里的文本是中文、英文和数字,
    /// 连着两个「非 ASCII 又不是汉字」的字母只可能是刚才那种误读。代价是一份真正的俄文或
    /// 希腊文 txt 会被判成 GBK ——那在一个中文健康 app 里换得过。
    static func text(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)

        if let declared = bomEncoding(of: data), let text = String(data: data, encoding: declared) {
            return text
        }

        let utf8 = String(data: data, encoding: .utf8)
        if let utf8, !looksMisread(utf8) { return utf8 }
        if let chinese = String(data: data, encoding: gb18030), containsChinese(chinese) {
            return chinese
        }
        if let utf8 { return utf8 }
        // 到这儿说明既不是 UTF-8 也不是 GB。交给系统去猜(Shift-JIS、Windows-1252 之类),
        // 这时候它没有对手,猜出什么都比读不出来强。
        if let detected = detect(data) { return detected }

        throw Failure.unreadableEncoding
    }

    /// 连着两个落在 U+0080…U+07FF 的字符——GBK 被当成 UTF-8 读出来的签名。
    ///
    /// 要求「连着」而不是「有」:真正的中文报告里 `°C`、`±`、`µg` 都在这个区间,但它们是
    /// 孤立的;而误读出来的字母是一个汉字一个,连成一片。
    private static func looksMisread(_ text: String) -> Bool {
        var run = 0
        for scalar in text.unicodeScalars {
            guard (0x80...0x7FF).contains(scalar.value) else {
                run = 0
                continue
            }
            run += 1
            if run >= 2 { return true }
        }
        return false
    }

    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }

    private static func detect(_ data: Data) -> String? {
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data,
            // 界面全是中文,拍的也是中文化验单。不给这条提示,两种都说得通的时候它会挑错。
            encodingOptions: [.likelyLanguageKey: "zh", .allowLossyKey: false],
            convertedString: &converted,
            usedLossyConversion: nil
        )
        guard encoding != 0, let converted else { return nil }
        return converted as String
    }

    private static func bomEncoding(of data: Data) -> String.Encoding? {
        let head = [UInt8](data.prefix(3))
        if head.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8 }
        if head.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if head.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        return nil
    }

    /// Foundation 没给它一个常量,只能从 CoreFoundation 那张表里换算。
    static var gb18030: String.Encoding {
        String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
    }

    static func richText(at url: URL) throws -> String {
        let attributed = try NSAttributedString(
            url: url,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )
        return attributed.string
    }
}
