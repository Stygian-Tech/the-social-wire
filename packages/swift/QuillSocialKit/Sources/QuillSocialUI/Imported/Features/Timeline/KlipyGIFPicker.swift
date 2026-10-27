#if os(iOS)
import SwiftUI

struct KlipyGIFPicker: View {
    let selection: (KlipyGIF) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [KlipyGIF] = []
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        NavigationStack {
            Group {
                if apiKey == nil {
                    ContentUnavailableView {
                        Label("GIF Search Unavailable", systemImage: "photo")
                    } description: {
                        Text("GIF search is not available right now. You can still attach photos from your library.")
                    }
                } else if results.isEmpty, isLoading {
                    ProgressView("Loading GIFs")
                } else if results.isEmpty, didFail {
                    ContentUnavailableView("GIFs Unavailable", systemImage: "wifi.exclamationmark")
                } else {
                    ScrollView {
                        LazyVGrid(columns: [.init(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                            ForEach(results) { gif in
                                Button {
                                    selection(gif)
                                } label: {
                                    FeedMediaViewport(aspectRatio: 1, cornerRadius: 12) {
                                        AnimatedImageView(url: gif.previewURL)
                                    }
                                    .background(.quaternary, in: .rect(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(gif.description.isEmpty ? gif.title : gif.description)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("Powered by KLIPY")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search KLIPY")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await load()
        }
    }

    private var apiKey: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "KLIPY_API_KEY") as? String,
              !value.isEmpty,
              !value.hasPrefix("$(") else { return nil }
        return value
    }

    private func load() async {
        guard let apiKey else { return }
        isLoading = true
        didFail = false
        defer { isLoading = false }

        var components = URLComponents(string: query.isEmpty
            ? "https://api.klipy.com/v2/featured"
            : "https://api.klipy.com/v2/search")
        components?.queryItems = [
            URLQueryItem(name: "key", value: apiKey),
            URLQueryItem(name: "q", value: query.isEmpty ? nil : query),
            URLQueryItem(name: "media_filter", value: "tinygif,gif"),
            URLQueryItem(name: "contentfilter", value: "medium"),
            URLQueryItem(name: "limit", value: "30"),
        ].filter { $0.value != nil }
        guard let url = components?.url else { return }

        do {
            var request = URLRequest(url: url)
            request.setValue("The Social Wire/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let payload = try JSONDecoder().decode(Response.self, from: data)
            results = payload.results.compactMap(\.gif)
        } catch is CancellationError {
        } catch {
            didFail = true
        }
    }
}

private extension KlipyGIFPicker {
    struct Response: Decodable {
        let results: [Item]
    }

    struct Item: Decodable {
        let id: String
        let title: String
        let contentDescription: String?
        let mediaFormats: [String: Media]

        enum CodingKeys: String, CodingKey {
            case id, title
            case contentDescription = "content_description"
            case mediaFormats = "media_formats"
        }

        var gif: KlipyGIF? {
            guard let full = mediaFormats["gif"] ?? mediaFormats["tinygif"] else { return nil }
            return KlipyGIF(
                id: id,
                title: title,
                description: contentDescription ?? title,
                url: full.url,
                previewURL: mediaFormats["tinygif"]?.url ?? full.url,
                width: full.dims?.first,
                height: full.dims?.count == 2 ? full.dims?[1] : nil
            )
        }
    }

    struct Media: Decodable {
        let url: URL
        let dims: [Int]?
    }
}

#endif
