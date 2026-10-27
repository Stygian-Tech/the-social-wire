#if os(iOS)
import ATProtoCore
import Feeds
import Foundation
import Observation

@MainActor
@Observable
final class ThreadPositionStore {
    private let source: any PostThreadSource
    private var positions: [String: (position: Int, total: Int)] = [:]
    private var loadingRootURIs: Set<String> = []
    private var loadedRootURIs: Set<String> = []
    private var retryAfter: [String: Date] = [:]
    private let now: () -> Date
    private let failureBackoff: TimeInterval = 30

    init(source: any PostThreadSource, now: @escaping () -> Date = { .now }) {
        self.source = source
        self.now = now
    }

    func position(for postURI: String) -> (position: Int, total: Int)? {
        positions[postURI]
    }

    func load(for post: TimelinePost) async {
        guard post.replyCount > 0 || post.replyRootURI != nil else { return }

        let rootURI = post.replyRootURI ?? post.uri
        guard !loadedRootURIs.contains(rootURI),
              retryAfter[rootURI].map({ now() >= $0 }) ?? true,
              let uri = try? ATURI(rootURI),
              loadingRootURIs.insert(rootURI).inserted
        else { return }

        defer { loadingRootURIs.remove(rootURI) }

        do {
            let thread = try await source.thread(uri: uri)
            try Task.checkCancellation()
            retryAfter[rootURI] = nil
            guard let root = thread.entries.first(where: { $0.post.uri == rootURI }) else {
                loadedRootURIs.insert(rootURI)
                return
            }

            for entry in thread.entries {
                positions[entry.post.uri] = nil
            }

            var authoredThread: [ThreadEntry] = []
            var chainContinuesAtDepth: [Int: Bool] = [:]
            for entry in thread.entries {
                let continuesChain: Bool
                if entry.post.uri == root.post.uri {
                    continuesChain = true
                } else {
                    continuesChain = entry.depth > root.depth
                        && chainContinuesAtDepth[entry.depth - 1] == true
                        && entry.post.author.did == root.post.author.did
                        && entry.replyingTo?.did == root.post.author.did
                }
                chainContinuesAtDepth[entry.depth] = continuesChain
                chainContinuesAtDepth = chainContinuesAtDepth.filter { $0.key <= entry.depth }
                if continuesChain { authoredThread.append(entry) }
            }
            let total = authoredThread.count
            guard total > 1 else {
                loadedRootURIs.insert(rootURI)
                return
            }

            for (index, entry) in authoredThread.enumerated() {
                positions[entry.post.uri] = (position: index + 1, total: total)
            }
            loadedRootURIs.insert(rootURI)
        } catch is CancellationError {
        } catch {
            retryAfter[rootURI] = now().addingTimeInterval(failureBackoff)
        }
    }
}

#endif
