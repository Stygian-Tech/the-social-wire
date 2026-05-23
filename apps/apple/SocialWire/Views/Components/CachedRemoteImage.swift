import SwiftUI

struct CachedRemoteImage<Placeholder: View>: View {
    let urls: [URL]
    let maxPixelSize: CGFloat
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var loadedImage: UIImage?

    private var loadToken: String {
        urls.map(\.absoluteString).joined(separator: "|")
    }

    var body: some View {
        Group {
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
            } else {
                placeholder()
            }
        }
        .task(id: loadToken) {
            loadedImage = nil
            for url in urls {
                if let image = await ImageCacheService.shared.image(for: url, maxPixelSize: maxPixelSize) {
                    loadedImage = image
                    return
                }
            }
        }
    }
}
