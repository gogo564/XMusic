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
        let scrollView = LXHorizontalScrollView()
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.bounces = true
        // LazyVStack 回收重建 / 尺寸变化后，SwiftUI 不一定再次调用 updateUIView，
        // 因此在自身 bounds 变化（含重建后恢复布局）时也主动重排内容，避免空白。
        let coordinator = context.coordinator
        scrollView.onLayoutChanged = { [weak coordinator] in
            coordinator?.layoutContent(in: scrollView)
        }

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        scrollView.addSubview(host.view)
        // 实例刚创建时 bounds 尚为 zero（layoutSubviews 的 lastBounds 判定不触发），
        // 此时不主动重排会导致 LazyVStack 回收重建后标签空白。下一 runloop 强制排一次。
        DispatchQueue.main.async { [weak coordinator, weak scrollView] in
            guard let coordinator = coordinator, let scrollView = scrollView else { return }
            coordinator.layoutContent(in: scrollView)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.host.rootView = content
        context.coordinator.layoutContent(in: scrollView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(content: content)
    }

    /// 在 frame/bounds 变化或 LazyVStack 回收重建后重新计算内容布局。
    final class LXHorizontalScrollView: UIScrollView {
        var onLayoutChanged: (() -> Void)?
        private var lastSize = CGSize.zero

        override func layoutSubviews() {
            super.layoutSubviews()
            // 只比较 size，忽略 origin：滚动时 bounds.origin 随 contentOffset 逐帧变化，
            // 若比较整个 bounds 会导致滚动每一帧都触发昂贵的 fittingSize 重排（卡顿）且可能把内容宽度算成 0（空白）。
            if bounds.size != lastSize {
                lastSize = bounds.size
                onLayoutChanged?()
            }
        }
    }

    final class Coordinator {
        let host: UIHostingController<Content>

        init(content: Content) {
            host = UIHostingController(rootView: content)
        }

        func layoutContent(in scrollView: UIScrollView) {
            let viewWidth = scrollView.bounds.width
            let height = scrollView.bounds.height > 0 ? scrollView.bounds.height : 40
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            let fittingSize = host.view.systemLayoutSizeFitting(
                CGSize(width: UIView.layoutFittingExpandedSize.width, height: height),
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .required
            )
            // 内容宽度兜底：系统首次布局可能算不出宽度（返回 0），此时退回到容器宽度，
            // 避免内容被设成 0 宽导致标签空白；之后 updateUIView / size 变化会再排一次纠正。
            let contentWidth = fittingSize.width > 0 ? fittingSize.width : max(viewWidth, 1)
            let contentHeight = max(fittingSize.height, height)
            host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
            scrollView.contentSize = CGSize(width: contentWidth, height: contentHeight)
        }
    }
}
