import Foundation

struct AppViewEntryListResponse: Codable, Sendable {
    let entries: [EntryListItem]
    let cursor: String?
}

struct AppViewEntryDetailResponse: Codable, Sendable {
    let entry: EntryDetail?
}

struct AppViewUnreadCountsResponse: Codable, Sendable {
    let counts: [String: Int]?
}
