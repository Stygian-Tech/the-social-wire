import CryptoKit
import Foundation

enum DeterministicKeys {
    static func entryReadStateRKey(subjectURI: String) -> String {
        let digest = SHA256.hash(data: Data(subjectURI.utf8))
        return String(Base32.encode(Data(digest)).prefix(52)).lowercased()
    }

    static func latrFingerprint(normalizedURL: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedURL.lowercased().utf8))
        return Data(digest).map { String(format: "%02x", $0) }.joined()
    }

    static func latrExternalRKey(normalizedURL: String) -> String {
        String(Base32.encode(Data(SHA256.hash(data: Data(normalizedURL.lowercased().utf8)))).prefix(52)).lowercased()
    }

    static func latrItemRKey(subjectURI: String) -> String {
        String(Base32.encode(Data(SHA256.hash(data: Data(subjectURI.utf8)))).prefix(52)).lowercased()
    }

    static func generateTID(date: Date = Date()) -> String {
        let millis = UInt64(date.timeIntervalSince1970 * 1000)
        var bytes = withUnsafeBytes(of: millis.bigEndian, Array.init)
        bytes.append(UInt8.random(in: 0...255))
        return String(Base32.encode(Data(bytes)).prefix(13)).lowercased()
    }
}
