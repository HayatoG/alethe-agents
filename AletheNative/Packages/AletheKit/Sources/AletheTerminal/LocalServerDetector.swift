import Foundation

/// Spots local development servers in terminal output ("Local: http://localhost:5173/"), so the pane
/// can offer to show the page (the native take on upstream `useAgentBrowserOffers`, which watched a
/// shared CDP browser the native app does not have). Colors and other escape sequences are ignored,
/// an address split across output chunks is still found, and each address is reported once.
public struct LocalServerDetector: Sendable {
    private var tail = ""
    private var seen: Set<String> = []
    /// Longest carry-over between chunks: enough for one address.
    private static let tailLength = 200

    public init() {}

    /// New local addresses in `data`, in order of appearance.
    public mutating func scan(_ data: Data) -> [URL] {
        let text = tail + Self.stripEscapes(String(decoding: data, as: UTF8.self))
        var found: [URL] = []
        var lastEnd = text.startIndex
        for match in text.matches(of: Self.pattern) {
            // An address touching the end may still be arriving; it is rescanned with the next chunk.
            if match.range.upperBound == text.endIndex { break }
            lastEnd = match.range.upperBound
            guard let url = Self.normalize(String(match.output)), seen.insert(url.absoluteString).inserted else { continue }
            found.append(url)
        }
        let carry = text[lastEnd...].suffix(Self.tailLength)
        tail = String(carry)
        return found
    }

    private static var pattern: Regex<Substring> { /https?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]):\d{2,5}(?:\/[^\s"'`<>)\]]*)?/ }

    /// `0.0.0.0` and `[::]` mean "every interface": the page is browsable at localhost.
    static func normalize(_ address: String) -> URL? {
        var value = address
        while let last = value.last, ".,;:".contains(last) { value.removeLast() }
        value = value.replacingOccurrences(of: "://0.0.0.0:", with: "://localhost:")
            .replacingOccurrences(of: "://[::]:", with: "://localhost:")
        guard var components = URLComponents(string: value) else { return nil }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    /// Removes CSI / OSC escape sequences (colors, hyperlinks, titles).
    static func stripEscapes(_ text: String) -> String {
        text.replacing(/\x1B\[[0-9;?]*[ -\/]*[@-~]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[@-Z\\-_]/, with: "")
    }
}
