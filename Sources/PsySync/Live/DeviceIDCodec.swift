import CryptoKit
import Foundation

/// Syncthing device ID encoding (upstream lib/protocol/deviceid.go):
/// base32(sha256(certificate DER)) without padding → 52 chars → four groups
/// of 13, each followed by a Luhn-mod-32 check char → 56 chars → 8 groups of 7
/// joined by '-'.
///
/// Used to derive the ID for a stored identity without a running bridge and to
/// validate IDs locally. User input is parsed by the App's `DeviceIDParser`
/// (Luhn-32 check, no bridge call).
public enum DeviceIDCodec {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    public enum CodecError: Error, Hashable, Sendable {
        case invalidPEM
    }

    public static func deviceID(certificateDER: Data) -> DeviceID {
        deviceID(sha256: Data(SHA256.hash(data: certificateDER)))
    }

    public static func deviceID(certificatePEM: Data) throws -> DeviceID {
        deviceID(certificateDER: try derFromPEM(certificatePEM, type: "CERTIFICATE"))
    }

    /// Encodes 32 raw bytes as a canonical device ID.
    public static func deviceID(sha256 digest: Data) -> DeviceID {
        precondition(digest.count == 32)
        let base = base32(digest)                    // 52 chars
        var withCheck = ""
        var idx = base.startIndex
        for _ in 0..<4 {
            let end = base.index(idx, offsetBy: 13)
            let group = String(base[idx..<end])
            withCheck += group + String(luhn32(group))
            idx = end
        }
        var groups: [String] = []
        var j = withCheck.startIndex
        while j < withCheck.endIndex {
            let end = withCheck.index(j, offsetBy: 7)
            groups.append(String(withCheck[j..<end]))
            j = end
        }
        return DeviceID(rawValue: groups.joined(separator: "-"))
    }

    /// True for a canonical ID with valid check characters.
    public static func isValid(_ raw: String) -> Bool {
        let chars = raw.replacingOccurrences(of: "-", with: "")
        guard chars.count == 56, chars.allSatisfy({ alphabet.contains($0) }) else { return false }
        var idx = chars.startIndex
        for _ in 0..<4 {
            let end = chars.index(idx, offsetBy: 13)
            let group = String(chars[idx..<end])
            guard chars[end] == luhn32(group) else { return false }
            idx = chars.index(after: end)
        }
        return true
    }

    /// Random valid-looking ID (tests: a device that never comes online).
    public static func random() -> DeviceID {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return deviceID(sha256: Data(bytes))
    }

    static func base32(_ data: Data) -> String {
        var out = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return out
    }

    static func luhn32(_ s: String) -> Character {
        var factor = 1
        var sum = 0
        let n = 32
        for ch in s {
            let codepoint = alphabet.firstIndex(of: ch)!
            var addend = factor * codepoint
            factor = factor == 2 ? 1 : 2
            addend = addend / n + addend % n
            sum += addend
        }
        return alphabet[(n - sum % n) % n]
    }

    static func derFromPEM(_ pem: Data, type: String) throws -> Data {
        let text = String(decoding: pem, as: UTF8.self)
        let begin = "-----BEGIN \(type)-----"
        let end = "-----END \(type)-----"
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else {
            throw CodecError.invalidPEM
        }
        let body = text[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: String(body)), !der.isEmpty else { throw CodecError.invalidPEM }
        return der
    }

    static func pem(der: Data, type: String) -> Data {
        let b64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(type)-----\n\(b64)\n-----END \(type)-----\n".utf8)
    }
}
