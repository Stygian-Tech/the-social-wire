import Foundation

actor ReaderBootstrapRequests {
    private var pending: [ReaderBootstrapURLProtocol] = []

    func receive(_ request: ReaderBootstrapURLProtocol) {
        pending.append(request)
    }

    func completeNext(body: String) async {
        while pending.isEmpty { await Task.yield() }
        pending.removeFirst().complete(body: body)
    }

    func waitForRequest() async {
        while pending.isEmpty { await Task.yield() }
    }
}
