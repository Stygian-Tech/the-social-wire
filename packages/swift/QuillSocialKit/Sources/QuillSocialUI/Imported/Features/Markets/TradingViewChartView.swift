#if os(iOS)
import SwiftUI

struct TradingViewChartView: View {
    static let height: CGFloat = 220
    let configuration: TradingViewChartConfiguration
    @State private var loadState = TradingViewLoadState.loading
    @State private var retryID = 0

    var body: some View {
        ZStack {
            if loadState != .failed {
                TradingViewWebView(configuration: configuration, loadState: $loadState)
                    .id(retryID)
            }
            if loadState == .loading {
                ProgressView("Loading Chart")
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 12))
                    .allowsHitTesting(false)
            } else if loadState == .failed {
                VStack(spacing: 12) {
                    Image(systemName: "chart.xyaxis.line")
                    Text("The chart couldn’t load.")
                        .foregroundStyle(.secondary)
                    Button("Retry") {
                        loadState = .loading
                        retryID += 1
                    }
                    Link("Open in TradingView", destination: configuration.chartURL)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
            }
        }
        .frame(height: Self.height)
        .sensoryFeedback(.selection, trigger: retryID)
        .onChange(of: configuration) { _, _ in loadState = .loading }
    }
}

#endif
