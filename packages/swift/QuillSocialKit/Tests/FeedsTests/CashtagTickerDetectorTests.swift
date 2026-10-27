import Feeds
import Testing

@Suite("Cashtag Tickers")
struct CashtagTickerDetectorTests {
    @Test("Missing facets link every occurrence with Unicode-safe UTF-8 offsets")
    func addsMissingFacets() {
        let text = "👩🏽‍💻 $aapl 株 $BRK.B $AAPL"
        let facets = CashtagTickerDetector.addingMissingFacets(in: text, to: [])
        #expect(facets.map(\.features) == [[.tag("$AAPL")], [.tag("$BRK.B")], [.tag("$AAPL")]])
        #expect(facets.map { String(decoding: Array(text.utf8)[$0.byteStart..<$0.byteEnd], as: UTF8.self) }
                == ["$aapl", "$BRK.B", "$AAPL"])
        #expect(CashtagTickerDetector.addingMissingFacets(in: text, to: facets) == facets)
    }

    @Test("Existing link, mention and tag facets retain priority over fallback links")
    func preservesExistingFacetPriority() {
        let text = "$AAPL $MSFT $BRK.B $TSLA"
        let existing = [
            TimelineFacet(byteStart: 0, byteEnd: 5, features: [.link(uri: "https://example.com")]),
            TimelineFacet(byteStart: 6, byteEnd: 11, features: [.mention(did: "did:plc:example")]),
            TimelineFacet(byteStart: 12, byteEnd: 18, features: [.tag("BRK.B")])
        ]
        #expect(CashtagTickerDetector.addingMissingFacets(in: text, to: existing) == existing + [
            TimelineFacet(byteStart: 19, byteEnd: 24, features: [.tag("$TSLA")])
        ])
    }

    @Test("Fallback facets exclude currency, URLs, mentions and code")
    func fallbackExclusions() {
        let text = "$100 https://example.com/$AAPL www.example.com/$MSFT @user$GOOG `$META`\n```\n$NVDA\n```\n$BRK.B"
        let facets = CashtagTickerDetector.addingMissingFacets(in: text, to: [])
        #expect(facets.count == 1)
        #expect(facets.first?.features == [.tag("$BRK.B")])
    }

    @Test("Malformed UTF-8 facets do not prevent display fallback")
    func fallbackMalformedOffsets() {
        let text = "👋 $AAPL"
        let malformed = [TimelineFacet(byteStart: 1, byteEnd: 8, features: [.tag("wrong")])]
        let facets = CashtagTickerDetector.addingMissingFacets(in: text, to: malformed)
        #expect(facets == malformed + [TimelineFacet(byteStart: 5, byteEnd: 10, features: [.tag("$AAPL")])])
    }

    @Test("Ticker feed topics require exactly one complete cashtag")
    func tickerFeedTopics() {
        #expect(CashtagTickerDetector.tickerTopic(in: "$aapl") == "AAPL")
        #expect(CashtagTickerDetector.tickerTopic(in: " $brk.b\n") == "BRK.B")
        for topic in ["AAPL", "#AAPL", "$100", "$AAPL $MSFT", "$AAPL news", "`$AAPL`", "$AAPLé", "$BRK.BBB", ""] {
            #expect(CashtagTickerDetector.tickerTopic(in: topic) == nil)
        }
    }

    @Test("Multiple symbols keep first appearance and deduplicate case-insensitively")
    func extractsUniqueSymbols() {
        #expect(CashtagTickerDetector.tickers(in: "$aapl, $MSFT and $AAPL with $brk.b/$BRK.B.") == ["AAPL", "MSFT", "BRK.B"])
    }

    @Test("Currency, hashtags, non-ASCII symbols and fragments are not stock symbols")
    func excludesInvalidSymbols() {
        #expect(CashtagTickerDetector.tickers(in: "$100 $2.50 #AAPL $株 $é $AAPLé word$AAPL $$AAPL $ABCDEFGHIJKLMNOP $BRK.BBB") == [])
    }

    @Test("Symbols in URLs, handles and inline or fenced code are excluded")
    func excludesNonProse() {
        let text = """
        https://example.com/$AAPL www.example.com/$MSFT @someone$TSLA
        `$GOOG` ``$META``
        ```swift
        $NVDA
        ```
        ~~~
        $AMZN
        ~~~
        Watching $BRK.B and $AAPL
        """
        #expect(CashtagTickerDetector.tickers(in: text) == ["BRK.B", "AAPL"])
    }

    @Test("Unfinished code fences do not trigger ticker cards")
    func excludesUnfinishedFence() {
        #expect(CashtagTickerDetector.tickers(in: "$AAPL\n```\n$MSFT") == ["AAPL"])
    }

    @Test("Equal or longer fence closers preserve following Unicode prose", arguments: [
        ("```", "```"), ("```", "````"), ("````", "`````"), ("~~~", "~~~~~")
    ])
    func acceptsLongerFenceClosers(delimiters: (String, String)) {
        let text = "👋 $AAPL\n\(delimiters.0)\n株 $MSFT\n\(delimiters.1)\n👩🏽‍💻 $BRK.B"
        #expect(CashtagTickerDetector.tickers(in: text) == ["AAPL", "BRK.B"])
    }

    @Test("Shorter or different fence delimiters cannot expose code symbols")
    func ignoresNonClosingDelimiters() {
        let text = """
        ````swift
        $AAPL
        ```
        $MSFT
        ~~~~
        $NVDA
        `````
        👋 $BRK.B
        ~~~
        $GOOG
        ```
        $META
        ~~~~
        👩🏽‍💻 $TSLA
        """
        #expect(CashtagTickerDetector.tickers(in: text) == ["BRK.B", "TSLA"])
    }

    @Test("Multiline inline spans require exactly matching backtick runs")
    func excludesMultilineInlineCode() {
        let text = "👋 `$AAPL\n株 $MSFT` $BRK.B\n``$GOOG\n`$META`\n$NVDA`` 👩🏽‍💻 $TSLA"
        #expect(CashtagTickerDetector.tickers(in: text) == ["BRK.B", "TSLA"])
    }

    @Test("Inline delimiters never pair across separate fenced blocks")
    func keepsProseBetweenFences() {
        let text = "```\n$AAPL\n````\n👋 $BRK.B\n````\n$MSFT\n````\n👩🏽‍💻 $TSLA"
        #expect(CashtagTickerDetector.tickers(in: text) == ["BRK.B", "TSLA"])
    }

    @Test("Link and mention facets exclude their rendered labels using UTF-8 offsets")
    func respectsFacets() {
        let text = "👋 $AAPL $MSFT $BRK.B"
        let facets = [
            TimelineFacet(byteStart: 5, byteEnd: 10, features: [.link(uri: "https://example.com")]),
            TimelineFacet(byteStart: 11, byteEnd: 16, features: [.mention(did: "did:plc:example")])
        ]
        #expect(CashtagTickerDetector.tickers(in: text, facets: facets) == ["BRK.B"])
    }

    @Test("Absent, partial or malformed tag facets do not lose valid text symbols")
    func toleratesMalformedFacets() {
        let text = "👋 $brk.b $AAPL"
        let facets = [
            TimelineFacet(byteStart: 5, byteEnd: 9, features: [.tag("$brk")]),
            TimelineFacet(byteStart: -1, byteEnd: 9, features: [.link(uri: "https://example.com")]),
            TimelineFacet(byteStart: 1, byteEnd: 2, features: [.mention(did: "invalid")]),
            TimelineFacet(byteStart: 100, byteEnd: 200, features: [.link(uri: "https://example.com")]),
            TimelineFacet(byteStart: 12, byteEnd: 4, features: [.link(uri: "https://example.com")])
        ]
        #expect(CashtagTickerDetector.tickers(in: text, facets: facets) == ["BRK.B", "AAPL"])
    }
}
