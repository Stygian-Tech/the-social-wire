import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// File transfer avoids loading a complete podcast into memory for Files or the share sheet.
struct PodcastAudioFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .audio) { file in
            SentTransferredFile(file.url, allowAccessingOriginalFile: true)
        }
    }
}
