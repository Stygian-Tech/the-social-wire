import CryptoKit
import Foundation

/// Deterministic ATProto record keys aligned with upstream L@tr (`latr-kit` / `latr-packages`).
enum DeterministicKeys {
    static func entryReadStateRKey(subjectURI: String) -> String {
        digestKey(for: subjectURI)
    }

    static func latrFingerprint(normalizedURL: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedURL.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func latrExternalRKey(normalizedURL: String) -> String {
        digestKey(for: normalizedURL)
    }

    static func latrItemRKey(subjectURI: String) -> String {
        digestKey(for: subjectURI)
    }

    static func generateTID(date: Date = Date()) -> String {
        let millis = UInt64(date.timeIntervalSince1970 * 1000)
        var bytes = withUnsafeBytes(of: millis.bigEndian, Array.init)
        bytes.append(UInt8.random(in: 0...255))
        return String(Base32.encode(Data(bytes)).prefix(13))
    }

    /// Legacy Social Wire iOS keys: lowercase 52-char base32 prefix with lowercased URL input for externals.
    static func legacyIOSLatrExternalRKey(normalizedURL: String) -> String {
        legacyIOSDigestKey(for: normalizedURL.lowercased())
    }

    /// Legacy Social Wire iOS keys: lowercase 52-char base32 prefix.
    static func legacyIOSLatrItemRKey(subjectURI: String) -> String {
        legacyIOSDigestKey(for: subjectURI)
    }

    /// Legacy Social Wire iOS / gateway hex read-state keys before base32 parity.
    static func legacyHexEntryReadStateRKey(subjectURI: String) -> String {
        let digest = SHA256.hash(data: Data(subjectURI.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func digestKey(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return Base32.encode(Data(digest))
    }

    private static func legacyIOSDigestKey(for text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        let encoded = legacyLowerBase32Encode(Data(digest))
        return String(encoded.prefix(52)).lowercased()
    }

    private static func legacyLowerBase32Encode(_ data: Data) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
        var output = ""
        var buffer = 0
        var bitsLeft = 0

        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bitsLeft += 8
            while bitsLeft >= 5 {
                let index = (buffer >> (bitsLeft - 5)) & 0x1f
                output.append(alphabet[index])
                bitsLeft -= 5
            }
        }

        if bitsLeft > 0 {
            let index = (buffer << (5 - bitsLeft)) & 0x1f
            output.append(alphabet[index])
        }

        return output
    }
}
