import ImageIO
import SwiftUI
import UIKit

/// AsyncImage with a memory cache: a thumbnail that scrolls back into view shows at once instead
/// of loading and decoding again. Pictures decode off the main thread, at most `maxPixels` wide.
struct RemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var maxPixels: CGFloat = 1600
    @ViewBuilder let content: (Image) -> Content
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, maxPixels: CGFloat = 1600, @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixels = maxPixels
        self.content = content
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { ImageCache.shared.memory($0) })
    }

    var body: some View {
        Group {
            if let image { content(Image(uiImage: image)) } else { placeholder() }
        }
        .task(id: url) {
            guard let url else { return }
            if let hit = ImageCache.shared.memory(url) {
                if image !== hit { image = hit }
                return
            }
            if let img = await ImageCache.shared.load(url, maxPixels: maxPixels, early: { image = $0 }),
               !Task.isCancelled, image !== img {
                image = img
            }
        }
    }
}

final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.totalCostLimit = 120 * 1024 * 1024
        return c
    }()
    /// Disk cache for the bytes. The Mac sends Last-Modified, so an unchanged picture costs a 304.
    /// A sleeping Mac fails in 10 s, not the default 60.
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 0, diskCapacity: 300 * 1024 * 1024)
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    func memory(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// The copy on disk first, however old, handed to `early` at once; then the Mac's copy, decoded
    /// only when its bytes differ. Offline, the disk copy stays (2026-10-03, 2026-10-08).
    func load(_ url: URL, maxPixels: CGFloat, early: (@MainActor (UIImage) -> Void)? = nil) async -> UIImage? {
        let old = try? await session.data(for: URLRequest(url: url, cachePolicy: .returnCacheDataDontLoad))
        var shown: UIImage?
        if let old, Self.ok(old.1), let img = await decoded(old.0, url, maxPixels) {
            shown = img
            if !Task.isCancelled { await early?(img) }
        }
        guard let fresh = try? await session.data(from: url), Self.ok(fresh.1) else { return shown }
        if let old, shown != nil, old.0 == fresh.0 { return shown }
        return await decoded(fresh.0, url, maxPixels) ?? shown
    }

    private static func ok(_ r: URLResponse) -> Bool { (r as? HTTPURLResponse)?.statusCode ?? 200 == 200 }

    private func decoded(_ data: Data, _ url: URL, _ maxPixels: CGFloat) async -> UIImage? {
        let img = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixels: maxPixels) }.value
        if let img { cache.setObject(img, forKey: url as NSURL, cost: Int(img.size.width * img.size.height * img.scale * img.scale * 4)) }
        return img
    }

    /// A downsized, already-decoded picture: drawing it later costs nothing on the main thread.
    private static func decode(_ data: Data, maxPixels: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
