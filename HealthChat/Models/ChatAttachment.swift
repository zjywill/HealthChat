import Foundation

/// 用户随一句话拍进来的一张照片。
///
/// **气泡显示缩略图,模型收到文本。** 两边同源(`ChatAttachment.modelText`),分开写迟早
/// 对不上——同 `HealthReport` 的 `modelText` / 面板那套。
///
/// 图片本身不在这儿,也不在会话文件里:会话目录已经是这个 app 里最大的一类数据,原图进去会
/// 让 `SessionIndexEntry` 那套增量索引的收益打折。这里只留一个文件名,图片归 `AttachmentStore`。
struct ChatAttachment: Identifiable, Equatable, Codable, Sendable {
    /// 一件附件最多带多少字进上下文。
    ///
    /// 六千是工具输出那一档(`ContextPolicy.maxToolOutputCharacters`),这里收紧到四千:
    /// 用户消息是**几件一起来**的,而工具输出一次只有一份。识别出来的和 Word 里取出来的
    /// 走同一道闸——一份二十页的扫描件和一份二十页的 Word,对上下文的压力是同一种。
    static let maxCharacters = 4000

    let id: UUID
    /// 本机识别出来的文字,**用户改过之后就是他改的那一份**。
    ///
    /// 识别错一个小数点,在健康场景里不是「有点脏数据」。所以这段字在发送之前是可编辑的,
    /// 发出去的就是他看过的那一份。
    var text: String
    /// 识别结果被截掉了多少行(见 `TextRecognizer.maxCharacters`)。截了要说。
    var droppedLines: Int
    /// 图片在 `AttachmentStore` 里的文件名。
    ///
    /// **隐私会话是 nil**:那条会话本来就不落盘,图片跟着不落。屏幕上照常看得见——
    /// 内存里那份还在(`AttachmentImageCache`),只是关掉就没了。
    var imageFileName: String?
    /// 这件是**文件**,不是照片,以及它原来叫什么(「体检报告.docx」)。照片是 nil。
    ///
    /// 分得开是要紧的:照片里的字是本机认出来的,可能错;文件里的字是原样取出来的。
    /// 把后者也说成「识别结果」,模型会去要求用户核对一份根本没经过识别的原文。
    var documentName: String?
    var createdAt: Date?

    init(
        id: UUID = UUID(),
        text: String,
        droppedLines: Int = 0,
        imageFileName: String? = nil,
        documentName: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.text = text
        self.droppedLines = droppedLines
        self.imageFileName = imageFileName
        self.documentName = documentName
        self.createdAt = createdAt
    }

    var isDocument: Bool { documentName != nil }

    static func fileName(for id: UUID) -> String { "\(id.uuidString).jpg" }

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension ChatAttachment {
    /// 模型看到的那一份:用户打的字在前,照片和文件里的文字跟在后面。
    ///
    /// 分隔和编号是给模型用的——一次带三页,不标出来它就会把第二页的参考范围接到第一页的
    /// 数值上。编号是**这句话里的第几件**,照片和文件连着数:混编时各排各的号,「第 2 件」
    /// 就成了两件东西。
    ///
    /// 开头那句说清这段字**不是他打的**,并且分清哪些是认出来的、哪些是原文:识别有误时模型
    /// 该请用户核对,而对着一份原样取出来的 Word 要求核对,只是白问一句。
    static func modelText(typed: String, attachments: [ChatAttachment]) -> String {
        guard !attachments.isEmpty else { return typed }

        var blocks: [String] = []
        let typedText = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedText.isEmpty { blocks.append(typedText) }

        blocks.append(preamble(for: attachments))
        for (index, attachment) in attachments.enumerated() {
            blocks.append(attachment.block(number: index + 1))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func preamble(for attachments: [ChatAttachment]) -> String {
        let photos = attachments.count { !$0.isDocument }
        let documents = attachments.count - photos
        if documents == 0 {
            return "（以下是用户拍的 \(photos) 张照片在本机识别出的文字，不是他打的字。）"
        }
        if photos == 0 {
            return "（以下是用户选的 \(documents) 份文件里的文字，原样取出，不是他打的字。）"
        }
        return "（以下是用户随这句话带来的 \(attachments.count) 件东西里的文字，都不是他打的字："
            + "照片是本机识别的，可能有错；文件是原样取出的。）"
    }

    private func block(number: Int) -> String {
        var header = isDocument ? "【文件 \(number)：\(documentName ?? "")】" : "【照片 \(number)】"
        if droppedLines > 0 {
            // 截掉的那几行要说出来。不说的话模型会把手上这半份当成整份,在用户问「最后那项
            // 呢」的时候一口咬定没有。
            let tail = "太长，后面 \(droppedLines) 行没有取进来】"
            header = isDocument
                ? "【文件 \(number)：\(documentName ?? "")·\(tail)"
                : "【照片 \(number)·\(tail)"
        }
        return "\(header)\n\(body)"
    }

    /// 空的**不是错误**。照实写,模型就会照实说,而不是对着一段空白硬编。
    private var body: String {
        if hasText { return text }
        return isDocument
            ? "（这份文件里没有取到文字。）"
            : "（没有识别到文字。Vana 现在只能读照片里的字，看不了图像本身。）"
    }
}
