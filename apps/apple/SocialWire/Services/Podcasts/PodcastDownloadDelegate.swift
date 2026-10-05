import Foundation

/// URLSession invokes these callbacks outside the UI actor. Each callback transfers
/// only immutable task identifiers, progress values, and a stable file URL.
final class PodcastDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let finished: @Sendable (Int, URL?, HTTPURLResponse?, String?) -> Void
    let progressed: @Sendable (Int, Double) -> Void

    init(finished: @escaping @Sendable (Int, URL?, HTTPURLResponse?, String?) -> Void, progressed: @escaping @Sendable (Int, Double) -> Void) {
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
            finished(downloadTask.taskIdentifier, nil, downloadTask.response as? HTTPURLResponse, "Download Failed. Try Again.")
            return
        }
        let stable = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: stable)
            finished(downloadTask.taskIdentifier, stable, response, nil)
        } catch { finished(downloadTask.taskIdentifier, nil, response, "Could Not Store Download. Check Available Device Storage.") }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let maximum: Int64 = 2 * 1024 * 1024 * 1024
        if totalBytesWritten > maximum || totalBytesExpectedToWrite > maximum {
            finished(downloadTask.taskIdentifier, nil, downloadTask.response as? HTTPURLResponse, "This Episode Exceeds the 2 GB Download Limit.")
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        progressed(downloadTask.taskIdentifier, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if error != nil { finished(task.taskIdentifier, nil, task.response as? HTTPURLResponse, "Download Interrupted. Check Your Connection and Available Device Storage, Then Retry.") }
    }
}
