import Foundation

/// Removes credentials from text before it is written to a log file or exported: known token
/// shapes, `Bearer …`, URL passwords and the value of any `key=value` / `"key": "value"` pair whose
/// key names a secret. Messages still go to OSLog as `.private`; this protects the files.
public enum SecretRedactor {
    public static let placeholder = "<redacted>"

    private static let secretKey =
        "[A-Za-z0-9_.-]*(?:token|secret|passw(?:or)?d|pwd|api[_-]?key|apikey|access[_-]?key|private[_-]?key|"
        + "credential|authorization|cookie)[A-Za-z0-9_.-]*"

    /// Pattern and the template it is replaced with, applied in order.
    private static let rules: [(regex: NSRegularExpression, template: String)] = [
        // `://user:password@host`
        (#"(://[^/\s:@]+):[^/\s@]+@"#, "$1:\(placeholder)@"),
        // `Authorization: Bearer abc`, `token abc`
        (#"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{6,}"#, "$1 \(placeholder)"),
        // `API_KEY=abc`, `"access_token": "abc"`, `--api-key abc`, `?token=abc`
        (#"(?i)(\#(secretKey)["']?\s*[:=]\s*["']?)[^\s"',;&}]+"#, "$1\(placeholder)"),
        (#"(?i)(--\#(secretKey)\s+)[^\s"']+"#, "$1\(placeholder)"),
        // Known token shapes, wherever they appear.
        (#"\bsk-[A-Za-z0-9_-]{16,}"#, placeholder),
        (#"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#, placeholder),
        (#"\bxox[abposr]-[A-Za-z0-9-]{10,}"#, placeholder),
        (#"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"#, placeholder),
        (#"\bAIza[0-9A-Za-z_-]{35}"#, placeholder),
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, placeholder),
    ].map { pattern, template in
        // The patterns are literals: a failure here is a programming error caught by the tests.
        (try! NSRegularExpression(pattern: pattern), template)
    }

    public static func redact(_ text: String) -> String {
        var result = text
        for rule in rules {
            let range = NSRange(result.startIndex..., in: result)
            result = rule.regex.stringByReplacingMatches(in: result, range: range, withTemplate: rule.template)
        }
        return result
    }
}
