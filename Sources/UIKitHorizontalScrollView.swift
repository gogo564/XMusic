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
        // 标签行只允许横向滚动：contentSize.height 严格锁定为容器高，
        // 否则垂直方向也能滚动，点着标签上下滑会把整行滚出屏幕（"向下就隐藏"）。
        scrollView.alwaysBounceVertical = false
        // LazyVStack 回收重建 / 尺寸变化后，SwiftUI 不一定再次调用 updateUIView，
        // 因此在自身 bounds 变化（含重建后恢复布局）时也主动重排内容，避免空白。
        let coordinator = context.coordinator

        let host = context.coordinator.host
        host.view.backgroundColor = .clear
        scrollView.addSubview(host.view)
        // 实例刚创建时 bounds 尚为 zero（layoutSubviews 的 lastBounds 判定不触发），
        // 此时不主动重排会导致 LazyVStack 回收重建后标签空白。下一 runloop 强制排一次。
        scrollView.onLayoutChanged = { [weak coordinator] in
            coordinator?.layoutContent(in: scrollView)
        }
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
        /// 最近一次 layoutContent 排出的内容宽度（在 onLayoutChanged 里回写）
        var lastContentWidth: CGFloat = 0

        override func layoutSubviews() {
            super.layoutSubviews()
            // 只比较 size，忽略 origin：滚动时 bounds.origin 随 contentOffset 逐帧变化，
            // 若比较整个 bounds 会导致滚动每一帧都触发昂贵的 fittingSize 重排（卡顿）且可能把内容宽度算成 0（空白）。
            if bounds.size != lastSize {
                lastSize = bounds.size
                onLayoutChanged?()
                return
            }
            // 兜底：LazyVStack cell 滚出屏幕再滚回时，SwiftUI 可能不销毁实例、bounds.size 不变、
            // 也不回调 updateUIView / didMoveToWindow，但 host.view 的布局已被系统重置成 1px 占位
            // （contentSize 反映当前实际内容宽）。此时强制重排一次，正常宽度不会触发，不卡顿。
            if bounds.width > 1, contentSize.width <= 1 {
                onLayoutChanged?()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // LazyVStack 回收重建时，cell 滚出屏幕会被移出 window，滚回时重新加入。
            // SwiftUI 此时不一定会再次调用 updateUIView，且 bounds.size 可能没变，
            // 上面 layoutSubviews 的 size 判断触发不到 -> 内容空白（用户触碰滚动才会恢复）。
            // 重新进入 window 必然回调这里，借此强制重排内容。
            // 刚加入 window 时 bounds 可能仍为 0（重排会退化成 1 宽占位），下一 runloop 排一次纠正。
            guard window != nil else { return }
            onLayoutChanged?()
            DispatchQueue.main.async { [weak self] in
                self?.onLayoutChanged?()
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
            // host.view 用内容真实高度（含 padding）：若用容器高度，重建时 bounds 未就绪
            // 会拿到偏小值导致标签被裁剪成"只看到上半部分"。
            let contentHeight = max(fittingSize.height, height)
            host.view.frame = CGRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
            // contentSize.height 严格锁为容器高：只要它大于 bounds.height，
            // 标签行就能垂直滚动，点着标签上下滑会把整行滚出屏幕（"向下就隐藏"）。
            scrollView.contentSize = CGSize(width: contentWidth, height: height)
            // 回写本次实际排出的内容宽度，供 layoutSubviews 校验"1px 退化值"
            if let lx = scrollView as? LXHorizontalScrollView {
                lx.lastContentWidth = contentWidth
            }
        }
    }
}
