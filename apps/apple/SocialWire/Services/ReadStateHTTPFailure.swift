import Foundation
import ReadStateCore

enum ReadStateHTTPFailure {
    static func checkGatewayCode(_ data: Data, statusCode: Int) throws {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if statusCode == 409, body?["error"] as? String == "ReadStateMigrationScopeConflict" {
            throw ReadStateSyncFailure.migrationScopeConflict
        }
        if statusCode == 503, body?["error"] as? String == "ReadStateNotReady" {
            throw ReadStateSyncFailure.projectionNotReady
        }
    }

    static func check(_ data: Data, response: HTTPURLResponse, now: Date = Date()) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        try checkGatewayCode(data, statusCode: response.statusCode)
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if response.statusCode == 409 || body?["error"] as? String == "InvalidSwap" {
            throw ReadStateSyncFailure.conflict
        }
        if response.statusCode == 429 {
            var until = now.addingTimeInterval(60)
            if let value = response.value(forHTTPHeaderField: "Retry-After") {
                if let seconds = Double(value), seconds.isFinite { until = now.addingTimeInterval(max(1, seconds)) }
                else {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                    if let date = formatter.date(from: value) { until = max(now.addingTimeInterval(1), date) }
                }
            }
            if let reset = response.value(forHTTPHeaderField: "RateLimit-Reset").flatMap(Double.init), reset.isFinite {
                until = max(until, Date(timeIntervalSince1970: reset))
            }
            throw ReadStateSyncFailure.rateLimited(until: until)
        }
        if [401, 403].contains(response.statusCode) {
            throw ReadStateSyncFailure.reauthorizationRequired
        }
        throw SocialWireError.badResponse("Read history sync failed (\(response.statusCode)). Pending changes remain on this device.")
    }
}
