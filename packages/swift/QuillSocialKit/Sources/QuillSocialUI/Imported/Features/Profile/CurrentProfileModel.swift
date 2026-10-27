#if os(iOS)
import Observation
import UIKit

@MainActor
@Observable
final class CurrentProfileModel {
    typealias Loader = @Sendable () async throws -> Data?

    private let loader: Loader
    private(set) var avatarImage: UIImage?
    private var hasLoaded = false

    init(loader: @escaping Loader) {
        self.loader = loader
    }

    func load() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard
            let data = try? await loader(),
            let source = UIImage(data: data)
        else { return }

        avatarImage = Self.squareThumbnail(source)
    }

    private static func squareThumbnail(_ source: UIImage) -> UIImage {
        let targetSize = CGSize(width: 24, height: 24)
        let scale = max(targetSize.width / source.size.width, targetSize.height / source.size.height)
        let scaledSize = CGSize(width: source.size.width * scale, height: source.size.height * scale)
        let origin = CGPoint(
            x: (targetSize.width - scaledSize.width) / 2,
            y: (targetSize.height - scaledSize.height) / 2
        )

        let image = UIGraphicsImageRenderer(size: targetSize).image { context in
            context.cgContext.addEllipse(in: CGRect(origin: .zero, size: targetSize))
            context.cgContext.clip()
            source.draw(in: CGRect(origin: origin, size: scaledSize))
        }
        return image.withRenderingMode(.alwaysOriginal)
    }
}

#endif
