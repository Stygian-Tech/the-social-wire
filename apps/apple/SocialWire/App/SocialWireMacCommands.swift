#if os(macOS)
import SwiftUI

struct SocialWireMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: SocialWireAppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Article in New Window") {
                if let entryID = appModel.selectedEntry?.entryId {
                    openWindow(value: entryID)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(appModel.selectedEntry == nil)
        }

        CommandGroup(replacing: .help) {
            Button("The Social Wire Help") {
                guard let url = URL(string: "https://thesocialwire.app") else { return }
                PlatformURLOpener.open(url)
            }
            Button("Send Feedback…") {
                openWindow(id: "feedback")
            }
        }
    }
}
#endif
