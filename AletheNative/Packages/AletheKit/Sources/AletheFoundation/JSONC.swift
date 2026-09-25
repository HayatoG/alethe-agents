import Foundation

/// JSON with comments: drops `//` and `/* */` comments and trailing commas, leaving strings intact.
/// Shared by the Todo template and the agents' config files (`opencode.jsonc`, `settings.json`).
public enum JSONC {
    /// `strip` over UTF-8 bytes.
    public static func strip(_ data: Data) -> Data {
        Data(strip(String(decoding: data, as: UTF8.self)).utf8)
    }

    public static func strip(_ source: String) -> String {
        let chars = Array(source.unicodeScalars)
        var output = String.UnicodeScalarView()
        var index = 0
        var inString = false
        while index < chars.count {
            let char = chars[index]
            let next: Unicode.Scalar? = index + 1 < chars.count ? chars[index + 1] : nil
            if inString {
                output.append(char)
                if char == "\\", let next {
                    output.append(next)
                    index += 2
                    continue
                }
                if char == "\"" { inString = false }
                index += 1
            } else if char == "\"" {
                inString = true
                output.append(char)
                index += 1
            } else if char == "/", next == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if char == "/", next == "*" {
                index += 2
                while index < chars.count, !(chars[index] == "*" && index + 1 < chars.count && chars[index + 1] == "/") {
                    index += 1
                }
                index += 2
            } else if char == "," {
                // A comma followed only by whitespace/comments before `}` or `]` is trailing.
                var lookahead = index + 1
                var trailing = false
                scan: while lookahead < chars.count {
                    let c = chars[lookahead]
                    let n: Unicode.Scalar? = lookahead + 1 < chars.count ? chars[lookahead + 1] : nil
                    switch c {
                    case " ", "\t", "\n", "\r":
                        lookahead += 1
                    case "/" where n == "/":
                        while lookahead < chars.count, chars[lookahead] != "\n" { lookahead += 1 }
                    case "/" where n == "*":
                        lookahead += 2
                        while lookahead < chars.count, !(chars[lookahead] == "*" && lookahead + 1 < chars.count && chars[lookahead + 1] == "/") {
                            lookahead += 1
                        }
                        lookahead += 2
                    case "}", "]":
                        trailing = true
                        break scan
                    default:
                        break scan
                    }
                }
                if !trailing { output.append(char) }
                index += 1
            } else {
                output.append(char)
                index += 1
            }
        }
        return String(output)
    }
}
