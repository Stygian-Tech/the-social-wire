import Foundation

struct SampleMedia: Identifiable, Sendable {
    let id: Int
    let name: String
    let caption: String
    var photoSource: String { ["Grain", "Flashes", "Bluesky", "Spark"][id % 4] }
    var videoSource: String { id.isMultiple(of: 2) ? "Spark" : "Bluesky" }
    var storySource: String { id.isMultiple(of: 2) ? "Spark" : "Grain" }
    static let all: [SampleMedia] = zip(
        ["Maya Chen", "Alex Rivera", "Sofia Laurent", "Jules Park", "Nora Woods", "Leo Martin", "Isabel Cruz", "Arlo James"],
        ["A little further from the everyday.", "Worth the early start.", "Take the scenic route.", "A moment by the water.", "Morning, at its own pace.", "Somewhere with no signal.", "The sky stayed like this for hours.", "Postcards from a slow weekend."]
    ).enumerated().map { SampleMedia(id: $0.offset, name: $0.element.0, caption: $0.element.1) }
}
