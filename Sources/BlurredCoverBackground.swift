import SwiftUI
import UIKit

// 网易云 CarPlay 播放页同款背景：
// 封面铺满 + 大半径模糊，再压一层暗色，保留封面原本的色调氛围。
// 换歌时新旧背景做 0.5 秒淡入淡出。

struct BlurredCoverBackground: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var loadedKey: String?

    var body: some View {
        GeometryReader { g in
            ZStack {
                // 必须有不透明底色：否则模糊图边缘的半透明会把下面的列表透出来
                Color.black
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .scaleEffect(1.18)
                        .blur(radius: 38)
                        .overlay(Color.black.opacity(0.22))
                        .id(loadedKey)
                        .transition(.opacity)
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: loadedKey)
        .onAppear { load() }
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        guard let urlString = url?.absoluteString, !urlString.isEmpty else {
            image = nil
            loadedKey = nil
            return
        }
        if loadedKey == urlString { return }
        Task {
            let img = await LXImageLoader.shared.load(urlString, maxPixel: 512)
            await MainActor.run {
                // 防止快速切歌时旧歌的异步结果覆盖新歌
                guard self.url?.absoluteString == urlString, let img else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    image = img
                    loadedKey = urlString
                }
            }
        }
    }
}
