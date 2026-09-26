import Foundation

struct ReadStatePutRecordRequest: Encodable {
    let repo: String
    let collection: String
    let rkey: String
    let record: AnyEncodable
    let swapRecord: String?

    enum CodingKeys: String, CodingKey { case repo, collection, rkey, record, swapRecord }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(repo, forKey: .repo)
        try container.encode(collection, forKey: .collection)
        try container.encode(rkey, forKey: .rkey)
        try container.encode(record, forKey: .record)
        if let swapRecord { try container.encode(swapRecord, forKey: .swapRecord) }
        else { try container.encodeNil(forKey: .swapRecord) }
    }
}
