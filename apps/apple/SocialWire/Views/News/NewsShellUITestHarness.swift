#if DEBUG
import SwiftUI

/// Deterministic shell used only by UI automation so navigation chrome can be tested without live OAuth.
struct NewsShellUITestHarness: View {
    @State private var selectedTab = NewsTab.wire

    var body: some View {
        VStack(spacing: 0) {
#if os(macOS)
            HStack {
                ForEach(NewsTab.allCases) { tab in
                    Button(tab.title) {
                        selectedTab = tab
                    }
                    .accessibilityIdentifier("news-tab-button-\(tab.rawValue)")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()
#endif
            adaptiveTabs
        }
    }

    private var adaptiveTabs: some View {
        TabView(selection: $selectedTab) {
            ForEach(NewsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    NavigationStack {
                        Text(tab.title)
                            .font(.largeTitle.bold())
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityIdentifier("news-tab-content-\(tab.rawValue)")
                            .navigationTitle(tab.title)
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
    }
}
#endif
