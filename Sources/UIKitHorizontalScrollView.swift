import SwiftUI
import UIKit

/// UIKit 桥接的横向滚动容器。
///
/// 在单个 UIScrollView 上设置 delaysContentTouches = false + canCancelContentTouches = true：
/// 内部按钮点按立即响应（不再被滚动判定延迟吞掉），同时保留原生横向滑动。
///
/// 注意：不能用 Auto Layout 把内容 trailing 绑到 contentLayoutGuide.trailing，
/// UIHostingController 视图无内在宽度，会形成宽度循环依赖导致内容被压缩成 0 宽（标签变小无字）。
/// 因此改为计算 fittingSize 后手动设置 host.view.frame + scrollView.contentSize。
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
        scrollView.addSubview(host.view)
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
        context.coordinator.layoutContent(in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    final class Coordinator {
        let host: UIHostingController<Content>

        init(content: Content) {
            host = UIHostingController(rootView: content)
        }

        func layoutContent(in scrollView: UIScrollView) {
            let height = scrollView.bounds.height > 0 ? scrollView.bounds.height : 40
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let fittingSize = host.view.systemLayoutSizeFitting(
                CGSize(width: UIView.layoutFittingExpandedSize.width, height: height),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .required
            )
            let contentWidth = max(fittingSize.width, scrollView.bounds.width)
            let contentHeight = max(fittingSize.height, height)
            host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
            scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        }
    }
}
