#if os(iOS)
import UIKit

@MainActor
final class PodcastBackgroundEvents: NSObject, UIApplicationDelegate {
    private static var completionHandlers: [String: () -> Void] = [:]

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        Self.completionHandlers[identifier] = completionHandler
    }

    static func finish(identifier: String) {
        completionHandlers.removeValue(forKey: identifier)?()
    }
}
#endif
