import Foundation
import Network

/// The hook bridge's endpoint (upstream `agent_events.rs` listener, on Network.framework instead of
/// tiny_http): loopback only, a port the system picks, a per-launch token every request must carry.
/// It takes `POST /hook/<agent>` with the `X-Alethe-Tab` header and hands the body over.
public final class AgentHookServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ agent: String, _ tab: String, _ body: Data) -> Void

    public static let bodyLimit = 1 << 20

    public let token: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "alethe.hooks")
    private var listener: NWListener?
    private let lock = NSLock()
    private var boundPort: UInt16?

    public init(token: String = UUID().uuidString + UUID().uuidString, handler: @escaping Handler) {
        self.token = token.replacingOccurrences(of: "-", with: "")
        self.handler = handler
    }

    /// `http://127.0.0.1:<port>` once listening.
    public var endpoint: String? { lock.withLock { boundPort.map { "http://127.0.0.1:\($0)" } } }

    /// Starts listening; returns once the port is known (or nil when it could not bind).
    public func start() async -> String? {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return nil }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    let port = listener.port?.rawValue
                    self?.lock.withLock { self?.boundPort = port }
                    if resumed.set() { continuation.resume(returning: self?.endpoint) }
                case .failed, .cancelled:
                    if resumed.set() { continuation.resume(returning: nil) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, bodyLimit: Self.bodyLimit) {
            case .incomplete where !complete && error == nil:
                self.receive(connection, buffer: buffer)
            case .request(let request):
                self.respond(connection, status: self.handle(request))
            case .tooLarge:
                self.respond(connection, status: 413)
            default:
                self.respond(connection, status: 400)
            }
        }
    }

    func handle(_ request: HTTPRequest) -> Int {
        guard request.headers["x-alethe-token"] == token else { return 401 }
        guard request.method == "POST", request.path.hasPrefix("/hook/"),
              let tab = request.headers["x-alethe-tab"], !tab.isEmpty else { return 404 }
        handler(String(request.path.dropFirst("/hook/".count)), tab, request.body)
        return 200
    }

    private func respond(_ connection: NWConnection, status: Int) {
        let reason = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found", 413: "Payload Too Large"][status] ?? "OK"
        let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// A minimal HTTP/1.1 request: request line, headers (names lowercased), a `Content-Length` body.
public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data

    public enum Parse: Equatable {
        case incomplete, invalid, tooLarge
        case request(HTTPRequest)
    }

    public static func parse(_ data: Data, bodyLimit: Int) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = data.range(of: separator) else { return data.count > 64 * 1024 ? .invalid : .incomplete }
        guard let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .invalid }
        guard length <= bodyLimit else { return .tooLarge }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return .incomplete }
        return .request(HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers,
                                    body: Data(data[bodyStart..<(bodyStart + length)])))
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// True the first time only.
    func set() -> Bool { lock.withLock { defer { value = true }; return !value } }
}
