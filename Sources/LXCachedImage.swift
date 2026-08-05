import SwiftUI
import UIKit

// Simple cached async image loader (iOS 15 has no caching AsyncImage).
struct LXCachedImage: View {
    let urlString: String
    var placeholder: String = "music.note"
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @StateObject private var loader = ImageLoader()

    var body: some View {
        Group {
            if let img = loader.image {
                Image(uiImage: img)
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
        .onAppear { loader.load(urlString) }
        .onChange(of: urlString) { newURL in loader.load(newURL) }
    }
}

private final class ImageLoader: ObservableObject {
    @Published var image: UIImage?
    private static var cache = NSCache<NSString, UIImage>()

    func load(_ urlString: String) {
        guard let url = URL(string: urlString), !urlString.isEmpty else {
            image = nil
            return
        }
        let key = urlString as NSString
        if let cached = ImageLoader.cache.object(forKey: key) {
            image = cached
            return
        }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data, let img = UIImage(data: data) else { return }
            ImageLoader.cache.setObject(img, forKey: key)
            DispatchQueue.main.async { self.image = img }
        }.resume()
    }
}
