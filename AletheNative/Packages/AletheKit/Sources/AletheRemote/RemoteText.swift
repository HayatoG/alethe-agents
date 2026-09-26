import Foundation

/// Dependency-free helpers shared by the hub, the transport and the API (upstream `remote/util.rs`).
public enum RemoteText {
    /// Compares two tokens in time that depends only on their lengths, never on where they differ.
    public static func tokensEqual(_ provided: String, _ expected: String) -> Bool {
        let lhs = Array(provided.utf8)
        let rhs = Array(expected.utf8)
        var difference = lhs.count ^ rhs.count
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            difference |= Int(left ^ right)
        }
        return difference == 0
    }

    /// Replaces every control character (Unicode `Cc`: C0, DEL, C1) with a space, so remote text
    /// can never carry escape sequences or line breaks into a terminal.
    public static func sanitize(_ input: String) -> String {
        var output = String.UnicodeScalarView()
        for scalar in input.unicodeScalars {
            output.append(scalar.properties.generalCategory == .control ? " " : scalar)
        }
        return String(output)
    }

    /// The first `key` value in the target's query string, percent-decoded (`+` is a space).
    public static func queryValue(_ target: String, _ key: String) -> String? {
        let parts = target.split(separator: "?", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        for pair in parts[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "=") else { continue }
            if pair[..<equals] == key[...] {
                return percentDecode(String(pair[pair.index(after: equals)...]))
            }
        }
        return nil
    }

    /// Percent-decoding as upstream: a malformed escape stays literal, invalid UTF-8 is replaced.
    public static func percentDecode(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var decoded: [UInt8] = []
        decoded.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
               let high = hexValue(bytes[index + 1]), let low = hexValue(bytes[index + 2]) {
                decoded.append(high << 4 | low)
                index += 3
            } else if byte == UInt8(ascii: "+") {
                decoded.append(UInt8(ascii: " "))
                index += 1
            } else {
                decoded.append(byte)
                index += 1
            }
        }
        return String(decoding: decoded, as: UTF8.self)
    }

    /// At most `limit` characters of `text`.
    public static func truncated(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }

    /// A random token over nanoid's URL-safe alphabet (64 symbols, so each byte maps without bias).
    public static func randomToken(length: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var scalars = String.UnicodeScalarView()
        for _ in 0..<length {
            let index = Int(UInt8.random(in: 0...255, using: &generator) & 63)
            scalars.append(tokenAlphabet[index])
        }
        return String(scalars)
    }

    private static let tokenAlphabet = Array("useandom-26T198340PX75pxJACKVERYMINDBUSHWOLF_GQZbfghjklqvwyzrict".unicodeScalars)

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
