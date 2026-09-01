import SwiftUI

#if canImport(UIKit)
import UIKit

typealias PlatformImage = UIImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(uiImage: platformImage)
    }
}

@MainActor
enum PlatformURLOpener {
    static func open(_ url: URL) {
        UIApplication.shared.open(url)
    }
}
#elseif canImport(AppKit)
import AppKit

typealias PlatformImage = NSImage

extension Image {
    init(platformImage: PlatformImage) {
        self.init(nsImage: platformImage)
    }
}

@MainActor
enum PlatformURLOpener {
    static func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
#endif

extension View {
    @ViewBuilder
    func platformInlineNavigationTitle() -> some View {
#if os(iOS)
        navigationBarTitleDisplayMode(.inline)
#else
        self
#endif
    }

    @ViewBuilder
    func platformLoginTextInputBehavior() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.URL)
#else
        autocorrectionDisabled()
#endif
    }

    @ViewBuilder
    func platformUncapitalizedTextInput() -> some View {
#if os(iOS)
        textInputAutocapitalization(.never)
            .autocorrectionDisabled()
#else
        autocorrectionDisabled()
#endif
    }

    @ViewBuilder
    func platformHideNavigationBar() -> some View {
#if os(iOS)
        toolbarVisibility(.hidden, for: .navigationBar)
#else
        self
#endif
    }
}
