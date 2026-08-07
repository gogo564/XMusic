import SwiftUI

// 竖滑分页容器：原生 UIScrollView pagingEnabled，iOS 15 兼容，滑到哪页回调 currentPage
struct VerticalPager<Content: View>: UIViewRepresentable {
    let pageHeight: CGFloat
    let pageCount: Int
    @Binding var currentPage: Int
    @Binding var scrollTo: Int?
    let content: () -> Content

    init(pageHeight: CGFloat, pageCount: Int, currentPage: Binding<Int>, scrollTo: Binding<Int?>, @ViewBuilder content: @escaping () -> Content) {
        self.pageHeight = pageHeight
        self.pageCount = pageCount
        self._currentPage = currentPage
        self._scrollTo = scrollTo
        self.content = content
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let sv = UIScrollView()
        sv.isPagingEnabled = true
        sv.showsVerticalScrollIndicator = false
        sv.bounces = false
        sv.delegate = context.coordinator
        return sv
    }

    func updateUIView(_ sv: UIScrollView, context: Context) {
        let coordinator = context.coordinator
        let hosting = coordinator.hosting
        hosting.rootView = content()

        let width = max(sv.bounds.width, 320)
        let totalHeight = pageHeight * CGFloat(max(pageCount, 1))
        hosting.view.frame = CGRect(x: 0, y: 0, width: width, height: totalHeight)
        if hosting.view.superview !== sv {
            sv.addSubview(hosting.view)
        }
        sv.contentSize = CGSize(width: width, height: totalHeight)

        // 页数变化（切模式/刷新）时回到第一页
        if coordinator.lastCount != pageCount {
            coordinator.lastCount = pageCount
            sv.setContentOffset(.zero, animated: false)
            if currentPage != 0 {
                DispatchQueue.main.async { currentPage = 0 }
            }
        }

        // 外部请求跳页（下一首按钮等）
        if let target = scrollTo {
            let page = min(max(target, 0), max(pageCount - 1, 0))
            sv.setContentOffset(CGPoint(x: 0, y: pageHeight * CGFloat(page)), animated: true)
            DispatchQueue.main.async { scrollTo = nil }
        }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let parent: VerticalPager
        let hosting: UIHostingController<Content>
        var lastCount: Int = -1

        init(_ parent: VerticalPager) {
            self.parent = parent
            self.hosting = UIHostingController(rootView: parent.content())
        }

        func scrollViewDidScroll(_ sv: UIScrollView) {
            let height = max(sv.bounds.height, 1)
            let page = Int((sv.contentOffset.y + height / 2) / height)
            let clamped = min(max(page, 0), max(parent.pageCount - 1, 0))
            if clamped != parent.currentPage {
                DispatchQueue.main.async {
                    self.parent.currentPage = clamped
                }
            }
        }
    }
}
