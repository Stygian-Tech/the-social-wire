import Testing
@testable import Navigation

@Suite struct LayoutTierTests {
    @Test func compactWidthIsAlwaysCompact() {
        #expect(LayoutTier(isHorizontallyRegular: false, width: 466) == .compact) // iPhone Duo outer display
        #expect(LayoutTier(isHorizontallyRegular: false, width: 1200) == .compact)
    }

    @Test func iPhoneDuoInnerDisplayIsRegular() {
        #expect(LayoutTier(isHorizontallyRegular: true, width: 669) == .regular)
        #expect(LayoutTier(isHorizontallyRegular: true, width: 951) == .wide) // inner display rotated
    }

    @Test func iPadSizes() {
        #expect(LayoutTier(isHorizontallyRegular: true, width: 834) == .regular) // 11" portrait
        #expect(LayoutTier(isHorizontallyRegular: true, width: 1366) == .wide) // 13" landscape
    }

    @Test func ordering() {
        #expect(LayoutTier.compact < .regular && LayoutTier.regular < .wide)
        #expect(!LayoutTier.compact.showsSplitColumns && LayoutTier.regular.showsSplitColumns)
        #expect(!LayoutTier.compact.prefersSidebarTabs)
        #expect(LayoutTier.regular.prefersSidebarTabs)
        #expect(LayoutTier.wide.prefersSidebarTabs)
    }
}
