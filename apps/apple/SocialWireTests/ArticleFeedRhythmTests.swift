import Foundation
import Testing
@testable import SocialWire

@Suite("Article feed rhythm")
struct ArticleFeedRhythmTests {
    private func sections(count: Int) -> [ArticleFeedSection<Int>] {
        ArticleFeedRhythm.sections(for: Array(0 ..< count))
    }

    @Test("An empty feed produces no sections")
    func emptyFeed() {
        #expect(sections(count: 0).isEmpty)
    }

    @Test("A full chapter runs lead, grid, then rows")
    func chapterOrder() {
        let chapterLength = 1
            + ArticleFeedRhythm.gridCardsPerChapter
            + ArticleFeedRhythm.rowsPerChapter
        let result = sections(count: chapterLength)

        #expect(result.map(\.style) == [.lead, .grid, .row])
        #expect(result.map(\.items.count) == [
            1,
            ArticleFeedRhythm.gridCardsPerChapter,
            ArticleFeedRhythm.rowsPerChapter
        ])
    }

    @Test("The chapter repeats so a long feed never settles into one texture")
    func chapterRepeats() {
        let chapterLength = 1
            + ArticleFeedRhythm.gridCardsPerChapter
            + ArticleFeedRhythm.rowsPerChapter
        let result = sections(count: chapterLength * 3)

        #expect(result.map(\.style) == [.lead, .grid, .row, .lead, .grid, .row, .lead, .grid, .row])
    }

    @Test("Every article appears exactly once, in feed order")
    func preservesOrderWithoutDuplicates() {
        for count in 1 ... 40 {
            let flattened = sections(count: count).flatMap(\.items)
            #expect(flattened == Array(0 ..< count), "count \(count)")
        }
    }

    @Test("A short feed stops mid-chapter instead of emitting empty sections")
    func partialChapter() {
        let result = sections(count: 3)

        #expect(result.map(\.style) == [.lead, .grid])
        #expect(result.map(\.items.count) == [1, 2])
        #expect(result.allSatisfy { !$0.items.isEmpty })
    }

    @Test("Section identifiers are unique so ForEach can diff them")
    func uniqueIdentifiers() {
        let ids = sections(count: 60).map(\.id)

        #expect(Set(ids).count == ids.count)
    }

    @Test("A full grid band divides evenly by every column count it can resolve to")
    func gridBandDividesEvenly() {
        for columns in 1 ... 3 {
            #expect(ArticleFeedRhythm.gridCardsPerChapter % columns == 0, "\(columns) columns")
        }
    }
}
