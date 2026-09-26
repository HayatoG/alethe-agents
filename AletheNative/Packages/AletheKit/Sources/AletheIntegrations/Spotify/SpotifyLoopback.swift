import AletheAgents
import Foundation
import Network

/// The page the browser shows after the redirect: it only tells the user to go back to the app.
/// Text is supplied by the app so it can be localized.
public struct SpotifyCallbackPages: Sendable {
    public var successTitle: String
    public var successMessage: String
    public var failureTitle: String
    public var failureMessage: String

    public init(successTitle: String, successMessage: String, failureTitle: String, failureMessage: String) {
        self.successTitle = successTitle
        self.successMessage = successMessage
        self.failureTitle = failureTitle
        self.failureMessage = failureMessage
    }

    public static let english = SpotifyCallbackPages(
        successTitle: "Connected to Spotify", successMessage: "You can close this tab and return to Alethe.",
        failureTitle: "Spotify connection failed", failureMessage: "Return to Alethe to see what happened.")

    func html(success: Bool) -> String {
        let title = escape(success ? successTitle : failureTitle)
        let message = escape(success ? successMessage : failureMessage)
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"color-scheme\" content=\"light dark\">"
            + "<title>\(title)</title></head><body style=\"font-family:system-ui;display:grid;place-items:center;"
            + "height:100vh;margin:0\"><div style=\"text-align:center\"><h1 style=\"font-weight:500\">\(title)</h1>"
            + "<p>\(message)</p></div></body></html>"
    }

    private func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Upstream `wait_for_oauth_callback`'s request handling, without the socket.
public enum SpotifyCallback {
    public enum Outcome: Equatable, Sendable {
        /// Not the callback (favicon and the like): 404, keep waiting.
        case notFound
        /// Not a request the callback answers: 400, keep waiting.
        case invalid
        case code(String)
        /// The login ends with this error.
        case failure(SpotifyError)
    }

    /// `target` is the request line's path and query. The `state` is checked before anything else
    /// the callback carries is believed.
    public static func evaluate(method: String, target: String, expectedState: String) -> Outcome {
        guard target.hasPrefix("/"),
              let components = URLComponents(string: "http://127.0.0.1:\(Spotify.callbackPort)\(target)"),
              components.path == Spotify.callbackPath else { return .notFound }
        guard method == "GET" else { return .invalid }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard let state = value("state"), state == expectedState else { return .failure(.stateMismatch) }
        if let error = value("error") { return .failure(.authorizationDenied(error)) }
        guard let code = value("code"), !code.isEmpty else { return .failure(.missingCode) }
        return .code(code)
    }
}

/// A one-shot listener on `127.0.0.1:<port>` (never a wildcard) that returns the first valid
/// callback's `code`. Ends on the callback, the timeout, a listener failure or task cancellation.
final class SpotifyLoopbackListener: @unchecked Sendable {
    private let port: UInt16
    private let expectedState: String
    private let timeout: TimeInterval
    private let pages: SpotifyCallbackPages
    private let queue = DispatchQueue(label: "alethe.spotify.oauth")
    private let lock = NSLock()
    private var listener: NWListener?
    private var continuation: CheckedContinuation<String, any Error>?
    private var result: Result<String, SpotifyError>?
    private var announcedReady = false

    init(port: UInt16 = Spotify.callbackPort, expectedState: String, timeout: TimeInterval = Spotify.loginTimeout,
         pages: SpotifyCallbackPages = .english) {
        self.port = port
        self.expectedState = expectedState
        self.timeout = timeout
        self.pages = pages
    }

    /// Binds, calls `ready` once listening (the caller opens the browser then; false aborts), and
    /// waits for the callback.
    func run(ready: @escaping @Sendable () async -> Bool) async throws(SpotifyError) -> String {
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, any Error>) in
                    let earlier = lock.withLock { () -> Result<String, SpotifyError>? in
                        if let result { return result }
                        self.continuation = continuation
                        return nil
                    }
                    if let earlier {
                        continuation.resume(with: earlier.mapError { $0 as any Error })
                    } else {
                        start(ready: ready)
                    }
                }
            } onCancel: {
                finish(.failure(.cancelled))
            }
        } catch let error as SpotifyError {
            throw error
        } catch {
            throw .listenerFailed(String(describing: error))
        }
    }

    private func start(ready: @escaping @Sendable () async -> Bool) {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return finish(.failure(.listenerFailed("port"))) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            return finish(.failure(Self.map(error)))
        }
        let proceed = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            self.listener = listener
            return true
        }
        guard proceed else { return listener.cancel() }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let first = lock.withLock { () -> Bool in defer { announcedReady = true }; return !announcedReady }
                guard first else { return }
                Task { if await !ready() { self.finish(.failure(.browserUnavailable)) } }
            case .failed(let error), .waiting(let error):
                finish(.failure(Self.map(error)))
            default:
                break
            }
        }
        listener.start(queue: queue)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(.timedOut)) }
    }

    private static func map(_ error: any Error) -> SpotifyError {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE { return .portBusy }
        if let error = error as? POSIXError, error.code == .EADDRINUSE { return .portBusy }
        return .listenerFailed(String(describing: error))
    }

    private func finish(_ outcome: Result<String, SpotifyError>) {
        let (continuation, listener) = lock.withLock { () -> (CheckedContinuation<String, any Error>?, NWListener?) in
            guard result == nil else { return (nil, nil) }
            result = outcome
            defer {
                self.continuation = nil
                self.listener = nil
            }
            return (self.continuation, self.listener)
        }
        listener?.cancel()
        continuation?.resume(with: outcome.mapError { $0 as any Error })
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            switch HTTPRequest.parse(buffer, bodyLimit: 0) {
            case .incomplete where !complete && error == nil:
                receive(connection, buffer: buffer)
            case .request(let request):
                switch SpotifyCallback.evaluate(method: request.method, target: request.path,
                                                expectedState: expectedState) {
                case .notFound:
                    respond(connection, status: "404 Not Found", html: nil)
                case .invalid:
                    respond(connection, status: "400 Bad Request", html: nil)
                case .code(let code):
                    respond(connection, status: "200 OK", html: pages.html(success: true))
                    finish(.success(code))
                case .failure(let failure):
                    respond(connection, status: "200 OK", html: pages.html(success: false))
                    finish(.failure(failure))
                }
            default:
                respond(connection, status: "400 Bad Request", html: nil)
            }
        }
    }

    private func respond(_ connection: NWConnection, status: String, html: String?) {
        let body = Data((html ?? "").utf8)
        var head = "HTTP/1.1 \(status)\r\n"
        if html != nil { head += "Content-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }
}
