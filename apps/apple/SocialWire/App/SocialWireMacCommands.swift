#if os(macOS)
import SwiftUI

struct SocialWireMacCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let appModel: SocialWireAppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open RSS Story in New Window") {
                if let entryID = appModel.selectedEntry?.entryId,
                   EntryOpenTargetResolver.isRSSEntry(entryID) {
                    openWindow(value: entryID)
                }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(
                appModel.selectedEntry.map {
                    !EntryOpenTargetResolver.isRSSEntry($0.entryId)
                } ?? true
            )
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
