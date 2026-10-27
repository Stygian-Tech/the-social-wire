import Foundation

/// Downloads public listing metadata once per cache window, never individual cashtags.
/// Unknown, uncertain, stale or unavailable listings produce no chart candidates.
public actor StockTickerResolver {
    public static let shared = StockTickerResolver()
    typealias Loader = @Sendable () async throws -> (nasdaq: Data, other: Data)
    private let loader: Loader
    private let now: @Sendable () -> Date
    private var directory: [String: ResolvedStockTicker] = [:]
    private var expiresAt = Date.distantPast
    private var retryAfter = Date.distantPast
    private struct LoadedDirectory: Sendable {
        let stocks: [String: ResolvedStockTicker]
        let expiresAt: Date
    }
    private var pending: Task<LoadedDirectory?, Never>?
    private static let cacheLifetime: TimeInterval = 6 * 60 * 60
    private static let failureBackoff: TimeInterval = 5 * 60

    public init() {
        loader = Self.downloadDirectories
        now = { Date() }
    }

    init(loader: @escaping Loader, now: @escaping @Sendable () -> Date) {
        self.loader = loader
        self.now = now
    }

    public func resolve(_ candidates: [String]) async -> [ResolvedStockTicker] {
        guard !candidates.isEmpty else { return [] }
        let current = now()
        if current >= expiresAt {
            if let pending {
                guard let loaded = await pending.value else { return [] }
                return Self.select(candidates, from: loaded.stocks)
            }
            guard current >= retryAfter else { return [] }
            let loader = self.loader
            let now = self.now
            let task = Task<LoadedDirectory?, Never> {
                do {
                    let files = try await loader()
                    let date = now()
                    let nasdaq = try StockSymbolDirectory.parseSnapshot(files.nasdaq, format: .nasdaq, now: date)
                    let other = try StockSymbolDirectory.parseSnapshot(files.other, format: .other, now: date)
                    var merged = nasdaq.stocks
                    for (ticker, listing) in other.stocks {
                        if let existing = merged[ticker], existing != listing { return nil }
                        merged[ticker] = listing
                    }
                    let sourceExpiry = min(nasdaq.createdAt, other.createdAt).addingTimeInterval(StockSymbolDirectory.maximumAge)
                    return LoadedDirectory(stocks: merged, expiresAt: min(date.addingTimeInterval(Self.cacheLifetime), sourceExpiry))
                } catch { return nil }
            }
            pending = task
            let loaded = await task.value
            pending = nil
            if let loaded {
                directory = loaded.stocks
                expiresAt = loaded.expiresAt
                retryAfter = .distantPast
            } else {
                directory = [:]
                expiresAt = .distantPast
                retryAfter = now().addingTimeInterval(Self.failureBackoff)
                return []
            }
        }
        return Self.select(candidates, from: directory)
    }

    /// Time until cached classifications expire or a failed download may be retried.
    /// Call after resolving; views should clear their results before the next resolution.
    public func nextRefreshDelay() -> TimeInterval {
        let current = now()
        let next = expiresAt > current ? expiresAt : retryAfter
        return max(1, next.timeIntervalSince(current))
    }

    private static func select(_ candidates: [String], from directory: [String: ResolvedStockTicker]) -> [ResolvedStockTicker] {
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let key = candidate.uppercased()
            guard seen.insert(key).inserted else { return nil }
            return directory[key]
        }
    }

    private static func downloadDirectories() async throws -> (nasdaq: Data, other: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        async let nasdaq = download("nasdaqlisted.txt", session: session)
        async let other = download("otherlisted.txt", session: session)
        return try await (nasdaq, other)
    }

    private static func download(_ filename: String, session: URLSession) async throws -> Data {
        let url = URL(string: "https://www.nasdaqtrader.com/dynamic/SymDir/\(filename)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.expectedContentLength <= 4_000_000 else {
            throw StockSymbolDirectory.InvalidDirectory.malformed
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4_000_000 else { throw StockSymbolDirectory.InvalidDirectory.malformed }
            data.append(byte)
        }
        return data
    }
}
