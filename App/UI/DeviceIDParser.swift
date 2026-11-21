import Foundation
import PsySync

/// Validates and normalises Syncthing device IDs entered by hand, pasted, or
/// scanned from a QR code (which contains the plain ID). Mirrors upstream's
/// `protocol.DeviceIDFromString` (Luhn-32 check per 13-character group), so the UI can
/// give instant feedback without calling the bridge.
enum DeviceIDParser {
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func luhn32(_ group: [Character]) -> Character? {
        var factor = 1
        var sum = 0
        for ch in group {
            guard let code = alphabet.firstIndex(of: ch) else { return nil }
            var addend = factor * code
            factor = factor == 2 ? 1 : 2
            addend = addend / 32 + addend % 32
            sum += addend
        }
        return alphabet[(32 - sum % 32) % 32]
    }

    /// Strict parse of a whole string (dashes/spaces optional, case-insensitive).
    static func parse(_ text: String) -> DeviceID? {
        var chars = text.uppercased().filter { !$0.isWhitespace && $0 != "-" }.map { $0 }
        chars = chars.map { c in
            switch c { case "0": "O"; case "1": "I"; case "8": "B"; default: c }
        }
        guard chars.count == 56 else { return nil }
        for g in 0..<4 {
            let group = Array(chars[(g * 14)..<(g * 14 + 13)])
            guard luhn32(group) == chars[g * 14 + 13] else { return nil }
        }
        let canonical = stride(from: 0, to: 56, by: 7).map { String(chars[$0..<$0 + 7]) }.joined(separator: "-")
        return DeviceID(rawValue: canonical)
    }

    /// Finds the first valid device ID anywhere in `text` (QR payloads, clipboard text).
    static func extract(from text: String) -> DeviceID? {
        if let id = parse(text) { return id }
        let pattern = #"(?:[A-Za-z0-9]{7}[- ]){7}[A-Za-z0-9]{7}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if let id = parse(ns.substring(with: match.range)) { return id }
        }
        return nil
    }
}
