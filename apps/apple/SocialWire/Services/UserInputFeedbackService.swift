import Foundation

@MainActor
final class UserInputFeedbackService {
    static let boardURL = URL(
        string: "https://userinput.app/s/did:plc:qy5pluw2bsuq2x6albsgkvx3/3mrzw42so4j2h?lang=en"
    )!
    static let boardAPIURL = URL(
        string: "https://userinput.app/api/board/did:plc:qy5pluw2bsuq2x6albsgkvx3/3mrzw42so4j2h"
    )!
    static let boardURI = "at://did:plc:qy5pluw2bsuq2x6albsgkvx3/app.userinput.space/3mrzw42so4j2h"
    static let discussionCollection = "app.userinput.discussion"
    static let upvoteCollection = "app.userinput.upvote"
    static let maximumPhotoCount = 4

    private let auth: ATProtoOAuthService
    private let xrpc: XRPCClient

    init(auth: ATProtoOAuthService, xrpc: XRPCClient) {
        self.auth = auth
        self.xrpc = xrpc
    }

    func fetchBoardReference() async throws -> UserInputBoardReference {
        var request = URLRequest(url: Self.boardAPIURL)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw UserInputFeedbackError.boardUnavailable
        }
        let payload = try JSONDecoder().decode(BoardEnvelope.self, from: data)
        guard let board = payload.board,
              board.uri == Self.boardURI,
              let cid = board.cid,
              !cid.isEmpty
        else {
            throw UserInputFeedbackError.invalidBoard
        }
        return UserInputBoardReference(
            strongRef: StrongRef(uri: board.uri, cid: cid),
            tags: board.value?.tags ?? []
        )
    }

    func submit(
        _ input: UserInputFeedbackInput,
        board: UserInputBoardReference,
        progress: @escaping @MainActor (UserInputSubmissionProgress) -> Void
    ) async throws -> URL {
        let trimmedTitle = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { throw UserInputFeedbackError.missingTitle }
        let photos = Array(input.photos.prefix(Self.maximumPhotoCount))
        let session = try await auth.validSession()
        try Self.requirePermissions(scope: session.scope, photoMimeTypes: photos.map(\.mimeType))

        var images: [DiscussionImage] = []
        for (index, photo) in photos.enumerated() {
            progress(.uploadingPhoto(completed: index, total: photos.count))
            let blob = try await xrpc.uploadBlob(data: photo.data, mimeType: photo.mimeType)
            images.append(DiscussionImage(image: blob, alt: photo.name))
            progress(.uploadingPhoto(completed: index + 1, total: photos.count))
        }

        progress(.posting)
        let trimmedBody = input.body?.trimmingCharacters(in: .whitespacesAndNewlines)
        let createdAt = DateFormatters.string()
        let discussion = DiscussionRecord(
            type: Self.discussionCollection,
            space: board.strongRef,
            title: trimmedTitle,
            body: trimmedBody?.isEmpty == false ? trimmedBody : nil,
            tags: input.tags.isEmpty ? nil : input.tags,
            images: images.isEmpty ? nil : images,
            createdAt: createdAt
        )
        let reference = try await xrpc.createRecordReference(
            collection: Self.discussionCollection,
            record: discussion
        )

        let upvote = UpvoteRecord(
            type: Self.upvoteCollection,
            subject: reference,
            createdAt: createdAt
        )
        try? await xrpc.putRecord(
            collection: Self.upvoteCollection,
            rkey: rkey(from: reference.uri),
            record: upvote
        )

        return Self.discussionURL(uri: reference.uri) ?? Self.boardURL
    }

    static func discussionURL(uri: String) -> URL? {
        let prefix = "at://"
        guard uri.hasPrefix(prefix) else { return nil }
        let components = String(uri.dropFirst(prefix.count)).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[1] == Substring(Self.discussionCollection),
              !components[0].isEmpty,
              !components[2].isEmpty
        else { return nil }
        let pathSegmentCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let did = String(components[0]).addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters),
              let rkey = String(components[2]).addingPercentEncoding(withAllowedCharacters: pathSegmentCharacters)
        else { return nil }
        return URL(string: "https://userinput.app/d/\(did)/\(rkey)?lang=en")
    }

    static func requirePermissions(scope: String?, photoMimeTypes: [String]) throws {
        let tokens = (scope ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let hasUserInputPermission = tokens.contains { token in
            scopeName(token) == "include:app.userinput.authFull"
                || repoScope(token, allows: discussionCollection, action: "create")
        }
        let photosAllowed = photoMimeTypes.allSatisfy { mimeType in
            tokens.contains { blobScope($0, allows: mimeType) }
        }
        guard hasUserInputPermission, photosAllowed else {
            throw UserInputFeedbackError.reauthorizationRequired
        }
    }

    private static func scopeName(_ token: String) -> String {
        String(token.split(separator: "?", maxSplits: 1).first ?? Substring(token))
    }

    private static func repoScope(_ token: String, allows collection: String, action: String) -> Bool {
        let parts = token.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let query = parts.count > 1 ? String(parts[1]) : ""
        let items = URLComponents(string: "https://scope.invalid/?\(query)")?.queryItems ?? []
        let collections = items.filter { $0.name == "collection" }.compactMap(\.value)
        let actions = items.filter { $0.name == "action" }.compactMap(\.value)
        let collectionAllowed = name == "repo:\(collection)"
            || name == "repo:*"
            || (name == "repo" && collections.contains { $0 == collection || $0 == "*" })
        return collectionAllowed && (actions.isEmpty || actions.contains(action))
    }

    private static func blobScope(_ token: String, allows mimeType: String) -> Bool {
        let parts = token.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let name = String(parts[0])
        let patterns: [String]
        if name.hasPrefix("blob:") {
            patterns = [String(name.dropFirst("blob:".count))]
        } else if name == "blob", parts.count > 1 {
            let query = String(parts[1])
            patterns = URLComponents(string: "https://scope.invalid/?\(query)")?.queryItems?
                .filter { $0.name == "accept" }
                .compactMap(\.value) ?? []
        } else {
            patterns = []
        }

        let mime = mimeType.split(separator: "/", maxSplits: 1).map(String.init)
        guard mime.count == 2 else { return false }
        return patterns.contains { pattern in
            let parts = pattern.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return false }
            return (parts[0] == "*" || parts[0] == mime[0])
                && (parts[1] == "*" || parts[1] == mime[1])
        }
    }
}

