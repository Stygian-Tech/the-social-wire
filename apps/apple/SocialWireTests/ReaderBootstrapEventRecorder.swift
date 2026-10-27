import Foundation
@testable import SocialWire

actor ReaderBootstrapEventRecorder {
    private(set) var kinds: [BootstrapStreamEventKind] = []

    func appendAfterYield(_ kind: BootstrapStreamEventKind) async {
        await Task.yield()
        kinds.append(kind)
    }
}
