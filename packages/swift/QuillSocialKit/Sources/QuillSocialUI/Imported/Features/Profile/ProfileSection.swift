#if os(iOS)
import Foundation

enum ProfileSection: String, CaseIterable, Identifiable {
    case posts = "Posts"
    case publications = "Publications"
    case replies = "Replies"
    case media = "Media"
    case likes = "Likes"
    case reviews = "Reviews"
    case reading = "Reading"
    case semble = "Semble"
    case lists = "Lists"
    case starterPacks = "Starter Packs"

    var id: Self { self }
}

#endif
