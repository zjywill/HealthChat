import Foundation
import UIKit
import Vision

/// 一张图识别出来的东西。
struct RecognizedText: Equatable, Sendable {
    /// 已经按几何重排、并且按行截断过的文本。
    var text: String
    /// 截掉了多少行。0 就是一行没截。
    var droppedLines: Int

    /// 这张图里没有能认出来的字。
    ///
    /// **不是错误**:一顿饭、一处皮疹本来就没有字。照实说「这张图里没有可识别的文字」,
    /// 比让模型对着一段空 OCR 硬编强(同「没有数据不是错误」那条)。
    var isEmpty: Bool { text.isEmpty }

    static let empty = RecognizedText(text: "", droppedLines: 0)
}

/// 本机文字识别。**图不出本机,发出去的只有文本。**
///
/// 这是默认路径,不是「因为 DeepSeek 没视觉」的权宜之计:一张化验单照片里有姓名、就诊号、
/// 医院、科室、医生签名、条码,而这次对话真正需要的只是那几行数值。把整张图发给云端模型,
/// 是把一份完整的就诊身份连同数据一起交出去。所以即使将来换了一个有视觉能力的模型,
/// **带字的照片也应该继续走这里**。
enum TextRecognizer {

    /// 认哪几种语言。
    ///
    /// 中文必须显式写上——不写的话默认只认英文,一张中文化验单会识别成一片空白。
    /// 简繁分开列:`zh-Hans` 一项认不出繁体。英文跟在后面,化验单上的单位(g/L、mmol/L)
    /// 和药瓶上的成分名本来就是英文。
    static let languages = ["zh-Hans", "zh-Hant", "en-US"]

    /// 一行字至少要占到画面高度的这么多才会被认出来。
    ///
    /// 默认是 1/32,而一份四十行的化验单每行只有 0.02——按默认值那张表会整个被跳过。
    /// 调低的代价是慢一点,而这是一次用户主动发起、他知道自己在等的操作。
    static let minimumTextHeightFraction: Float = 0.008

    enum Failure: LocalizedError {
        case unreadableImage

        var errorDescription: String? {
            switch self {
            case .unreadableImage: "这张图读不出来，换一张试试。"
            }
        }
    }

    @MainActor
    static func recognize(_ image: UIImage) async throws -> RecognizedText {
        guard let cgImage = image.cgImage else { throw Failure.unreadableImage }
        return try await recognize(cgImage, orientation: .init(image.imageOrientation))
    }

    /// 跑在主线程之外:识别一张十二兆像素的照片要几百毫秒,而这时候界面上那颗附件正在转圈。
    nonisolated static func recognize(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation = .up
    ) async throws -> RecognizedText {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages.map(Locale.Language.init(identifier:))
        request.minimumTextHeightFraction = minimumTextHeightFraction
        // 语言纠错开着:中文识别靠它把形近字掰回来。数字不在词典里,不受它影响——真正会
        // 写错数值的是版面,不是纠错,所以力气花在 `RecognizedTextLayout` 那边。
        request.usesLanguageCorrection = true

        let observations = try await request.perform(on: image, orientation: orientation)
        let fragments = observations.compactMap { observation -> RecognizedFragment? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            // Vision 的归一化坐标原点在左下,`RecognizedTextLayout` 按阅读顺序(左上、y 向下)
            // 想事情。翻面只此一处。
            return RecognizedFragment(
                text: candidate.string,
                frame: observation.boundingBox.verticallyFlipped().cgRect
            )
        }

        let text = RecognizedTextLayout.reconstruct(fragments)
        // 和 Word、txt 那条路走同一道闸(`ChatAttachment.maxCharacters`):一份二十页的扫描件
        // 和一份二十页的文档,对上下文的压力是同一种。
        let cut = RecognizedTextLayout.truncated(text, maxCharacters: ChatAttachment.maxCharacters)
        return RecognizedText(text: cut.text, droppedLines: cut.droppedLines)
    }
}

extension CGImagePropertyOrientation {
    /// 拍出来的照片九成不是 `.up`——不翻这一下,横着拿手机拍的化验单会被当成竖排来认。
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
