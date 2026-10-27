#if os(iOS)
import UIKit

enum ComposerImageProcessor {
    // app.bsky.embed.images defines the maximum image blob size as 2,000,000 bytes.
    // com.atproto.server.describeServer does not advertise a server-specific override.
    static let maximumByteCount = 2_000_000
    private static let maximumDimension = 4_000.0

    static func prepare(_ data: Data, mimeType: String) -> (data: Data, mimeType: String)? {
        guard let original = UIImage(data: data) else { return nil }
        // Re-encoding a GIF through UIImage would silently discard its animation.
        if mimeType.lowercased() == "image/gif" {
            return data.count <= maximumByteCount ? (data, mimeType) : nil
        }
        let largestDimension = pixelDimensions(of: original).largest
        if data.count <= maximumByteCount, largestDimension <= maximumDimension {
            return (data, mimeType)
        }

        var image = resizedImage(original, maximumDimension: maximumDimension)
        for quality in stride(from: 0.9, through: 0.3, by: -0.1) {
            if let encoded = image.jpegData(compressionQuality: quality),
               encoded.count <= maximumByteCount {
                return (encoded, "image/jpeg")
            }
        }

        while true {
            let largestDimension = pixelDimensions(of: image).largest
            guard largestDimension > 800 else { break }
            let nextMaximumDimension = largestDimension * 0.8
            image = resizedImage(image, maximumDimension: nextMaximumDimension)
            if let encoded = image.jpegData(compressionQuality: 0.72),
               encoded.count <= maximumByteCount {
                return (encoded, "image/jpeg")
            }
        }
        return nil
    }

    private static func resizedImage(_ image: UIImage, maximumDimension: CGFloat) -> UIImage {
        let dimensions = pixelDimensions(of: image)
        guard dimensions.largest > maximumDimension else { return image }
        let scale = maximumDimension / dimensions.largest
        let size = CGSize(width: dimensions.width * scale, height: dimensions.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func pixelDimensions(of image: UIImage) -> (width: CGFloat, height: CGFloat, largest: CGFloat) {
        let width = CGFloat(image.cgImage?.width ?? Int(image.size.width * image.scale))
        let height = CGFloat(image.cgImage?.height ?? Int(image.size.height * image.scale))
        return (width, height, max(width, height))
    }
}

#endif
