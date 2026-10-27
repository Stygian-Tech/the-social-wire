#if os(iOS)
import SwiftUI
import UIKit

struct ProfileTabIcon: View {
    let avatarImage: UIImage?

    var body: some View {
        if let avatarImage {
            Image(uiImage: avatarImage)
                .clipShape(.circle)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "person.crop.circle")
                .accessibilityHidden(true)
        }
    }
}

#endif
