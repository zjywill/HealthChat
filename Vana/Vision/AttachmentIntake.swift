import PhotosUI
import SwiftUI

/// 重活做完的一件。
///
/// 和 `ImportedAttachment` 分成两个类型,是因为它们中间隔着一次线程切换:那一个是刚拿到手的
/// 原件(一张十二兆像素的照片、一份还没渲染的 PDF),这一个是缩好、取好、可以直接摆上屏幕的。
/// 中间那一步必须发生在主线程外面。
enum PreparedAttachment {
    /// `preview` 是缩到 `AttachmentImage.maxPixelSize` 的那份(显示和存盘都用它),
    /// `original` 留给识别——那一步要看清小数点。
    case photo(preview: UIImage, original: UIImage)
    case document(name: String, text: String, droppedLines: Int, failure: String?)
}

/// 从「他选完了」到「那一排出现在输入框上方」之间的这一段。
///
/// 拍、选、挑文件三条入口在这里合流,而这件事有两半:
///
/// - **占位当场摆上。** 选择器关掉之后到那一排出现之间原来是几秒钟的空白:屏幕上一个像素都
///   不变,而他刚做完一个动作。那读起来不是「慢」,是「没反应」——他会再点一次加号。所以按他
///   选的件数先摆上几个转圈的格子,每一件各自到齐各自翻面。顺序按他选的来:格子先占住了,
///   谁先读完就不影响谁排在哪。
/// - **重活挪出主线程。** 读一份原始数据、解一次 JPEG、缩一次图,六张连着做是实打实的一秒
///   多卡死;一份 PDF 按两倍渲染六页更久。原来这些全在主线程上,所以那几秒里连转圈都转不动
///   ——光加占位不挪线程,换来的只是一个卡住的圈。
///
/// 一份 PDF 会渲染出好几页,所以占位和最后的件数不是一一对应:第一页顶掉那个格子,剩下的
/// 紧跟在它后面插进去(见 `ChatViewModel.fill`)。
@MainActor
enum AttachmentIntake {
    /// 文档扫描器拍完的那几页。图已经在内存里了,慢的是缩图那一下。
    static func scanned(_ pages: [UIImage], into model: ChatViewModel) {
        let ids = model.reserveAttachments(pages.count)
        for (id, page) in zip(ids, pages) {
            Task { model.fill(id, with: await prepared([.photo(page)])) }
        }
    }

    /// 相册里选的那几张。
    ///
    /// 每张各起一个任务并发读,不排队一张一张来:`loadTransferable` 多数时间花在等 Photos
    /// 把原件递过来,六张排着等就是六份等待时间叠在一起。
    static func photos(_ items: [PhotosPickerItem], into model: ChatViewModel) {
        let ids = model.reserveAttachments(items.count)
        for (id, item) in zip(ids, items) {
            Task {
                guard let prepared = await decoded(item) else {
                    // 这一格不能一直转下去:转不停和真的卡住在屏幕上是一模一样的。
                    model.failAttachment(id, message: unreadablePhoto)
                    return
                }
                model.fill(id, with: [prepared])
            }
        }
    }

    /// 从「文件」里挑的那几份。
    static func files(_ urls: [URL], into model: ChatViewModel) {
        let ids = model.reserveAttachments(urls.count)
        for (id, url) in zip(ids, urls) {
            Task { model.fill(id, with: await loaded(url)) }
        }
    }

    private static let unreadablePhoto = "这张照片读不出来，换一张试试。"

    // MARK: - 主线程外面

    /// `nonisolated` 的 async 函数跑在协作线程池上,不继承调用方的主线程隔离——下面这三个
    /// 就是靠这一条把重活挪出去的。改成同步函数会当场退回主线程,而那正是要修的东西。
    private nonisolated static func decoded(_ item: PhotosPickerItem) async -> PreparedAttachment? {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else { return nil }
        return prepare(.photo(image))
    }

    private nonisolated static func loaded(_ url: URL) async -> [PreparedAttachment] {
        AttachmentImporter.load(at: url).map(prepare)
    }

    private nonisolated static func prepared(
        _ items: [ImportedAttachment]
    ) async -> [PreparedAttachment] {
        items.map(prepare)
    }

    private nonisolated static func prepare(_ item: ImportedAttachment) -> PreparedAttachment {
        switch item {
        case .photo(let image):
            // 缩图会强制解码一整张原图,一张十二兆像素的照片要几十上百毫秒——原来卡在主线程上
            // 的就是这一下,连着六张就是一秒多。
            .photo(preview: AttachmentImage.downscaled(image), original: image)
        case .document(let name, let text, let droppedLines, let failure):
            .document(name: name, text: text, droppedLines: droppedLines, failure: failure)
        }
    }
}
