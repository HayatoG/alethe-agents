import AletheExtensionSDK
import Foundation

/// Connections to Alethe and the host storage calls made over them.
final class HostBridge: @unchecked Sendable {
    static let shared = HostBridge()
    static let counterKey = "counter"

    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []

    /// Configures and keeps a connection from the host. `service` is exported on the process
    /// connection; scene connections only call the host.
    func accept(_ connection: NSXPCConnection, exporting service: (any AletheExtensionXPC)?) -> Bool {
        connection.remoteObjectInterface = .aletheHost()
        if let service {
            connection.exportedInterface = .aletheExtension()
            connection.exportedObject = service
        }
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.withLock { self.connections.removeAll { $0 === connection } }
        }
        lock.withLock { connections.append(connection) }
        connection.resume()
        return true
    }

    func send(_ request: HostRequest) async -> HostResponse {
        guard let connection = lock.withLock({ connections.last }) else { return .failed("not connected") }
        return await withCheckedContinuation { continuation in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(returning: .failed(error.localizedDescription))
            } as? any AletheHostXPC
            guard let proxy else { return continuation.resume(returning: .failed("no proxy")) }
            proxy.handle(ExtensionWire.encode(request)) { data in
                continuation.resume(returning: ExtensionWire.decode(HostResponse.self, from: data) ?? .failed("bad reply"))
            }
        }
    }

    /// The stored counter, or nil when the host denied storage.
    func counter() async -> Int? {
        guard case .value(let value) = await send(.storageGet(key: Self.counterKey)) else { return nil }
        return Int(value ?? "0") ?? 0
    }

    /// Adds one to the counter in host storage; nil when storage is denied.
    func incrementCounter() async -> Int? {
        guard let current = await counter() else { return nil }
        let next = current + 1
        guard case .done = await send(.storageSet(key: Self.counterKey, value: String(next))) else { return nil }
        return next
    }
}
