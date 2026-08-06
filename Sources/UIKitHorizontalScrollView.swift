import SwiftUI
import UIKit

/// UIKit 桥接的横向滚动容器。
///
/// 在单个 UIScrollView 上设置 delaysContentTouches = false + canCancelContentTouches = true：
/// 内部按钮点按立即响应（不再被滚动判定延迟吞掉），同时保留原生横向滑动。
/// 用于 iOS 15 嵌套 ScrollView 手势冲突（如首页纵向 ScrollView 内嵌横向标签行）。
struct UIKitHorizontalScrollView<Content: View>: UIViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.bounces = true

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            host.view.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    final class Coordinator {
        let host: UIHostingController<Content>

        init(content: Content) {
            host = UIHostingController(rootView: content)
        }
    }
}
