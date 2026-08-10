import SwiftUI

/// 拍完还没发出去的一张照片。
///
/// 和 `ChatAttachment` 分成两个类型,是因为它们的生命周期完全不同:这一个只活在输入框上方
/// 那一排里,带着一张内存里的图和一次还在跑的识别;那一个是存进会话文件的结果。合成一个的话,
/// 「正在识别」这种一次性状态就要跟着会话一起落盘。
struct DraftAttachment: Identifiable, Equatable {
    let id: UUID
    /// 已经缩到 `AttachmentImage.maxPixelSize` 的那一份。**文件是 nil**(Word、txt 没有图)。
    ///
    /// 识别跑在**原图**上(要看清小数点),原图只被那个 Task 拿着,识别完就放掉——一次选四张
    /// 十二兆像素的照片,原图全留在手里是几百兆。
    var preview: UIImage?
    /// 这件是文件时它原来叫什么(「体检报告.docx」)。照片是 nil。
    var documentName: String?
    var text = ""
    var droppedLines = 0
    /// 还在识别。这时候发送按钮是等待态:让他把一张还没认完的图发出去,模型收到的就是空的。
    /// 文件那条路是同步取文本的,一进来就是 false。
    var isRecognizing = true
    /// 东西还在路上:相册那张要先读一份原始数据、解一次 JPEG、缩一次图,PDF 要先渲染成图。
    ///
    /// 这一档排在 `isRecognizing` 前面,而且**在他选完的那一刻就摆上去**。选择器一关,输入框
    /// 上方必须当场多出几个格子来——否则这几秒钟屏幕上一个像素都不变,而他刚做完一个动作,
    /// 只会当这一下没点上然后再点一次。见 `AttachmentIntake`。
    var isLoading = false
    /// 读不出来时那一句人话。识别不出**文字**不算失败(那是空结果),这里指的是这份东西打不开。
    var failure: String?
    /// 他点了「让 Vana 看这张图」。见 `ChatAttachment.sendsImage`。
    var sendsImage = false

    /// 这张图值得问一句「要不要直接发给模型」吗。
    ///
    /// 三个条件缺一不可:是照片(文件里的字是原文,没有「图」这回事)、读完认完了、而且
    /// **一个字都没认出来**。最后这条是全部的分寸所在——认出字来的那些是化验单、药盒、
    /// 成分表,它们的信息就是字,本机那份文本已经把要的都给了,再把带着姓名和就诊号的原图
    /// 发出去是净亏。认不出字的才是 OCR 够不着的那类:一顿饭、一处皮疹、一张没有文字的图。
    var suggestsImage: Bool {
        !isDocument && !isLoading && !isRecognizing && failure == nil && !hasText
    }

    /// 占位:他刚选完,东西还在路上。
    ///
    /// 这时候还不知道它到底是什么——一份 PDF 要渲染完才知道有几页,一张 HEIC 要解出来才
    /// 知道读不读得了——所以图和名字两样都先不填,格子里只有一个圈在转。
    init(loading id: UUID) {
        self.id = id
        isLoading = true
    }

    /// 照片。
    init(id: UUID = UUID(), preview: UIImage) {
        self.id = id
        self.preview = preview
    }

    /// 文件。取文本是同步的,建出来就已经是终态。
    init(id: UUID = UUID(), documentName: String, text: String, droppedLines: Int, failure: String?) {
        self.id = id
        self.documentName = documentName
        self.text = text
        self.droppedLines = droppedLines
        self.failure = failure
        isRecognizing = false
    }

    var isDocument: Bool { documentName != nil }

    /// 认出东西来了吗。空结果照样能发——「这张图里没有可识别的文字」是一句有效的回答。
    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
