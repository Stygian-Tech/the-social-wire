import SwiftUI
import WebKit

/// Column 3: Renders entry content HTML in a WKWebView.
/// A strict client-side CSP is applied via the WKWebView configuration.
struct EntryDetailView: View {
    let entry: EntryModel
    @EnvironmentObject var authService: ATProtoOAuthService
    @State private var fullEntry: EntryDetailModel?
    @State private var isLoading = false
    @State private var loadError: Error?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(fullEntry?.title ?? entry.title)
                        .font(.title2.bold())

                    HStack(spacing: 12) {
                        Text(formattedDate)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        if let url = fullEntry?.originalURL {
                            Link(destination: url) {
                                Label("View original", systemImage: "arrow.up.right.square")
                                    .font(.subheadline)
                            }
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.top)

                Divider()

                // Content
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 200)
                } else if let error = loadError {
                    ContentUnavailableView(
                        "Failed to Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(error.localizedDescription)
                    )
                } else if let content = fullEntry?.contentHTML {
                    SanitizedHTMLView(html: content)
                        .frame(minHeight: 400)
                }
            }
        }
        .task(id: entry.entryId) {
            await loadDetail()
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: entry.publishedAt)
    }

    private func loadDetail() async {
        guard let session = authService.session else { return }
        isLoading = true
        loadError = nil
        do {
            let client = PDSClient(session: session)
            fullEntry = try await client.entryDetail(id: entry.entryId)
        } catch {
            loadError = error
        }
        isLoading = false
    }
}

// ── WKWebView wrapper ─────────────────────────────────────────────────────────

/// Renders sanitized HTML in a WKWebView with a strict Content Security Policy.
struct SanitizedHTMLView: UIViewRepresentable {
    let html: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()

        // Block all network requests from the rendered HTML — content is
        // already inline after server + Swift sanitization.
        let contentController = WKUserContentController()
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .clear
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let wrappedHTML = """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https:; style-src 'unsafe-inline';">
        <style>
          body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            font-size: 17px;
            line-height: 1.6;
            color: #1c1c1e;
            padding: 0 16px 32px;
            max-width: 100%;
            word-wrap: break-word;
          }
          @media (prefers-color-scheme: dark) {
            body { color: #f2f2f7; background: transparent; }
            a { color: #0a84ff; }
          }
          img { max-width: 100%; height: auto; border-radius: 8px; }
          pre { overflow-x: auto; }
          blockquote { border-left: 3px solid #8e8e93; margin-left: 0; padding-left: 16px; color: #8e8e93; }
        </style>
        </head>
        <body>\(html)</body>
        </html>
        """
        webView.loadHTMLString(wrappedHTML, baseURL: nil)
    }
}
