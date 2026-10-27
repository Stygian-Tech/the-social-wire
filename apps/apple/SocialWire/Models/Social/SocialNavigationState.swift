import Foundation
import Observation
#if os(iOS)
import QuillSocialUI
#endif

/// Scene-owned routes survive workspace reconstruction without crossing account boundaries.
@MainActor
@Observable
final class SocialNavigationState {
    private var viewerDID: String?
    private var paths: [SocialDestination: [SocialRoute]] = [:]
    private(set) var contextID = UUID()
    #if os(iOS)
    let quill = QuillSocialNavigation()
    #endif

    func bind(viewerDID: String?) {
        guard self.viewerDID != viewerDID else { return }
        self.viewerDID = viewerDID
        #if os(iOS)
        quill.bind(viewerDID: viewerDID)
        #endif
        paths.removeAll()
        contextID = UUID()
    }

    func showHome() {
        paths[.timeline] = []
        #if os(iOS)
        quill.showHome()
        #endif
    }

    func showProfile(viewerDID: String) {
        bind(viewerDID: viewerDID)
        paths[.timeline] = [.profile(did: viewerDID)]
        #if os(iOS)
        quill.showProfile(actor: viewerDID)
        #endif
    }

    func path(for destination: SocialDestination) -> [SocialRoute] {
        paths[destination, default: []]
    }

    func setPath(_ path: [SocialRoute], for destination: SocialDestination, contextID: UUID) {
        guard self.contextID == contextID else { return }
        paths[destination] = path
    }
}
