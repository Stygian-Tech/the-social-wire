import Foundation
import ReadStateCore

@MainActor
final class StandardReaderListPDSService {
    private let xrpc: XRPCClient
    init(xrpc: XRPCClient) { self.xrpc = xrpc }
    private func assertViewer(_ viewer: String) async throws {
        guard try await xrpc.currentDID() == viewer else { throw ReadStateSyncFailure.accountChanged }
    }
    private func saves(viewer: String) async throws -> [RepoRecord<StandardReaderListSaveRecord>] {
        var records: [RepoRecord<StandardReaderListSaveRecord>] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            try await assertViewer(viewer)
            let page: ListRecordsResponse<StandardReaderListSaveRecord> = try await xrpc.listRecords(
                repo: viewer, collection: StandardReaderListContract.saveCollection, cursor: cursor, authorized: true)
            records += page.records.filter {
                StandardReaderListContract.recordURI($0.uri, collection: StandardReaderListContract.saveCollection) == $0.uri && $0.uri.hasPrefix("at://\(viewer)/")
            }
            cursor = page.cursor
            if let cursor, !seen.insert(cursor).inserted || seen.count > 100 {
                throw SocialWireError.badResponse("List saves could not be read completely.")
            }
        } while cursor != nil
        try await assertViewer(viewer)
        return records
    }
    func save(_ uri: String, viewer: String) async throws {
        guard let list = StandardReaderListContract.recordURI(uri) else { throw SocialWireError.invalidATURI }
        if try await saves(viewer: viewer).contains(where: { $0.value.type == StandardReaderListContract.saveCollection && $0.value.list == list }) { return }
        try await xrpc.putRecord(collection: StandardReaderListContract.saveCollection,
            rkey: StandardReaderListContract.saveKey(list),
            record: StandardReaderListSaveRecord(list: list, createdAt: DateFormatters.string()), expectedViewer: viewer)
        try await assertViewer(viewer)
    }
    func remove(_ uri: String, viewer: String) async throws {
        guard let list = StandardReaderListContract.recordURI(uri) else { throw SocialWireError.invalidATURI }
        let records = try await saves(viewer: viewer).filter { $0.value.list == list }
        for record in records {
            guard let key = record.uri.split(separator: "/").last else { continue }
            try await xrpc.deleteRecord(collection: StandardReaderListContract.saveCollection, rkey: String(key), expectedViewer: viewer)
        }
        try await assertViewer(viewer)
    }
    func create(_ record: StandardReaderListRecord, viewer: String) async throws -> StandardReaderList {
        try await assertViewer(viewer)
        let uri = try await xrpc.createRecord(collection: StandardReaderListContract.collection, record: record, expectedViewer: viewer)
        try await assertViewer(viewer)
        guard StandardReaderListContract.recordURI(uri) == uri, uri.hasPrefix("at://\(viewer)/") else {
            throw SocialWireError.badResponse("The PDS returned an invalid list reference. Refresh Lists before trying again.")
        }
        return StandardReaderList(uri: uri, name: record.name, description: record.description, creatorDid: viewer,
            publications: record.publications, users: record.users ?? [], owned: true, saved: false)
    }
    func delete(_ uri: String, viewer: String) async throws {
        guard StandardReaderListContract.recordURI(uri) == uri, uri.hasPrefix("at://\(viewer)/"), let key = uri.split(separator: "/").last else {
            throw SocialWireError.badResponse("Only a list created by your signed-in account can be deleted.")
        }
        try await xrpc.deleteRecord(collection: StandardReaderListContract.collection, rkey: String(key), expectedViewer: viewer)
    }
}
