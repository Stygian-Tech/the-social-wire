import Testing
@testable import SocialWire

@Suite("Web sidebar tool parity")
struct NewsSidebarToolTests {
    @Test("Native sidebar preserves the web tool names and order")
    func webToolOrder() {
        #expect(NewsSidebarTool.allCases.map(\.title) == [
            "Articles", "Live Post", "Livestream", "Brand Accounts", "Content Calendar", "Analytics"
        ])
        #expect(Set(NewsSidebarTool.allCases.map(\.id)).count == 6)
    }

    @Test("Unreleased Pro tools are hidden from the native sidebar")
    func unreleasedToolsHidden() {
        #expect(!SocialWireAPIEnvironment.proFeaturesReleased)
        #expect(NewsSidebarTool.availableTools.isEmpty)
    }
}
