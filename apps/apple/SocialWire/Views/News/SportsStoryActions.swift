import SwiftUI

struct SportsStoryActions: View {
    @Environment(SocialWireAppModel.self) private var appModel
    let item: SportsFeedItem
    @State private var showingQuote = false
    @State private var showingReply = false

    private var entry: EntryDetail {
        var value = item.story.toEntryDetail()
        value.sportsEntities = item.entities
        value.sportsAssociations = item.associations
        return value
    }

    var body: some View {
        ArticleToolbar(entry: entry, showingQuote: $showingQuote, showingReply: $showingReply)
            .sheet(isPresented: $showingQuote) { SportsPostComposer(entry: entry, isQuote: true) }
            .sheet(isPresented: $showingReply) { SportsPostComposer(entry: entry, isQuote: false) }
    }
}
