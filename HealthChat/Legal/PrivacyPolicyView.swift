import SwiftUI
import WebKit

/// 隐私说明。内容不在这个文件里——它直接渲染打进 app 包的那份 `PrivacyPolicy.html`。
///
/// **一份内容,两个读者**(同 `SessionTitle.make` 那条):app 里这一页,和 App Store Connect
/// 要填的那个隐私政策 URL,必须逐字一致。写成原生 SwiftUI 再另存一份 HTML 去发布,就是同一份
/// 法律文本的两个副本——改一处忘一处是迟早的事,而对不上的那一条恰好会是审核在核对的那条。
enum PrivacyPolicy {
    static let resourceName = "PrivacyPolicy"

    static var fileURL: URL? {
        Bundle.main.url(forResource: resourceName, withExtension: "html")
    }
}

struct PrivacyPolicyView: View {
    var body: some View {
        Group {
            if let url = PrivacyPolicy.fileURL {
                PolicyWebView(fileURL: url)
                    .ignoresSafeArea(edges: .bottom)
            } else {
                // 这一页是有硬性要求的那种页面,空白比什么都糟。真掉了资源至少要说清
                // 去哪儿看得到——`ComplianceTests` 盯着这条路不该发生。
                ContentUnavailableView {
                    Label("隐私说明暂时打不开", systemImage: "doc.questionmark")
                } description: {
                    Text("可以在 github.com/zjywill/HealthChat 上看到同一份内容。")
                }
            }
        }
        .navigationTitle("隐私说明")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// 本地文件,不联网。里面的链接(GitHub、mailto)交给系统,不在这块 web view 里打开——
/// 一个隐私政策页面变成一个能到处点的浏览器,是这一页最不该有的形状。
private struct PolicyWebView: UIViewRepresentable {
    let fileURL: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = false
        // 页面自己按 `prefers-color-scheme` 定背景色。这一句只管越界回弹时露出来的那一块,
        // 少了它深色模式下往下拉会闪一片白。
        view.underPageBackgroundColor = .systemBackground
        view.loadFileURL(fileURL, allowingReadAccessTo: fileURL)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard navigationAction.navigationType == .linkActivated,
                  let url = navigationAction.request.url else {
                return .allow
            }
            await UIApplication.shared.open(url)
            return .cancel
        }
    }
}

#Preview {
    NavigationStack {
        PrivacyPolicyView()
    }
}
