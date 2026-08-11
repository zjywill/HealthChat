import Foundation
import UIKit

/// 照片的存放处:`Documents/attachments/<id>.jpg`,**和会话文件分开**。
///
/// 分开存不是洁癖。会话文件是这个 app 里最大的一类数据,而 `SessionIndexEntry` 那套增量索引
/// 的全部收益来自「只解用得上的键」——一张 base64 进会话 JSON,列表刷新时那几百 KB 每次都要
/// 从磁盘读进来再跳过去。这里只让会话留一个文件名。
///
/// 文件保护等级和 `medications.json` 同一档(`.completeFileProtection`):一张化验单照片上有
/// 姓名、就诊号、医院和条码,比记忆里那句「他喜欢早睡」敏感得多。
actor AttachmentStore {
    /// 当前那位成员的照片(同 `SessionStore.shared`)。一张化验单上有姓名和就诊号,
    /// 而在多成员之后那个姓名多半**不是机主的**。
    static var shared: AttachmentStore { TenantScope.currentStores.attachments }

    private let directory: URL
    /// 刚读进来的几张留在手里。会话往回滚的时候同一张图会被反复要,每次都去解一遍 JPEG
    /// 是纯浪费;留太多则是拿一屏图片换住整个 app 的内存,所以只留最近几张。
    private var cache: [String: Data] = [:]
    private var cacheOrder: [String] = []
    private static let maxCachedImages = 6

    /// - Parameter parent: 测试必须传自己的临时目录(同 `SessionStore(parent:)`)。
    init(parent: URL = URL.documentsDirectory) {
        directory = parent.appending(path: "attachments", directoryHint: .isDirectory)
    }

    // MARK: - 读写

    /// 存一张,返回会话里要记的文件名。
    @discardableResult
    func store(_ data: Data, id: UUID) throws -> String {
        let name = ChatAttachment.fileName(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: url(for: name), options: [.atomic, .completeFileProtection])
        remember(data, named: name)
        return name
    }

    func data(named name: String) -> Data? {
        if let cached = cache[name] { return cached }
        guard let data = try? Data(contentsOf: url(for: name)) else { return nil }
        remember(data, named: name)
        return data
    }

    /// 会话被删掉时,它带的图片跟着走。
    ///
    /// 用户刚把这段对话删了,那张化验单还留在盘上,是这套东西最难解释的一种失灵——同
    /// 「删掉的会话必须立刻从召回索引里消失」。
    ///
    /// 分叉出去的会话和原会话共用同一批文件:删原会话,分支上那几张缩略图会变成占位。
    /// 认了——真正要紧的 OCR 文本存在消息里,一个字都不会丢。
    func remove(named names: [String]) {
        for name in names {
            try? FileManager.default.removeItem(at: url(for: name))
            cache[name] = nil
            cacheOrder.removeAll { $0 == name }
        }
    }

    private func remember(_ data: Data, named name: String) {
        cache[name] = data
        cacheOrder.removeAll { $0 == name }
        cacheOrder.append(name)
        while cacheOrder.count > Self.maxCachedImages {
            cache[cacheOrder.removeFirst()] = nil
        }
    }

    private func url(for name: String) -> URL {
        directory.appending(path: name, directoryHint: .notDirectory)
    }
}

/// 缩略图的来源。
///
/// 两级:内存里那份优先(刚拍完的、以及隐私会话里那几张压根不落盘的只有这一份),
/// 落过盘的第一次显示时从 `AttachmentStore` 读回来。
@MainActor
final class AttachmentImageCache {
    static let shared = AttachmentImageCache()

    private let cache = NSCache<NSUUID, UIImage>()

    private init() {
        // 一屏最多几张图,按张数限而不是按字节:限字节要先知道解码后有多大,而那个数
        // 只有解完才知道。
        cache.countLimit = 12
    }

    func set(_ image: UIImage, for id: UUID) {
        cache.setObject(image, forKey: id as NSUUID)
    }

    func cached(_ id: UUID) -> UIImage? {
        cache.object(forKey: id as NSUUID)
    }

    /// 拿这条附件的图。内存里没有就去盘上取,取回来的顺手留下。
    func image(for attachment: ChatAttachment) async -> UIImage? {
        if let cached = cached(attachment.id) { return cached }
        guard let name = attachment.imageFileName,
              let data = await AttachmentStore.shared.data(named: name),
              let image = UIImage(data: data)
        else { return nil }
        set(image, for: attachment.id)
        return image
    }
}

enum AttachmentImage {
    /// 存下来的那份最长边不超过这么多点。
    ///
    /// 识别在原图上跑(那一步要看清小数点),存的这份只用来让用户认出「哦，是那张」和放大
    /// 核对一下。原图一张四五兆,一段对话拍五张就把会话目录的量级整个换了一档。
    static let maxPixelSize: CGFloat = 1600
    static let compressionQuality: CGFloat = 0.7

    /// 缩到上限之内再压成 JPEG。
    static func jpegData(from image: UIImage) -> Data? {
        downscaled(image).jpegData(compressionQuality: compressionQuality)
    }

    static func downscaled(_ image: UIImage) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxPixelSize, longest > 0 else { return image }
        let scale = maxPixelSize / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
