import SwiftUI
import UIKit
import CoreImage

// 网易云 CarPlay 播放页同款背景：
// 取封面主色，压暗后做「上亮下黑」的竖向渐变，换歌时 0.5 秒平滑过渡。
// 不放模糊封面图，保持画面干净、文字对比稳定。

struct BlurredCoverBackground: View {
    let url: URL?
    @State private var tint: Color = Color(red: 0.10, green: 0.10, blue: 0.11)

    private static var tintCache = NSCache<NSString, UIColor>()

    var body: some View {
        // 必须有不透明底色：否则渐变里的半透明色会把下面的列表“透”出来
        ZStack {
            Color.black
            LinearGradient(
                colors: [
                    tint.opacity(1.0),
                    tint.opacity(0.55),
                    Color.black.opacity(0.97),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: url)
        .onAppear { load() }
        .onChange(of: url) { _ in load() }
    }

    private func load() {
        guard let url = url else { return }
        let key = url.absoluteString as NSString
        if let cached = Self.tintCache.object(forKey: key) {
            tint = Color(cached)
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = UIImage(data: data),
                      let color = Self.dominantColor(of: img) else { return }
                Self.tintCache.setObject(color, forKey: key)
                await MainActor.run {
                    // 防止旧歌的异步结果覆盖新歌
                    guard self.url?.absoluteString == (key as String) else { return }
                    withAnimation(.easeInOut(duration: 0.5)) {
                        tint = Color(color)
                    }
                }
            } catch {}
        }
    }

    /// 封面平均色 → 压暗、提一点饱和，得到网易云那种深色氛围色
    private static func dominantColor(of image: UIImage) -> UIColor? {
        guard let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: input,
            "inputExtent": CIVector(cgRect: input.extent),
        ]), let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output,
                       toBitmap: &pixel,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: nil)

        let raw = UIColor(red: CGFloat(pixel[0]) / 255,
                          green: CGFloat(pixel[1]) / 255,
                          blue: CGFloat(pixel[2]) / 255,
                          alpha: 1)

        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard raw.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return raw }
        // 亮度压到 0.20~0.38：顶部能看出版面主色，底部渐变到黑
        return UIColor(hue: h,
                       saturation: min(0.90, max(0.28, s * 1.15)),
                       brightness: min(0.38, max(0.20, b * 0.60)),
                       alpha: 1)
    }
}
