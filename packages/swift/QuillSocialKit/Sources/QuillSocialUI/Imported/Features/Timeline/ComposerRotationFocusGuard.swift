#if os(iOS)
import SwiftUI
import UIKit

/// Release iOS 18 text focus before sheet rotation, before SwiftUI size-class updates.
struct ComposerRotationFocusGuard: UIViewControllerRepresentable {
    let onTransition: () -> Void

    func makeUIViewController(context: Context) -> Controller {
        let controller = Controller()
        controller.onTransition = onTransition
        return controller
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.onTransition = onTransition
    }

    final class Controller: UIViewController {
        var onTransition: (() -> Void)?

        override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) {
            onTransition?()
            view.window?.endEditing(true)
            super.viewWillTransition(to: size, with: coordinator)
        }
    }
}
#endif
