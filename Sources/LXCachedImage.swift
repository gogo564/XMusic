import SwiftUI
import UIKit
import ImageIO

// 懒加载缓存图片（iOS 15 无自带缓存 AsyncImage）。
// 优化点（滚动卡顿）：
// 1. ImageIO 降采样解码到目标尺寸，避免全分辨率大图解码耗 CPU/内存；
// 2. 专用 URLSession + 磁盘 URLCache，滚动重复出现/重启 App 不重复下载；
// 3. .task(id:) 生命周期：滚出屏幕自动取消，URL 变化不重复加载；
// 4. 同 URL 并发去重，快速滚动不会为同一张图并发多次下载/解码。
struct LXCachedImage: View {
    let urlString: String
    var placeholder: String = "music.note"
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(.systemGray5))
                    Image(systemName: placeholder)
                        .font(.system(size: size * 0.35))
                        .foregroundColor(Color(.systemGray))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: urlString) {
            image = await LXImageLoader.shared.load(urlString, maxPixel: max(Int(size * 3), 96))
        }
    }
}

final class LXImageLoader: @unchecked Sendable {
    static let shared = LXImageLoader()

    private static let memoryCache = NSCache<NSString, UIImage>()

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()

    private let lock = NSLock()
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        LXImageLoader.memoryCache.totalCostLimit = 64 * 1024 * 1024
        LXImageLoader.memoryCache.countLimit = 500
    }

    /// 返回目标尺寸的缩略图（nil = 未加载/URL 非法/加载取消）。
    func load(_ urlString: String, maxPixel: Int) async -> UIImage? {
        guard let url = URL(string: urlString), !urlString.isEmpty else { return nil }
        let key = urlString as NSString

        if let cached = LXImageLoader.memoryCache.object(forKey: key) {
            return cached
        }

        let cacheKey = urlString
        lock.lock()
        if let running = inflight[cacheKey] {
            lock.unlock()
            return await running.value
        }
        let task = Task<UIImage?, Never> { [weak self] in
            await self?.fetchAndDecode(url: url, key: key, maxPixel: maxPixel)
        }
        inflight[cacheKey] = task
        lock.unlock()

        let result = await task.value

        // 同 key 只会存在一个任务（并发加载会复用 inflight 里的完成/进行中任务），
        // 完成后清掉即可由后续加载创建新任务。
        lock.lock()
        inflight[cacheKey] = nil
        lock.unlock()
        return result
    }

    private func fetchAndDecode(url: URL, key: NSString, maxPixel: Int) async -> UIImage? {
        let data: Data
        do {
            // data(for:) 在 Swift Task 取消时会主动取消底层 URLSessionTask 并抛错
            let (d, _) = try await LXImageLoader.session.data(for: URLRequest(url: url))
            data = d
        } catch {
            return nil
        }
        guard !Task.isCancelled, data.count > 0 else { return nil }
        // 解码是重活，放到工具优先级后台执行，避免卡主线程
        let decoded = await Task.detached(priority: .utility) {
            LXImageLoader.downsample(data, maxPixel: maxPixel)
        }.value
        if let decoded {
            LXImageLoader.memoryCache.setObject(decoded, forKey: key, cost: data.count)
        }
        return Task.isCancelled ? nil : decoded
    }

    /// ImageIO 降采样解码：直接生成指定最大边长的小图，避免解 1024/2048 大图。
    private static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}