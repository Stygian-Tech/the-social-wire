import Foundation
import UIKit

/// Shared remote image cache with large in-memory retention and URLSession disk backing.
actor ImageCacheService {
    static let shared = ImageCacheService()

    private final class CacheEntry: NSObject {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    private let memoryCache = NSCache<NSString, CacheEntry>()
    private let session: URLSession
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private init() {
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 192 * 1024 * 1024

        let urlCache = URLCache(
            memoryCapacity: 96 * 1024 * 1024,
            diskCapacity: 512 * 1024 * 1024,
            diskPath: "socialwire-image-cache"
        )
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = urlCache
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, maxPixelSize: CGFloat) async -> UIImage? {
        let key = cacheKey(url: url, maxPixelSize: maxPixelSize)
        if let cached = memoryCache.object(forKey: key as NSString)?.image {
            return cached
        }

        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            defer { Task { await self.clearInFlight(key) } }

            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                    return nil
                }
                guard let decoded = Self.decodeImage(data: data, maxPixelSize: maxPixelSize) else {
                    return nil
                }
                let cost = data.count
                memoryCache.setObject(CacheEntry(decoded), forKey: key as NSString, cost: cost)
                return decoded
            } catch {
                return nil
            }
        }

        inFlight[key] = task
        return await task.value
    }

    func prefetch(urls: [URL], maxPixelSize: CGFloat, concurrency: Int = 6) async {
        let unique = Array(Set(urls))
        guard !unique.isEmpty else { return }

        await withTaskGroup(of: Void.self) { group in
            var iterator = unique.makeIterator()
            let initial = min(concurrency, unique.count)
            for _ in 0 ..< initial {
                guard let url = iterator.next() else { break }
                group.addTask {
                    _ = await self.image(for: url, maxPixelSize: maxPixelSize)
                }
            }
            for await _ in group {
                guard let url = iterator.next() else { continue }
                group.addTask {
                    _ = await self.image(for: url, maxPixelSize: maxPixelSize)
                }
            }
        }
    }

    private func clearInFlight(_ key: String) {
        inFlight[key] = nil
    }

    private func cacheKey(url: URL, maxPixelSize: CGFloat) -> String {
        "\(url.absoluteString)|\(Int(maxPixelSize))"
    }

    private static func decodeImage(data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard maxPixelSize > 0 else { return UIImage(data: data) }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else {
            return UIImage(data: data)
        }
        return UIImage(cgImage: cgImage)
    }
}
