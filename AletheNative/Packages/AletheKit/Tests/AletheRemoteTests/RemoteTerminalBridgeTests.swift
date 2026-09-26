import Foundation
import Testing
@testable import AletheRemote

/// A stand-in for the app's terminal registry: running tabs record what is typed into them.
final class FakeRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var typed: [String: Data] = [:]
    private var handlers: [UUID: @Sendable (RemoteTerminalChunk) -> Void] = [:]
    var running: Set<String> = ["tab-1"]
    var known: Set<String> = ["tab-1", "tab-2"]
    var scrollback = Data()
    var sizes: [String: RemoteTerminalSize] = ["tab-1": RemoteTerminalSize(cols: 120, rows: 40)]

    func input(_ id: String) -> String { lock.withLock { String(decoding: typed[id] ?? Data(), as: UTF8.self) } }
    var observers: Int { lock.withLock { handlers.count } }

    func emit(_ chunk: RemoteTerminalChunk) {
        for handler in lock.withLock({ Array(handlers.values) }) { handler(chunk) }
    }

    var backend: RemoteTerminalBridge.Backend {
        RemoteTerminalBridge.Backend(
            write: { id, bytes in
                guard self.known.contains(id) else { return .notFound }
                guard self.running.contains(id) else { return .notRunning }
                self.lock.withLock { self.typed[id, default: Data()].append(bytes) }
                return .written
            },
            size: { id in self.sizes[id] },
            scrollback: { _, maxBytes in self.scrollback.suffix(maxBytes) },
            observe: { handler in
                let id = UUID()
                self.lock.withLock { self.handlers[id] = handler }
                return { self.lock.withLock { _ = self.handlers.removeValue(forKey: id) } }
            }
        )
    }
}

@Suite struct RemoteTerminalBridgeTests {
    @Test func inputReachesTheTabAsTypedBytes() async throws {
        let registry = FakeRegistry()
        let bridge = RemoteTerminalBridge(backend: registry.backend)

        try await bridge.write(terminalID: "tab-1", text: "ls -la\r")
        try await bridge.write(terminalID: "tab-1", text: "é\u{03}")

        #expect(registry.input("tab-1") == "ls -la\ré\u{03}")
        #expect(registry.input("tab-2").isEmpty)
    }

