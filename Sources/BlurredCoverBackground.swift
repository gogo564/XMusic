import SwiftUI
import UIKit

// 汽水式沉浸背景（对齐 BNPlayBackgroundView）：
// 封面放大 + 高斯模糊铺满全屏，顶部轻微压暗、底部渐隐，营造"整首歌一个氛围"。

struct BlurredCoverBackground: View {
    let url: URL?
    @State private var image: UIImage?

    private static var cache = NSCache<NSString, UIImage>()

    var body: some View {
        ZStack {
            Color.black

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 42)
                    .scaleEffect(1.4)
                    .opacity(0.9)
                    .clipped()
            }

            // 底部渐变遮罩（对齐 bottomMaskGradientView）
            LinearGradient(
                colors: [
                    Color.black.opacity(0.35),
                    Color.black.opacity(0.15),
                    Color.black.opacity(0.45),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .onAppear { load() }
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        guard let url = url else {
            image = nil
            return
        }
        let key = url.absoluteString as NSString
        if let cached = Self.cache.object(forKey: key) {
            image = cached
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let img = UIImage(data: data) {
                    Self.cache.setObject(img, forKey: key)
                    await MainActor.run { image = img }
                }
            } catch {}
        }
    }
}
