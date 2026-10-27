#if os(iOS)
import SwiftUI

/// Each row draws to its own edges so lazy loading never requires the next avatar to be mounted.
struct ThreadAvatarConnector: Shape {
    let avatarFrame: CGRect
    let connectsAbove: Bool
    let connectsBelow: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            if connectsAbove {
                path.move(to: CGPoint(x: avatarFrame.midX, y: rect.minY))
                path.addLine(to: CGPoint(x: avatarFrame.midX, y: avatarFrame.minY))
            }
            if connectsBelow {
                path.move(to: CGPoint(x: avatarFrame.midX, y: avatarFrame.maxY))
                path.addLine(to: CGPoint(x: avatarFrame.midX, y: rect.maxY))
            }
        }
    }
}

#endif
