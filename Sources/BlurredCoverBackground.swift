import SwiftUI
import UIKit
import CoreImage

// 汽水式沉浸背景（对齐 BNPlayBackgroundView）：
// 取封面主色做渐变底，再叠一层放大模糊的封面，换歌时颜色平滑过渡，
// 形成"整首歌一个氛围"的效果（参考网易云 CarPlay 播放页）。

struct BlurredCoverBackground: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var tint: Color = Color(red: 0.07, green: 0.075, blue: 0.095)

    private static var imageCache = NSCache<NSString, UIImage>()
    private static var tintCache = NSCache<NSString, UIColor>()

    var body: some View {
        ZStack {
            Color.black

            // 主色渐变：左上偏亮、右下压黑，文字始终可读
            LinearGradient(
                colors: [
                    tint.opacity(1.0),
                    tint.opacity(0.55),
                    Color.black.opacity(0.97),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 42)
                    .scaleEffect(1.4)
                    .opacity(0.50)
                    .clipped()
            }

            // 底部渐变遮罩（对齐 bottomMaskGradientView）
            LinearGradient(
                colors: [
                    Color.black.opacity(0.30),
                    Color.black.opacity(0.10),
                    Color.black.opacity(0.45),
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
        guard let url = url else {
            image = nil
            return
        }
        let key = url.absoluteString as NSString
        if let cached = Self.imageCache.object(forKey: key) {
            image = cached
            if let color = Self.tintCache.object(forKey: key) {
                tint = Color(color)
            } else if let color = Self.averageColor(of: cached) {
                Self.tintCache.setObject(color, forKey: key)
                tint = Color(color)
            }
            return
        }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let img = UIImage(data: data) else { return }
                Self.imageCache.setObject(img, forKey: key)
                let color = Self.averageColor(of: img)
                if let color = color {
                    Self.tintCache.setObject(color, forKey: key)
                }
                await MainActor.run {
                    image = img
                    if let color = color {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            tint = Color(color)
                        }
                    }
                }
            } catch {}
        }
    }

    /// 取封面平均色，并适当提饱和/限亮度，避免纯黑或过亮刺眼
    private static func averageColor(of image: UIImage) -> UIColor? {
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
        return UIColor(hue: h,
                       saturation: min(1, max(0.36, s * 1.40)),
                       brightness: min(0.66, max(0.40, b * 1.15)),
                       alpha: 1)
    }
}
