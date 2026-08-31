import SwiftUI
import SwiftData

@main
struct SocialWireApp: App {
    @State private var appModel = SocialWireAppModel()

    private static let readerModelContainer: ModelContainer = {
        do {
            return try ReaderSwiftDataStack.makeReaderContainer()
        } catch {
            fatalError("Reader SwiftData container failed: \(error)")
        }
    }()

    var body: some Scene {
#if os(macOS)
        WindowGroup {
            mainContent
        }
        .commands {
            SocialWireMacCommands(appModel: appModel)
        }

        WindowGroup("Article", for: String.self) { $entryID in
            NavigationStack {
                if let entryID,
                   let entry = appModel.selectedEntry,
                   entry.entryId == entryID {
                    EntryDetailView(entry: entry)
                } else {
                    ContentUnavailableView("Article Unavailable", systemImage: "doc.text")
                }
            }
            .environment(appModel)
            .modelContainer(Self.readerModelContainer)
            .appAppearance()
            .frame(minWidth: 620, minHeight: 520)
        }

        Window("Feedback", id: "feedback") {
            NavigationStack {
                UserInputFeedbackView()
            }
            .environment(appModel)
            .modelContainer(Self.readerModelContainer)
            .appAppearance()
            .frame(minWidth: 520, minHeight: 560)
        }

        Settings {
            NavigationStack {
                SettingsView(showsDoneButton: false)
            }
            .environment(appModel)
            .modelContainer(Self.readerModelContainer)
            .appAppearance()
            .frame(minWidth: 520, minHeight: 420)
        }
#else
        WindowGroup {
            mainContent
        }
#endif
    }

    private var mainContent: some View {
        RootView()
            .environment(appModel)
            .modelContainer(Self.readerModelContainer)
            .tint(.indigo)
            .appAppearance()
            .onOpenURL { url in
                Task { await appModel.handleOAuthCallback(url) }
            }
    }
}