enum UserInputFeedbackError: LocalizedError, Equatable {
    case boardUnavailable
    case invalidBoard
    case missingTitle
    case reauthorizationRequired

    var errorDescription: String? {
        switch self {
        case .boardUnavailable:
            "The feedback board is unavailable right now. Try again shortly."
        case .invalidBoard:
            "The feedback board returned an invalid response."
        case .missingTitle:
            "Add a title before sending feedback."
        case .reauthorizationRequired:
            "Your session does not include feedback or photo permissions yet. Log out and sign back in, then try again."
        }
    }
}

private struct BoardEnvelope: Decodable {
    let board: BoardDTO?
}

private struct BoardDTO: Decodable {
    let uri: String
    let cid: String?
    let value: BoardValueDTO?
}

private struct BoardValueDTO: Decodable {
    let tags: [UserInputTag]?
}

private struct DiscussionRecord: Encodable {
    let type: String
    let space: StrongRef
    let title: String
    let body: String?
    let tags: [String]?
    let images: [DiscussionImage]?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case space
        case title
        case body
        case tags
        case images
        case createdAt
    }
}

private struct DiscussionImage: Encodable {
    let image: ATProtoBlob
    let alt: String
}

private struct UpvoteRecord: Encodable {
    let type: String
    let subject: StrongRef
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case type = "$type"
        case subject
        case createdAt
    }
}
