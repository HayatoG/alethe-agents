import Foundation

/// Why the transport refused a request before routing it (answered 400, as upstream).
public enum RemoteRequestError: Error, Equatable, Sendable {
    case headersTooLarge
    case bodyTooLarge
    case closedEarly
    case malformed
}

/// HTTP/1.1 request parsing within `RemoteLimits` (upstream `http.rs` `read_request`,
/// `find_headers_end`, `header_value`, `bearer_token`). Pure: the transport feeds it the bytes it
/// receives, chunk by chunk.
public struct RemoteHTTPReader: Sendable {
    public enum Outcome: Equatable, Sendable {
        case needMore
        case complete(head: String, body: Data)
        case failed(RemoteRequestError)
    }

    private var raw = Data()
    private var headersEnd: Int?
    private var contentLength = 0
    private var searchedUpTo = 0

    public init() {}

    /// Adds received bytes and reports whether the request is complete.
    public mutating func append(_ chunk: Data) -> Outcome {
        raw.append(chunk)
        if headersEnd == nil {
            // Resume the search a few bytes back so a separator split across chunks is found.
            let start = max(0, searchedUpTo - 3)
            guard let end = Self.findHeadersEnd(raw, from: start) else {
                searchedUpTo = raw.count
                return raw.count > RemoteLimits.maxRequestHead ? .failed(.headersTooLarge) : .needMore
            }
            guard end <= RemoteLimits.maxRequestHead else { return .failed(.headersTooLarge) }
            headersEnd = end
            let length = Self.headerValue(head, "content-length").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? 0
            guard length <= RemoteLimits.maxBody else { return .failed(.bodyTooLarge) }
            contentLength = max(0, length)
        }
        return bodyOutcome()
    }

    /// The peer closed its side before the request completed.
    public func finish() -> Outcome {
        .failed(.closedEarly)
    }

    private var head: String {
        guard let headersEnd else { return "" }
        return String(decoding: raw.prefix(headersEnd), as: UTF8.self)
    }

    private func bodyOutcome() -> Outcome {
        guard let headersEnd else { return .needMore }
        let bodyStart = headersEnd + 4
        let received = raw.count - bodyStart
        guard received >= contentLength else { return .needMore }
        return .complete(head: head, body: Data(raw[bodyStart..<(bodyStart + contentLength)]))
    }

    // MARK: Upstream helpers

    /// The offset of the `\r\n\r\n` that ends the headers, or `nil`.
    public static func findHeadersEnd(_ raw: Data, from start: Int = 0) -> Int? {
        let bytes = [UInt8](raw)
        guard bytes.count >= 4 else { return nil }
        var index = max(0, start)
        while index + 3 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10, bytes[index + 2] == 13, bytes[index + 3] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }

    /// The first value of header `name` (case-insensitive), trimmed.
    public static func headerValue(_ head: String, _ name: String) -> String? {
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            if key.caseInsensitiveCompare(name) == .orderedSame {
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// The `Authorization: Bearer …` token, or `""`.
    public static func bearerToken(_ head: String) -> String {
        guard let value = headerValue(head, "authorization") else { return "" }
        for prefix in ["Bearer ", "bearer "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return ""
    }

    /// A request from its head and body: method and target from the request line (target `/` when
    /// missing), every header by name.
    public static func request(head: String, body: Data, peerAddress: String) -> RemoteRequest? {
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(whereSeparator: \.isWhitespace)
        guard let method = requestLine.first, !method.isEmpty else { return nil }
        let target = requestLine.count > 1 ? String(requestLine[1]) : "/"
        var headers: [(String, String)] = []
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers.append((
                line[..<colon].trimmingCharacters(in: .whitespaces),
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            ))
        }
        // `RemoteRequest` keeps the first occurrence of each name, as `headerValue` does.
        var byName: [String: String] = [:]
        for (name, value) in headers where byName[name.lowercased()] == nil {
            byName[name.lowercased()] = value
        }
        return RemoteRequest(method: String(method), target: target, headers: byName, body: body, peerAddress: peerAddress)
    }
}
