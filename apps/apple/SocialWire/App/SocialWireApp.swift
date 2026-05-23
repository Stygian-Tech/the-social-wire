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
        WindowGroup {
            RootView()
                .environment(appModel)
                .modelContainer(Self.readerModelContainer)
                .tint(.indigo)
                .onOpenURL { url in
                    Task { await appModel.handleOAuthCallback(url) }
                }
        }
    }
}
