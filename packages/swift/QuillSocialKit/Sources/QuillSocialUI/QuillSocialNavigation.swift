#if os(iOS)
import ATProtoCore
import Observation
import Foundation

/// Scene-owned navigation, independent of the shared account's feed data.
@MainActor
@Observable
public final class QuillSocialNavigation {
    private var viewerDID: String?
    @ObservationIgnored private var stacks: [QuillSocialDestination: RouteStack] = [:]
    private var contextID = UUID()

    public init() {}

    public func bind(viewerDID: String?) {
        guard self.viewerDID != viewerDID else { return }
        self.viewerDID = viewerDID
        stacks = [:]
        contextID = UUID()
    }

    public func showHome() {
        stack(for: .timeline).popToRoot()
    }

    /// Avatar shortcuts always use the shared Social profile route.
    public func showProfile(actor: String) {
        guard let identifier = try? ActorIdentifier(actor) else { return }
        stack(for: .timeline).path = [.profile(identifier)]
    }

    func stack(for destination: QuillSocialDestination) -> RouteStack {
        _ = contextID
        if let stack = stacks[destination] { return stack }
        let stack = RouteStack()
        stacks[destination] = stack
        return stack
    }
}
#endif
