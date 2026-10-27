import ATProtoCore
import Foundation
import Testing
@testable import Navigation

@Suite struct TabNavigationStateTests {
    @Test func tabOrderPlacesChatBeforeNotifications() {
        #expect(AppTab.allCases == [.home, .search, .chat, .notifications, .profile])
    }

    let thread = Route.thread(try! ATURI("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l3qo2vutsw2b"))
    let profile = Route.profile(try! ActorIdentifier("bsky.app"))
    let likes = Route.likedBy(try! ATURI("at://did:plc:z72i7hdynmk6r22z27h6tvur/app.bsky.feed.post/3l3qo2vutsw2b"))

    @Test func compactStackBecomesSelectionPlusDetailWhenUnfolding() {
        var state = TabNavigationState()
        state.select(thread) // tap a post in the timeline on the outer display
        state.push(profile)
        state.push(likes)
        // Unfold: split layout reads the same path.
        #expect(state.selection == thread)
        #expect(state.detailPath == [profile, likes])
        // Fold again: compact stack is unchanged.
        #expect(state.path == [thread, profile, likes])
    }

    @Test func choosingANewListRowReplacesTheDetailStack() {
        var state = TabNavigationState(path: [thread, profile])
        state.selection = likes
        #expect(state.path == [likes])
        state.selection = nil
        #expect(state.path.isEmpty)
    }

    @Test func detailStackEditsKeepTheSelection() {
        var state = TabNavigationState(path: [thread, profile, likes])
        state.detailPath = [profile] // back button in the detail column
        #expect(state.path == [thread, profile])
        state.detailPath = []
        #expect(state.path == [thread])
    }

    @Test func detailEditWithoutSelectionBecomesThePath() {
        var state = TabNavigationState()
        state.detailPath = [profile]
        #expect(state.path == [profile])
    }

    @Test func navigationStateRoundTripsThroughJSON() throws {
        var state = NavigationState()
        state[.home].select(thread)
        state[.home].push(profile)
        state.selectedTab = .search
        let decoded = try JSONDecoder().decode(NavigationState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        #expect(decoded[.home].path == [thread, profile])
    }

    @Test func conversationsOpenInTheChatTab() {
        var state = NavigationState(selectedTab: .home)
        state.open(.conversation(id: "3kabc"))
        #expect(state.selectedTab == .chat)
        #expect(state[.chat].path == [.conversation(id: "3kabc")])
        state.selectedTab = .home
        state.open(profile)
        #expect(state[.home].path == [profile])
    }

    @Test func reselectingATabPopsToRoot() {
        var state = NavigationState(selectedTab: .home)
        state[.home].select(thread)
        state.reselect(.search)
        #expect(state.selectedTab == .search && state[.home].path == [thread])
        state.reselect(.home)
        state.reselect(.home)
        #expect(state[.home].path.isEmpty)
    }
}