    @Test func aTabThatIsNotRunningRefusesInput() async {
        let bridge = RemoteTerminalBridge(backend: FakeRegistry().backend)

        await #expect(throws: RemoteInputError.notRunning) {
            try await bridge.write(terminalID: "tab-2", text: "hi")
        }
        await #expect(throws: RemoteInputError.notFound) {
            try await bridge.write(terminalID: "gone", text: "hi")
        }
    }

    @Test func theAPIAnswers409ForATabThatIsNotRunning() async throws {
        let registry = FakeRegistry()
        let hub = RemoteHub(resolver: RemoteHostResolver(lanAddress: { "127.0.0.1" }, tailscaleAddress: { nil }))
        let workspace = FakeWorkspace()
        workspace.tabs = [RemoteSharedTab(terminalID: "tab-2", agent: "shell", cwd: "/tmp", sessionID: nil)]
        let api = RemoteAPI(hub: hub, terminals: RemoteTerminalBridge(backend: registry.backend), workspace: workspace,
                            assets: FakeAssets())
        await hub.beginRun()
        await hub.setHTTPPort(9340)
        await hub.setAllowShellInput(true)
        await hub.openPairingWindow()
        let pairing = try await hub.pair(token: hub.pairingToken, name: "Phone", address: "127.0.0.1:1")

        let response = await api.route(RemoteRequest(
            method: "POST", target: "/api/message", headers: ["Authorization": "Bearer \(pairing.sessionToken)"],
            body: Data(#"{"ptyId":"tab-2","text":"hi"}"#.utf8), peerAddress: "127.0.0.1:1"))

        #expect(response.status == 409)
        #expect(registry.input("tab-2").isEmpty)
    }

    @Test func sizesComeFromTheTab() async {
        let bridge = RemoteTerminalBridge(backend: FakeRegistry().backend)

        #expect(await bridge.size(terminalID: "tab-1") == RemoteTerminalSize(cols: 120, rows: 40))
        #expect(await bridge.size(terminalID: "tab-2") == nil)
    }

    @Test func theScrollbackTailStartsOnACharacterBoundary() async {
        let registry = FakeRegistry()
        registry.scrollback = Data("aé€😀z".utf8)
        let bridge = RemoteTerminalBridge(backend: registry.backend)

        // "😀z" is 5 bytes; 6 bytes cut into the middle of "€" (3 bytes), whose tail is dropped.
        #expect(await bridge.scrollbackTail(terminalID: "tab-1", maxBytes: 6) == "😀z")
        #expect(await bridge.scrollbackTail(terminalID: "tab-1", maxBytes: 8) == "€😀z")
        #expect(await bridge.scrollbackTail(terminalID: "tab-1", maxBytes: 1_000) == "aé€😀z")
        #expect(await bridge.scrollbackTail(terminalID: "tab-1", maxBytes: 0) == "")
    }

    @Test func aCharacterSplitAcrossChunksIsDecodedWhole() {
        let decoder = RemoteOutputDecoder()
        let bytes = Array("a€b".utf8)

        let first = decoder.decode(.data(terminalID: "t", bytes: Data(bytes[0..<2])))
        let second = decoder.decode(.data(terminalID: "t", bytes: Data(bytes[2..<3])))
        let third = decoder.decode(.data(terminalID: "t", bytes: Data(bytes[3...])))

        #expect(first == .data(terminalID: "t", text: "a"))
        #expect(second == nil)
        #expect(third == .data(terminalID: "t", text: "€b"))
    }

    @Test func tabsAreDecodedApartAndAnExitDropsPendingBytes() {
        let decoder = RemoteOutputDecoder()
        let euro = Array("€".utf8)

        _ = decoder.decode(.data(terminalID: "a", bytes: Data(euro[0..<1])))
        #expect(decoder.decode(.data(terminalID: "b", bytes: Data("x".utf8))) == .data(terminalID: "b", text: "x"))
        #expect(decoder.decode(.exit(terminalID: "a", reason: "exited")) == .exit(terminalID: "a", reason: "exited"))
        #expect(decoder.decode(.data(terminalID: "a", bytes: Data("y".utf8))) == .data(terminalID: "a", text: "y"))
    }

    @Test func completePrefixHoldsBackOnlyAnUnfinishedCharacter() {
        #expect(RemoteOutputDecoder.completePrefix([]) == 0)
        #expect(RemoteOutputDecoder.completePrefix(Array("abc".utf8)) == 3)
        #expect(RemoteOutputDecoder.completePrefix(Array("é".utf8)) == 2)
        #expect(RemoteOutputDecoder.completePrefix([0x61, 0xF0, 0x9F, 0x98]) == 1)
        #expect(RemoteOutputDecoder.completePrefix([0x61, 0xFF]) == 2, "invalid bytes pass through")
    }

    @Test func outputIsStreamedAndObservingStopsWithTheStream() async {
        let registry = FakeRegistry()
        let bridge = RemoteTerminalBridge(backend: registry.backend)
        let stream = bridge.output()
        #expect(registry.observers == 1)
        let received = Received()
        let consumer = Task {
            for await output in stream { received.append(output) }
        }

        registry.emit(.data(terminalID: "tab-1", bytes: Data("hello".utf8)))
        registry.emit(.exit(terminalID: "tab-1", reason: "exited"))
        #expect(await eventuallyTrue { received.count == 2 })
        consumer.cancel()

        #expect(received.values == [.data(terminalID: "tab-1", text: "hello"), .exit(terminalID: "tab-1", reason: "exited")])
        #expect(await eventuallyTrue { registry.observers == 0 })
    }
}

final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [RemoteTerminalOutput] = []

    func append(_ output: RemoteTerminalOutput) { lock.withLock { items.append(output) } }
    var values: [RemoteTerminalOutput] { lock.withLock { items } }
    var count: Int { values.count }
}

/// Polls `condition` for up to two seconds.
func eventuallyTrue(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<40 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(50))
    }
    return condition()
}
