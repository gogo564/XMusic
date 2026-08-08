import SwiftUI
import UIKit

// 汽水式竖向分页容器：基于 UIScrollView + isPagingEnabled 的原生分页
// （系统级惯性/阻尼/吸附/回弹，手感与汽水 PagingViewController 一致），
// 每页一屏高，只渲染当前页与上下邻页（对齐 cell 复用）。
// iOS 15 安全：不使用 .id/.transition 重建页面。

struct PagingPlayerScrollView<Page: View>: UIViewRepresentable {
    // 当前页索引（双向：外部可改驱动程序化滚动；吸附落定后回调）
    let currentIndex: Int
    let pageCount: Int
    let pageBuilder: (Int) -> Page
    let onIndexChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(pageBuilder: pageBuilder, onIndexChange: onIndexChange)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.isPagingEnabled = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.decelerationRate = .normal
        scrollView.delegate = context.coordinator
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        let c = context.coordinator
        c.pageCount = pageCount
        c.pageBuilder = pageBuilder
        c.onIndexChange = onIndexChange
        c.externalIndex = currentIndex
        c.layoutIfNeeded(in: scrollView)
    }

    static func dismantleUIView(_ scrollView: UIScrollView, coordinator: Coordinator) {
        coordinator.teardown()
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

        func layoutIfNeeded(in scrollView: UIScrollView) {
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
                } else {
                    let host = UIHostingController(rootView: pageBuilder(idx))
                    host.view.frame = CGRect(x: 0, y: CGFloat(idx) * height, width: width, height: height)
                    host.view.backgroundColor = .clear
                    host.view.clipsToBounds = true
                    scrollView?.addSubview(host.view)
                    hosts[idx] = host
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
