import SwiftUI

struct SportsStoryActions: View {
    let item: SportsFeedItem

    private var entry: EntryDetail {
        var value = item.story.toEntryDetail()
        value.sportsEntities = item.entities
        value.sportsAssociations = item.associations
        return value
    }

    var body: some View {
        ArticleToolbar(entry: entry)
    }
}
