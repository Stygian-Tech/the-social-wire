import Testing
@testable import SocialWire

@Suite("Native Section Navigation")
struct NewsRootSectionTests {
    @Test("The native tab bar and sidebar share four ordered destinations")
    func sections() {
        #expect(NewsRootSection.allCases == [.readLater, .feeds, .topics, .lists])
        #expect(NewsRootSection(rawValue: "social") == nil)
        #expect(NewsRootSection(rawValue: "media") == nil)
    }
}
