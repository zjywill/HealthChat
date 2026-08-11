import SwiftUI
import VisionKit

/// 系统的文档扫描器。拍化验单比用相机随手拍好得多:它自己找边、纠偏、还能连拍好几页。
///
/// 纠偏这一步顺带救了 `RecognizedTextLayout`——歪着拍的表格,同一行的项目和数值在画面里
/// 不在同一个高度上,聚行就会把它们分到两行去。
///
/// 模拟器上 `isSupported` 是 false(没有摄像头),所以「从相册选取」那条路不是可选项,
/// 是这个功能在模拟器上唯一验得动的入口。
struct DocumentScannerView: UIViewControllerRepresentable {
    let onFinish: ([UIImage]) -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinish: onFinish)
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onFinish: ([UIImage]) -> Void

        init(onFinish: @escaping ([UIImage]) -> Void) {
            self.onFinish = onFinish
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            // 一页一张附件:每一页各自识别、各自能删。多页糊成一段文本的话,用户想删掉
            // 不相关的那一页就只能整段重来。
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            onFinish(pages)
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onFinish([])
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: any Error
        ) {
            print("文档扫描失败：\(error.localizedDescription)")
            onFinish([])
        }
    }
}
