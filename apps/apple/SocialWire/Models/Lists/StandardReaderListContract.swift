import CryptoKit
import Foundation

enum StandardReaderListContract {
    static let collection = "app.standard-reader.list"
    static let saveCollection = "app.standard-reader.listSave"

    static func recordURI(_ input: String, collection: String = collection) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^at://did:[a-z]+:[A-Za-z0-9._:%-]+/"# + NSRegularExpression.escapedPattern(for: collection) + #"/[A-Za-z0-9._~:-]{1,512}$"#
        return value.range(of: pattern, options: .regularExpression) == nil ? nil : value
    }

    static func saveKey(_ uri: String) throws -> String {
        guard let canonical = recordURI(uri) else { throw SocialWireError.invalidATURI }
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func shareURL(_ uri: String) -> URL? {
        guard let canonical = recordURI(uri) else { return nil }
        let pieces = canonical.dropFirst(5).split(separator: "/")
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%:")
        guard let did = String(pieces[0]).addingPercentEncoding(withAllowedCharacters: allowed),
              let key = String(pieces[2]).addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "https://standard-reader.app/l/\(did)/\(key)")
    }

    static func makeRecord(name: String, description: String, publications: [String], users: [String]) throws -> StandardReaderListRecord {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title.count <= 64, title.utf8.count <= 640,
              detail.count <= 300, detail.utf8.count <= 3000,
              publications.count <= 500, users.count <= 500,
              publications.allSatisfy({ recordURI($0, collection: "site.standard.publication") == $0 }),
              users.allSatisfy({ $0.range(of: #"^did:[a-z]+:[A-Za-z0-9._:%-]+$"#, options: .regularExpression) != nil }) else {
            throw SocialWireError.badResponse("Enter a list name of up to 64 characters, a description of up to 300 characters, and valid publication or author references.")
        }
        return StandardReaderListRecord(name: title, description: detail.isEmpty ? nil : detail,
            publications: publications, users: users.isEmpty ? nil : users, createdAt: DateFormatters.string())
    }
}
