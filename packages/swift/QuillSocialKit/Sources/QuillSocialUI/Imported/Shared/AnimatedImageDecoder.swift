#if os(iOS)
import Foundation
import ImageIO

/// Serializes image decoding away from the UI executor and bounds retained frames.
actor AnimatedImageDecoder {
    struct Frame: Sendable {
        let image: CGImage
        let duration: TimeInterval
    }

    struct Result: Sendable {
        let frames: [Frame]
        var duration: TimeInterval { frames.reduce(0) { $0 + $1.duration } }
    }

    struct Policy: Sendable {
        var maximumEncodedBytes = 20 * 1_024 * 1_024
        var maximumDecodedBytes = 24 * 1_024 * 1_024
        var maximumFrames = 60
        var maximumPixelSize = 1_600
    }

    enum DecodeError: Error {
        case tooLarge
        case invalidImage
    }

    static let shared = AnimatedImageDecoder()

    func load(_ source: AnimatedImageSource, firstFrameOnly: Bool) async throws -> Result {
        let policy = Policy()
        let data: Data
        switch source {
        case let .bytes(bytes):
            data = bytes
        case let .remote(url):
            let (bytes, response) = try await URLSession.shared.bytes(from: url)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                throw URLError(.badServerResponse)
            }
            guard response.expectedContentLength <= policy.maximumEncodedBytes else {
                throw DecodeError.tooLarge
            }
            var downloaded = Data()
            var buffer: [UInt8] = []
            buffer.reserveCapacity(65_536)
            for try await byte in bytes {
                if downloaded.count + buffer.count >= policy.maximumEncodedBytes { throw DecodeError.tooLarge }
                buffer.append(byte)
                if buffer.count == 65_536 {
                    try Task.checkCancellation()
                    downloaded.append(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            downloaded.append(contentsOf: buffer)
            data = downloaded
        }
        try Task.checkCancellation()
        return try Self.decode(data, firstFrameOnly: firstFrameOnly, policy: policy)
    }

    /// Pure synchronous work; production calls it on the decoder actor, never the UI actor.
    nonisolated static func decode(
        _ data: Data,
        firstFrameOnly: Bool = false,
        policy: Policy = Policy()
    ) throws -> Result {
        try Task.checkCancellation()
        guard data.count <= policy.maximumEncodedBytes else { throw DecodeError.tooLarge }
        guard policy.maximumFrames > 0, policy.maximumPixelSize > 0,
              policy.maximumDecodedBytes > 0,
              let source = CGImageSourceCreateWithData(data as CFData, [
                  kCGImageSourceShouldCache: false,
              ] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else { throw DecodeError.invalidImage }
        let count = CGImageSourceGetCount(source)
        let frameCount = firstFrameOnly ? 1 : min(count, policy.maximumFrames)
        // Reserve room for every retained frame before decoding. Eight bytes per pixel
        // and row padding also cover higher-depth source images without caching originals.
        let perFrameBudget = policy.maximumDecodedBytes / frameCount
        let budgetPixelSize = Int((sqrt(4_096 + 32 * Double(perFrameBudget)) - 64) / 16)
        guard budgetPixelSize > 0 else { throw DecodeError.tooLarge }
        let pixelSize = min(policy.maximumPixelSize, budgetPixelSize)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelSize,
        ]
        var frames: [Frame] = []
        frames.reserveCapacity(frameCount)
        var decodedBytes = 0
        for retainedIndex in 0..<frameCount {
            try Task.checkCancellation()
            // Distribute samples over the complete animation instead of keeping only
            // its beginning. Each sample carries the durations of the skipped frames.
            let index = firstFrameOnly ? 0 : retainedIndex * count / frameCount
            let nextIndex = firstFrameOnly ? 1 : (retainedIndex + 1) * count / frameCount
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                throw DecodeError.invalidImage
            }
            let (frameBytes, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
            guard !overflow, frameBytes <= policy.maximumDecodedBytes - decodedBytes else {
                throw DecodeError.tooLarge
            }
            decodedBytes += frameBytes
            var duration: TimeInterval = 0
            for durationIndex in index..<nextIndex {
                try Task.checkCancellation()
                duration += frameDuration(source: source, index: durationIndex)
            }
            frames.append(Frame(image: image, duration: duration))
        }
        return Result(frames: frames)
    }

    nonisolated private static func frameDuration(source: CGImageSource, index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else { return 0.1 }
        let duration = gif[kCGImagePropertyGIFUnclampedDelayTime] as? TimeInterval
            ?? gif[kCGImagePropertyGIFDelayTime] as? TimeInterval
            ?? 0.1
        return duration.isFinite ? max(duration, 0.02) : 0.1
    }
}

#endif
