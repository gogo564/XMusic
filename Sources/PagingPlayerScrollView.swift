import SwiftUI
import UIKit

// 汽水式竖向分页容器：基于 UIPageViewController(.scroll) 的原生分页。
// 每页一个 UIHostingController，由 UIPageViewController 负责把每页自动填满容器
// （内部用 Auto Layout 把子控制器 view 钉满 bounds），无需手动管理 hosting frame，
// 彻底避免 UIHostingController 按内容固有尺寸渲染导致"页面不铺满/背景不全/底部被挤出"。
// iOS 15 安全：不使用 .id/.transition 重建页面。

struct PagingPlayerScrollView<Page: View>: UIViewControllerRepresentable {
    // 当前页索引（双向：外部可改驱动程序化滚动；吸附落定后回调）
    let currentIndex: Int
    let pageCount: Int
    let pageBuilder: (Int) -> Page
    let onIndexChange: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let vc = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .vertical,
            options: [.interPageSpacing: 0]
        )
        vc.dataSource = context.coordinator
        vc.delegate = context.coordinator
        vc.view.backgroundColor = .black
        return vc
    }

    func updateUIViewController(_ vc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.currentIndex = currentIndex
        c.pageCount = pageCount
        c.pageBuilder = pageBuilder
        c.onIndexChange = onIndexChange
        c.sync(vc)
    }

    static func dismantleUIViewController(_ vc: UIPageViewController, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var currentIndex: Int = 0
        var pageCount: Int = 0
        var pageBuilder: ((Int) -> Page)?
        var onIndexChange: ((Int) -> Void)?

        private var cache: [Int: UIViewController] = [:]
        private var current = 0
        private var isTransitioning = false

        // MARK: Sync

        func sync(_ vc: UIPageViewController) {
            let target = min(max(currentIndex, 0), max(pageCount - 1, 0))
            if vc.viewControllers?.isEmpty ?? true {
                current = target
                vc.setViewControllers([makePage(target)], direction: .forward, animated: false, completion: nil)
            } else if target != current, !isTransitioning {
                let direction: UIPageViewController.NavigationDirection = target > current ? .forward : .reverse
                current = target
                vc.setViewControllers([makePage(target)], direction: direction, animated: false, completion: nil)
            }
            // 只保留当前页附近的控制器，避免长队列内存膨胀
            for key in cache.keys where abs(key - current) > 3 {
                cache.removeValue(forKey: key)
            }
        }

        private func makePage(_ idx: Int) -> UIViewController {
            if let v = cache[idx] { return v }
            let host = UIHostingController(rootView: pageBuilder?(idx))
            host.view.backgroundColor = .black
            host.view.clipsToBounds = true
            cache[idx] = host
            return host
        }

        func teardown() {
            cache.removeAll()
        }

        // MARK: DataSource

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            let idx = index(of: vc)
            guard idx > 0 else { return nil }
            return makePage(idx - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            let idx = index(of: vc)
            guard idx + 1 < pageCount else { return nil }
            return makePage(idx + 1)
        }

        // MARK: Delegate

        func pageViewController(_ pvc: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
            isTransitioning = true
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            isTransitioning = false
            guard completed, let vc = pvc.viewControllers?.first else { return }
            let idx = index(of: vc)
            guard idx != current else { return }
            current = idx
            onIndexChange?(idx)
        }

        private func index(of vc: UIViewController) -> Int {
            for (k, v) in cache where v === vc { return k }
            return current
        }
    }
}
