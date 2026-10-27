import Foundation
@testable import Feeds
import Testing

@Suite("Verified US Stock Tickers")
struct StockTickerResolverTests {
    static let date = Date(timeIntervalSince1970: 1_790_815_800) // Oct 1, 2026, 02:10 UTC
    static let nasdaqHeader = "Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares"
    static let otherHeader = "ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol"
    static let footer = "File Creation Time: 0930202621:31|||||||"
    static func file(_ header: String, _ rows: [String], footer: String = footer) -> Data {
        let footer = header == otherHeader ? String(footer.dropLast()) : footer
        return Data(([header] + rows + [footer]).joined(separator: "\r\n").utf8)
    }
    static let nasdaq = file(nasdaqHeader, ["AAPL|Apple Inc. - Common Stock|Q|N|N|100|N|N"])
    static let other = file(otherHeader, ["BRK.B|Berkshire Hathaway Common Stock|N|BRK.B|N|100|N|BRK.B"])

    @Test("Directory verifies stock identity and exchange without punctuation guessing")
    func identities() throws {
        let rows = [
            "BRK.B|Berkshire Common Stock|N|BRK.B|N|100|N|BRK.B",
            "ADR|Issuer American Depositary Shares|N|ADR|N|100|N|ADR",
            "COMMON|Issuer Common Shares|A|COMMON|N|100|N|COMMON",
            "CLASS|Issuer Ordinary Shares|N|CLASS|N|100|N|CLASS",
            "UNKNOWN|Unclassified Company|N|UNKNOWN|N|100|N|UNKNOWN",
            "OTHER|Issuer Common Stock|Z|OTHER|N|100|N|OTHER"
        ]
        let stocks = try StockSymbolDirectory.parse(Self.file(Self.otherHeader, rows), format: .other, now: Self.date)
        #expect(stocks["BRK.B"]?.tradingViewSymbol == "NYSE:BRK.B")
        #expect(stocks["COMMON"]?.tradingViewSymbol == "AMEX:COMMON")
        #expect(stocks["ADR"] != nil && stocks["CLASS"] != nil)
        #expect(stocks["BRKB"] == nil && stocks["UNKNOWN"] == nil && stocks["OTHER"] == nil)
    }

    @Test("Capital stock resolves to a verified Nasdaq equity")
    func capitalStock() throws {
        let file = Self.file(Self.nasdaqHeader, ["GOOG|Alphabet Inc. - Class C Capital Stock|Q|N|N|100|N|N"])
        let stocks = try StockSymbolDirectory.parse(file, format: .nasdaq, now: Self.date)
        #expect(stocks["GOOG"]?.tradingViewSymbol == "NASDAQ:GOOG")
    }

    @Test("Funds, tests, derivative descriptions and debt cannot qualify as stocks")
    func exclusions() throws {
        let names = ["Units each containing Common Stock", "Warrants for Ordinary Shares", "Rights to Common Shares", "Senior Notes", "Preferred Stock", "Bond", "Common Stock Fund", "NextShares", "Exchange traded ETN"]
        var rows = names.enumerated().map { index, name in "X\(index)|\(name)|Q|N|N|100|N|N" }
        rows += ["AAPL|Apple Common Stock|Q|N|N|100|N|N", "ETF|Common Stock|Q|N|N|100|Y|N", "TEST|Common Stock|Q|Y|N|100|N|N", "NEXT|Common Stock|Q|N|N|100|N|Y"]
        let stocks = try StockSymbolDirectory.parse(Self.file(Self.nasdaqHeader, rows), format: .nasdaq, now: Self.date)
        #expect(Set(stocks.keys) == ["AAPL"])
    }

    @Test("Malformed, truncated, oversized and stale directories fail closed")
    func integrity() {
        let badFiles = [
            Data("<html>Error</html>".utf8),
            Self.file("Wrong Header", ["AAPL|Apple Common Stock|Q|N|N|100|N|N"]),
            Self.file(Self.nasdaqHeader, ["Bad|Row"]),
            Self.file(Self.nasdaqHeader, ["AAPL|Apple Common Stock|Q|N|N|100|N|N"], footer: "File Creation Time: 0920202621:31|||||||"),
            Self.file(Self.nasdaqHeader, ["AAPL|Apple Common Stock|Q|N|N|100|N|N"], footer: "File Creation Time: 1002202621:31|||||||"),
            Self.file(Self.nasdaqHeader, ["AAPL|Apple Common Stock|Q|N|N|100|N|N"], footer: "File Creation Time: 0930202621:31||||||"),
            Data(repeating: 65, count: 4_000_001)
        ]
        for data in badFiles {
            #expect(throws: (any Error).self) { try StockSymbolDirectory.parse(data, format: .nasdaq, now: Self.date) }
        }
    }

