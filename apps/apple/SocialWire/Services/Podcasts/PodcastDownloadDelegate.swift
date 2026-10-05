import Foundation

/// URLSession invokes these callbacks outside the UI actor. Each callback transfers
/// only immutable task identifiers, progress values, and a stable file URL.
final class PodcastDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let finished: @Sendable (Int, URL?, String?) -> Void
    let progressed: @Sendable (Int, Double) -> Void

    init(finished: @escaping @Sendable (Int, URL?, String?) -> Void, progressed: @escaping @Sendable (Int, Double) -> Void) {
        self.finished = finished
        self.progressed = progressed
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
#if os(iOS)
        guard let identifier = session.configuration.identifier else { return }
        Task { @MainActor in PodcastBackgroundEvents.finish(identifier: identifier) }
#endif
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            finished(downloadTask.taskIdentifier, nil, "Download Failed")
            return
        }
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            finished(downloadTask.taskIdentifier, stable, nil)
        } catch { finished(downloadTask.taskIdentifier, nil, error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progressed(downloadTask.taskIdentifier, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error { finished(task.taskIdentifier, nil, error.localizedDescription) }
    }
}
