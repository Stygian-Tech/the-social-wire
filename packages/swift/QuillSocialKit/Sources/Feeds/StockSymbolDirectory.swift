import Foundation

/// Parses only positively identified common/ordinary equities and depositary receipts.
/// A directory also contains funds, debt and derivatives, so membership alone is insufficient.
enum StockSymbolDirectory {
    enum Format: Sendable { case nasdaq, other }
    enum InvalidDirectory: Error { case malformed, stale }
    static let maximumAge: TimeInterval = 4 * 24 * 60 * 60

    struct Snapshot: Sendable {
        let stocks: [String: ResolvedStockTicker]
        let createdAt: Date
    }

    static func parse(_ data: Data, format: Format, now: Date) throws -> [String: ResolvedStockTicker] {
        try parseSnapshot(data, format: format, now: now).stocks
    }

    static func parseSnapshot(_ data: Data, format: Format, now: Date) throws -> Snapshot {
        guard !data.isEmpty, data.count <= 4_000_000,
              let text = String(data: data, encoding: .utf8) else { throw InvalidDirectory.malformed }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        let expectedHeader: String
        switch format {
        case .nasdaq: expectedHeader = "Symbol|Security Name|Market Category|Test Issue|Financial Status|Round Lot Size|ETF|NextShares"
        case .other: expectedHeader = "ACT Symbol|Security Name|Exchange|CQS Symbol|ETF|Round Lot Size|Test Issue|NASDAQ Symbol"
        }
        guard lines.count >= 3, lines.first == expectedHeader,
              let footer = lines.last, footer.hasPrefix("File Creation Time: ") else { throw InvalidDirectory.malformed }
        let footerFields = footer.components(separatedBy: "|")
        let footerCount = format == .nasdaq ? 8 : 7
        guard footerFields.count == footerCount, footerFields.dropFirst().allSatisfy(\.isEmpty) else { throw InvalidDirectory.malformed }
        let timestamp = String(footerFields[0].dropFirst("File Creation Time: ".count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/New_York")
        formatter.dateFormat = "MMddyyyyHH:mm"
        formatter.isLenient = false
        guard timestamp.count == 13, let created = formatter.date(from: timestamp),
              formatter.string(from: created) == timestamp else { throw InvalidDirectory.malformed }
        guard now.timeIntervalSince(created) <= maximumAge,
              created.timeIntervalSince(now) <= 60 * 60 else { throw InvalidDirectory.stale }
        var stocks: [String: ResolvedStockTicker] = [:]
        for line in lines.dropFirst().dropLast() {
            let fields = line.components(separatedBy: "|")
            guard fields.count == 8, !fields[0].isEmpty, !fields[1].isEmpty else { throw InvalidDirectory.malformed }
            let ticker: String
            let exchange: String
            switch format {
            case .nasdaq:
                guard ["Y", "N"].contains(fields[3]), ["Y", "N"].contains(fields[6]),
                      ["Y", "N"].contains(fields[7]) else { throw InvalidDirectory.malformed }
                guard fields[3] == "N", fields[6] == "N", fields[7] == "N" else { continue }
                ticker = fields[0]; exchange = "NASDAQ"
            case .other:
                guard ["Y", "N"].contains(fields[4]), ["Y", "N"].contains(fields[6]) else { throw InvalidDirectory.malformed }
                guard fields[4] == "N", fields[6] == "N" else { continue }
                switch fields[2] {
                case "N": exchange = "NYSE"
                case "A": exchange = "AMEX"
                default: continue
                }
                ticker = fields[3]
            }
            guard validTicker(ticker), isCommonEquity(fields[1]) else { continue }
            let listing = ResolvedStockTicker(ticker: ticker, tradingViewSymbol: "\(exchange):\(ticker)")
            if let previous = stocks[ticker], previous != listing { throw InvalidDirectory.malformed }
            stocks[ticker] = listing
        }
        guard !stocks.isEmpty else { throw InvalidDirectory.malformed }
        return Snapshot(stocks: stocks, createdAt: created)
    }

    private static func validTicker(_ ticker: String) -> Bool {
        ticker.range(of: #"^[A-Z][A-Z0-9]{0,14}(?:\.[A-Z]{1,2})?\z"#, options: .regularExpression) != nil
    }

    private static func isCommonEquity(_ securityName: String) -> Bool {
        let name = securityName.lowercased()
        // Exclude descriptions containing ordinary-share language as part of a derivative.
        let excluded = #"\b(warrants?|rights?|units?|notes?|bonds?|debentures?|preferred|preference|fund|etf|etn|nextshares)\b"#
        guard name.range(of: excluded, options: .regularExpression) == nil else { return false }
        let equity = #"\b(common (stock|shares?)|ordinary (stock|shares?)|capital stock|american deposit[ao]ry (shares?|receipts?)|adrs?|ads)\b"#
        return name.range(of: equity, options: .regularExpression) != nil
    }
}