    @Test("Fresh Friday metadata remains usable over a closed-market weekend")
    func weekend() throws {
        let friday = Self.file(Self.nasdaqHeader, ["AAPL|Apple Common Stock|Q|N|N|100|N|N"], footer: "File Creation Time: 0925202621:31|||||||")
        let formatter = ISO8601DateFormatter()
        let sunday = try #require(formatter.date(from: "2026-09-27T16:00:00Z"))
        #expect(try StockSymbolDirectory.parse(friday, format: .nasdaq, now: sunday)["AAPL"] != nil)
    }

    @Test("Concurrent and repeated requests share one load and preserve candidate order")
    func sharedLoad() async {
        let loader = FixtureLoader()
        let resolver = StockTickerResolver(loader: { try await loader.load() }, now: { Self.date })
        async let first = resolver.resolve(["brk.b", "AAPL", "INVALID", "BRK.B"])
        async let second = resolver.resolve(["AAPL"])
        let results = await (first, second)
        #expect(results.0.map(\.ticker) == ["BRK.B", "AAPL"])
        #expect(results.1.first?.tradingViewSymbol == "NASDAQ:AAPL")
        #expect(await resolver.resolve(["BRKB", "INVALID"]) == [])
        #expect(await loader.count == 1)
    }

    @Test("Failures back off, expired entries never fall back, and recovery refreshes")
    func expiryAndFailure() async {
        let clock = FixtureClock(Self.date)
        let loader = FixtureLoader()
        let resolver = StockTickerResolver(loader: { try await loader.load() }, now: { clock.date })
        #expect(await resolver.resolve(["AAPL"]).count == 1)
        #expect(await resolver.nextRefreshDelay() == 6 * 60 * 60)
        clock.advance(6 * 60 * 60)
        await loader.setFailure(true)
        #expect(await resolver.resolve(["AAPL"]) == [])
        #expect(await resolver.resolve(["AAPL"]) == [])
        #expect(await loader.count == 2)
        #expect(await resolver.nextRefreshDelay() == 5 * 60)
        clock.advance(60)
        #expect(await resolver.nextRefreshDelay() == 4 * 60)
        clock.advance(4 * 60)
        await loader.setFailure(false)
        #expect(await resolver.resolve(["AAPL"]).count == 1)
        #expect(await loader.count == 3)
    }

    @Test("Cache cannot extend the source freshness limit")
    func sourceExpiry() async throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-05T01:30:59Z"))
        let clock = FixtureClock(date)
        let loader = FixtureLoader()
        let resolver = StockTickerResolver(loader: { try await loader.load() }, now: { clock.date })
        #expect(await resolver.resolve(["AAPL"]).count == 1)
        #expect(await resolver.nextRefreshDelay() == 1)
        clock.advance(2)
        #expect(await resolver.nextRefreshDelay() == 1)
        #expect(await resolver.resolve(["AAPL"]) == [])
        #expect(await resolver.nextRefreshDelay() == 300)
        #expect(await loader.count == 2)
    }

    @Test("A broken second directory suppresses both exchanges")
    func atomicDirectory() async {
        let resolver = StockTickerResolver(loader: { (Self.nasdaq, Data("Bad".utf8)) }, now: { Self.date })
        #expect(await resolver.resolve(["AAPL", "BRK.B"]) == [])
    }
}

private actor FixtureLoader {
    var count = 0
    var failure = false
    func setFailure(_ failure: Bool) { self.failure = failure }
    func load() throws -> (nasdaq: Data, other: Data) {
        count += 1
        if failure { throw URLError(.notConnectedToInternet) }
        return (StockTickerResolverTests.nasdaq, StockTickerResolverTests.other)
    }
}

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var date: Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}
