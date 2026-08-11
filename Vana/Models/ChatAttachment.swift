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
    /// 用户同意把这张图**本身**也发给模型。
    ///
    /// 默认关,而且只在两件事同时成立时才问得出口:本机一个字都没认出来,以及当前这个模型
    /// 看得了图。**带字的照片永远不问**——一张化验单上有姓名、就诊号、医院和条码,而这次
    /// 对话要的只是那几行数值,本机认出来的那份文本已经把它们都给了。所以这不是「有视觉就
    /// 直传」的开关,是「OCR 够不着的那类照片」的补丁:一顿饭、一处皮疹、一张没有文字的图。
    ///
    /// 存下来是必须的:图每一轮都要跟着历史重发一遍,这个标记丢了,重开 app 之后模型就看不见
    /// 它前几句已经描述过的那张图了。
    var sendsImage: Bool
    var createdAt: Date?

    /// 要发出去的那张图,base64。
    ///
    /// **故意不进会话文件**:一张 JPEG 编成 base64 是几十上百 KB,而 `SessionIndexEntry`
    /// 那套增量索引的全部收益来自「只解用得上的键」——原图进 JSON,列表每刷一次都要把它从
    /// 磁盘读进来再跳过去。盘上那份归 `AttachmentStore`(它本来就存着),这里只在内存里
    /// 拿着;重开 app 之后由 `ChatViewModel.loadImagePayloads` 从盘上补回来。
    ///
    /// 隐私会话里它是唯一的那份:那条会话不落盘,图只活在内存里,关掉就没了。
    var imagePayload: String?

    init(
        id: UUID = UUID(),
        text: String,
        droppedLines: Int = 0,
        imageFileName: String? = nil,
        documentName: String? = nil,
        sendsImage: Bool = false,
        imagePayload: String? = nil,
        createdAt: Date? = Date()
    ) {
        self.id = id
        self.text = text
        self.droppedLines = droppedLines
        self.imageFileName = imageFileName
        self.documentName = documentName
        self.sendsImage = sendsImage
        self.imagePayload = imagePayload
        self.createdAt = createdAt
    }

    /// `imagePayload` 不在里面:那是内存里的东西,不该被写进会话文件。
    private enum CodingKeys: String, CodingKey {
        case id, text, droppedLines, imageFileName, documentName, sendsImage, createdAt
    }

    /// 手写 decoder 只为了一件事:`sendsImage` 是后加的字段,合成的那个 decoder 碰到一份
    /// 老会话会直接抛 `keyNotFound`,而那意味着这条会话再也打不开了。
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        droppedLines = try container.decodeIfPresent(Int.self, forKey: .droppedLines) ?? 0
        imageFileName = try container.decodeIfPresent(String.self, forKey: .imageFileName)
        documentName = try container.decodeIfPresent(String.self, forKey: .documentName)
        sendsImage = try container.decodeIfPresent(Bool.self, forKey: .sendsImage) ?? false
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    /// `imagePayload` 不参与比较。它是几十上百 KB 的 base64,而这个 `==` 跑在每一次界面
    /// 判等上(`ChatMessage.rendersIdentically`);同一条附件的图不会中途换人,`id` 和
    /// `sendsImage` 已经说完了屏幕上要知道的一切。
    static func == (lhs: ChatAttachment, rhs: ChatAttachment) -> Bool {
        lhs.id == rhs.id
            && lhs.text == rhs.text
            && lhs.droppedLines == rhs.droppedLines
            && lhs.imageFileName == rhs.imageFileName
            && lhs.documentName == rhs.documentName
            && lhs.sendsImage == rhs.sendsImage
            && lhs.createdAt == rhs.createdAt
    }

    var isDocument: Bool { documentName != nil }

    /// 这张图真的能发出去吗。开了开关但内容还没从盘上读回来时是 false——那时候正文里
    /// 也不能写「原图在下面」,不然模型会去找一张不存在的图。
    var carriesImage: Bool { sendsImage && imagePayload != nil }

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
        // 随附的图各自也有编号,而且和「第几件」不是一回事:六件里只有第 4 件带了图,那它
        // 就是随附的第 1 张。不对上的话,模型会去看它上面那张图然后解释错东西。
        var imageNumber = 0
        for (index, attachment) in attachments.enumerated() {
            var attached: Int?
            if attachment.carriesImage {
                imageNumber += 1
                attached = imageNumber
            }
            blocks.append(attachment.block(number: index + 1, attachedImage: attached))
        }
        return blocks.joined(separator: "\n\n")
    }

    private static func preamble(for attachments: [ChatAttachment]) -> String {
        let photos = attachments.count { !$0.isDocument }
        let documents = attachments.count - photos
        let images = attachments.count(where: \.carriesImage)
        // 有图随行时补一句。少了它,模型读到「没有识别到文字」就会照着老规矩说一句
        // 「我看不了图像本身」——而这一次图明明就在它手上。
        let attached = images > 0
            ? "其中 \(images) 张本机一个字都没认出来，原图直接附在这条消息里了，请看图。"
            : ""
        if documents == 0 {
            return "（以下是用户拍的 \(photos) 张照片在本机识别出的文字，不是他打的字。\(attached)）"
        }
        if photos == 0 {
            return "（以下是用户选的 \(documents) 份文件里的文字，原样取出，不是他打的字。）"
        }
        return "（以下是用户随这句话带来的 \(attachments.count) 件东西里的文字，都不是他打的字："
            + "照片是本机识别的，可能有错；文件是原样取出的。\(attached)）"
    }

    private func block(number: Int, attachedImage: Int? = nil) -> String {
        var header = isDocument ? "【文件 \(number)：\(documentName ?? "")】" : "【照片 \(number)】"
        if droppedLines > 0 {
            // 截掉的那几行要说出来。不说的话模型会把手上这半份当成整份,在用户问「最后那项
            // 呢」的时候一口咬定没有。
            let tail = "太长，后面 \(droppedLines) 行没有取进来】"
            header = isDocument
                ? "【文件 \(number)：\(documentName ?? "")·\(tail)"
                : "【照片 \(number)·\(tail)"
        }
        return "\(header)\n\(body(attachedImage: attachedImage))"
    }

    /// 空的**不是错误**。照实写,模型就会照实说,而不是对着一段空白硬编。
    ///
    /// 图随行的那一份要**换一句话说**:老那句「看不了图像本身」在这一次是假的,而模型会
    /// 照着它说自己看不见——那正是这颗开关要消掉的那句回答。
    private func body(attachedImage: Int?) -> String {
        var lines: [String] = []
        if hasText {
            lines.append(text)
        } else if isDocument {
            lines.append("（这份文件里没有取到文字。）")
        } else if attachedImage == nil {
            lines.append("（没有识别到文字。Vana 现在只能读照片里的字，看不了图像本身。）")
        } else {
            lines.append("（本机没有识别到文字。）")
        }
        if let attachedImage {
            lines.append("（用户同意把原图发给你：它是这条消息随附的第 \(attachedImage) 张图，直接看图回答。）")
        }
        return lines.joined(separator: "\n")
    }
}
