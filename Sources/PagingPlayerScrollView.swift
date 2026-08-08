import SwiftUI
import UIKit

// 汽水式竖向分页容器：基于 UIScrollView + isPagingEnabled 的原生分页
// （系统级惯性/阻尼/吸附/回弹，手感与汽水 PagingViewController 一致），
// 每页一屏高，只渲染当前页与上下邻页（对齐 cell 复用）。
// iOS 15 安全：不使用 .id/.transition 重建页面。
//
// 用自定义 LayoutSyncScrollView 子类：layoutSubviews 里同步 hosting view
// 尺寸，确保每页都精确铺满一屏（否则内容会被安全区/父视图压缩，
// 表现为"横版显示不全 / 背景不铺满 / 底部控制区消失"）。

struct PagingPlayerScrollView<Page: View>: UIViewRepresentable {
    // 当前页索引（双向：外部可改驱动程序化滚动；吸附落定后回调）
    let currentIndex: Int
    let pageCount: Int
    let pageBuilder: (Int) -> Page
    let onIndexChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(pageBuilder: pageBuilder, onIndexChange: onIndexChange)
    }

    func makeUIView(context: Context) -> LayoutSyncScrollView {
        let scrollView = LayoutSyncScrollView()
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.decelerationRate = .normal
        // 关键：不要自动把内容压进安全区（否则每页 hosting view 被上下压缩，
        // 表现为背景不铺满、底部歌词/控制区被挤出屏幕，像"横版显示不全"）
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = .zero
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        scrollView.delegate = context.coordinator
        context.coordinator.scrollView = scrollView
        let coordinator = context.coordinator
        scrollView.onLayout = { [weak coordinator] in
            coordinator?.syncLayout()
        }
        return scrollView
    }

    func updateUIView(_ scrollView: LayoutSyncScrollView, context: Context) {
        let c = context.coordinator
        c.pageCount = pageCount
        c.pageBuilder = pageBuilder
        c.onIndexChange = onIndexChange
        c.externalIndex = currentIndex
        c.syncLayout()
    }

    static func dismantleUIView(_ scrollView: LayoutSyncScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Scroll View 子类：在 layoutSubviews 后同步 hosting view

    final class LayoutSyncScrollView: UIScrollView {
        var onLayout: (() -> Void)?

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var pageCount: Int = 0
        var pageBuilder: (Int) -> Page
        var onIndexChange: ((Int) -> Void)?
        var externalIndex: Int = 0

        weak var scrollView: UIScrollView?
        private var hosts: [Int: UIHostingController<Page>] = [:]
        private var renderedCenter: Int?
        private var userInteracting = false

        init(pageBuilder: @escaping (Int) -> Page, onIndexChange: @escaping (Int) -> Void) {
            self.pageBuilder = pageBuilder
            self.onIndexChange = onIndexChange
            super.init()
        }

        // MARK: Layout

        /// 每次 scrollView 布局变化都调用，确保 contentSize / hosting frame 与 bounds 一致
        func syncLayout() {
            guard let scrollView else { return }
            let w = scrollView.bounds.width
            let h = scrollView.bounds.height
            guard w > 0, h > 0 else { return }

            scrollView.contentSize = CGSize(width: w, height: CGFloat(max(pageCount, 1)) * h)

            // 外部索引变化（切歌/加载完成）→ 程序化滚动到对应页
            let target = CGPoint(x: 0, y: CGFloat(externalIndex) * h)
            if !userInteracting && abs(scrollView.contentOffset.y - target.y) > 1 {
                scrollView.setContentOffset(target, animated: false)
            }

            renderWindow(center: externalIndex, width: w, height: h)
        }

        // 只渲染当前页 + 上下邻页（对齐 CollectionView cell 复用）
        private func renderWindow(center: Int, width: CGFloat, height: CGFloat) {
            let lower = max(0, center - 1)
            let upper = min(max(pageCount - 1, 0), center + 1)
            guard center >= lower, center <= upper else { return }
            if center == renderedCenter && hosts.count == upper - lower + 1 {
                // 布局未变但尺寸可能变了（旋转/安全区变化）：仍需刷新已有 host 的 frame，
                // 否则内容按旧尺寸排版，表现为"横版显示不全/背景不铺满"
                for (idx, host) in hosts {
                    host.view.frame = CGRect(x: 0, y: CGFloat(idx) * height, width: width, height: height)
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                }
                return
            }
            renderedCenter = center

            let needed = Set(lower...upper)
            for (idx, host) in hosts where !needed.contains(idx) {
                host.view.removeFromSuperview()
                hosts.removeValue(forKey: idx)
            }
            for idx in needed {
                if let host = hosts[idx] {
                    host.rootView = pageBuilder(idx)
                    host.view.frame = CGRect(x: 0, y: CGFloat(idx) * height, width: width, height: height)
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                } else {
                    let host = UIHostingController(rootView: pageBuilder(idx))
                    host.view.frame = CGRect(x: 0, y: CGFloat(idx) * height, width: width, height: height)
                    host.view.backgroundColor = .clear
                    host.view.clipsToBounds = true
                    host.view.autoresizingMask = []
                    scrollView?.addSubview(host.view)
                    hosts[idx] = host
                    // 首次布局：frame 设完立即强制布局，避免 SwiftUI 按默认大小排版
                    host.view.layoutIfNeeded()
                }
            }
        }

        func teardown() {
            for host in hosts.values {
                host.view.removeFromSuperview()
            }
            hosts.removeAll()
        }

        // MARK: Scroll Delegate

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userInteracting = true
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                userInteracting = false
                settle(scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            userInteracting = false
            settle(scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            settle(scrollView)
        }

        private func settle(_ scrollView: UIScrollView) {
            let h = scrollView.bounds.height
            guard h > 0 else { return }
            let idx = min(max(Int((scrollView.contentOffset.y / h).rounded()), 0), max(pageCount - 1, 0))
            externalIndex = idx
            renderWindow(center: idx, width: scrollView.bounds.width, height: h)
            onIndexChange?(idx)
        }
    }
}
